#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use FindBin;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use JSON::PP qw(encode_json);
use Time::HiRes qw(time);

require "$FindBin::Bin/../../TrueNASPlugin.pm";
my $pkg = 'PVE::Storage::Custom::TrueNASPlugin';
my $root = tempdir(CLEANUP => 1);
my $volname = 'vol-vm-101-disk-0-lun7';
my $wwid = '3' . 'a' x 32;
my $device = "$root/sys/block/sdm/device";
my $scfg = {
    tn_transport_mode => 'iscsi', tn_dataset => 'tank/pve',
    tn_target_iqn => 'iqn.2005-10.org.freenas.ctl:prox',
    tn_force_delete_on_inuse => 1, tn_use_multipath => 1,
};
make_path($device, "$root/pmxcfs/nodes/remote/qemu-server");

sub put {
    my ($file, $text) = @_;
    open(my $fh, '>', $file) or die "open $file: $!";
    print {$fh} $text or die "write $file: $!";
    close($fh) or die "close $file: $!";
}

sub guest_index {
    my (%ids) = @_;
    put("$root/pmxcfs/.vmlist", encode_json({ ids => \%ids }));
}

no strict 'refs';
no warnings 'redefine', 'once';
$INC{'PVE/Cluster.pm'} = __FILE__;
*PVE::Cluster::check_cfs_quorum = sub { 1 };
local ${"${pkg}::_PRUNE_PVE_ROOT"} = "$root/pmxcfs";
local ${"${pkg}::SYS_BLOCK_ROOT"} = "$root/sys/block";
local *{"${pkg}::_log"} = sub {};

subtest '9: a recycled sd name never receives a device/delete write' => sub {
    put("$device/wwid", 'naa.' . ('a' x 32) . "\n");
    put("$device/delete", '0');
    my $runner = sub {
        my ($cmd) = @_;
        put("$device/wwid", 'naa.' . ('b' x 32) . "\n") if $cmd->[0] eq 'multipath';
        return 0;
    };
    local *PVE::Tools::run_command = $runner;
    local *{"${pkg}::run_command"} = $runner;
    is($pkg->can('_teardown_stale_wwid')->($scfg, $wwid, ['sdm']), 0,
        'changed identity makes teardown incomplete');
    open(my $fh, '<', "$device/delete") or die $!;
    is(<$fh>, '0', 'zero delete writes for the replacement WWID');
    close($fh);
};

subtest '10: iSCSI free verifies cluster references and fails closed on uncertain logout' => sub {
    my (@mutations, $mode, $deferred, $mapping_deletes);
    my $map = { id => 8, target => 42, extent => 9, lunid => 7 };
    local *{"${pkg}::_resolve_target_id"} = sub { 42 };
    local *{"${pkg}::_clear_cache"} = sub {};
    local *{"${pkg}::_assert_no_child_datasets"} = sub {};
    local *{"${pkg}::_defer_after_lock"} = sub { $deferred = shift };
    local *{"${pkg}::_ensure_target_visible"} = sub {};
    local *{"${pkg}::_session_has_no_luns"} = sub { 1 };
    local *{"${pkg}::_logout_target_all_portals"} = sub { push @mutations, 'logout' };
    local *{"${pkg}::_delete_dataset_with_retry"} = sub { push @mutations, 'dataset' };
    local *{"${pkg}::sleep"} = sub {};
    local *PVE::Tools::run_command = sub { push @mutations, $_[0][0]; 0 };
    local *{"${pkg}::run_command"} = sub { push @mutations, $_[0][0]; 0 };
    local *{"${pkg}::_api_call"} = sub {
        my (undef, $method, $args) = @_;
        return [{ id => 9 }] if $method eq 'iscsi.extent.query';
        if ($method eq 'iscsi.targetextent.query') {
            return [$map] if @{ $args->[0] } == 2;
            die "could not count LUNs\n" if $mode eq 'unknown';
            return [$map] if $mode eq 'last';
            return [{ id => 18, target => 42, extent => 19, lunid => 17 }];
        }
        push @mutations, $method;
        if ($method eq 'iscsi.targetextent.delete' && $mode eq 'last') {
            die "mapping is in use\n" if ++$mapping_deletes == 1;
        }
        if ($method eq 'iscsi.extent.delete') {
            die "extent is in use\n" if $mode eq 'unknown' || $mode eq 'other';
            die "permission denied\n" if $mode eq 'denied';
        }
        return 1;
    };

    my $free = sub { $pkg->free_image('store', $scfg, $volname, 0, 'raw') };
    my $reference = sub {
        guest_index(900 => { node => 'remote', type => 'qemu' });
        put("$root/pmxcfs/nodes/remote/qemu-server/900.conf", "[PENDING]\nscsi0: store:$volname\n");
    };
    $mode = 'clear';
    $reference->();
    ok(!eval { $free->(); 1 }, 'refuses remote reference');
    like($@, qr/referenced by guest 900/, 'names the remote guest');
    is_deeply(\@mutations, [], 'zero local or array mutations for a referenced disk');

    for my $case (qw(unknown other denied)) {
        guest_index();
        @mutations = ();
        $mode = $case;
        my $result = eval { $free->() };
        ok($@, "$case leaves the dataset intact");
        ok(!grep({ $_ eq 'logout' } @mutations), "$case issued zero target-wide logouts");
        ok(ref($result) ne 'CODE', "$case returned no dataset-delete worker");
    }

    guest_index();
    @mutations = ();
    $mode = 'last';
    $mapping_deletes = 0;
    is(ref($free->()), 'CODE', 'the verified sole mapping can be retried');
    is(scalar(grep { $_ eq 'logout' } @mutations), 1, 'the sole matching LUN permits one logout');
    is($mapping_deletes, 2, 'the original mapping is retried exactly once');

    guest_index();
    @mutations = ();
    $mode = 'clear';
    local $scfg->{tn_logout_on_free} = 1;
    my $worker = $free->();
    is(ref($worker), 'CODE', 'verified ordinary deletion returns a worker');
    $deferred->();
    ok(!grep({ $_ eq 'logout' } @mutations), 'optional logout also preserves a mapped disk');
    $reference->();
    ok(!eval { $worker->('UPID:test'); 1 }, 'worker detects a reference added after export removal');
    ok(!grep({ $_ eq 'dataset' } @mutations), 'worker issued zero dataset deletes');
};

subtest '11: one pvestatd budget limits reconcile commands and prevents further work' => sub {
    my @runs;
    my $runner = sub {
        my ($cmd, %opts) = @_;
        push @runs, [ $cmd, $opts{timeout} ];
        return 0;
    };
    local *PVE::Tools::run_command = $runner;
    local *{"${pkg}::run_command"} = $runner;

    {
        local ${"${pkg}::_api_deadline"} = time() + 3;
        $pkg->can('_teardown_stale_wwid')->($scfg, $wwid, []);
    }
    is_deeply([map { $_->[0][0] } @runs], [qw(kpartx multipath udevadm)],
        'all three local commands run with sufficient budget');
    for my $run (@runs) {
        ok(defined($run->[1]) && $run->[1] > 0 && $run->[1] <= 3,
            "$run->[0][0] has a bounded command timeout");
    }
    like($runs[-1][0][-1], qr/\A--timeout=[1-3]\z/, 'udevadm also receives its own timeout');

    @runs = ();
    {
        local ${"${pkg}::_api_deadline"} = time() - 1;
        is($pkg->can('_teardown_stale_wwid')->($scfg, $wwid, []), 0,
            'an expired sweep remains incomplete');
    }
    is(scalar @runs, 0, 'zero local commands after the budget expires');

    {
        local ${"${pkg}::_api_deadline"} = time() + 3;
        local *PVE::Tools::run_command = sub {
            $runner->(@_);
            ${"${pkg}::_api_deadline"} = time() - 1;
        };
        is($pkg->can('_teardown_stale_wwid')->($scfg, $wwid, []), 0,
            'exhausting the budget during kpartx stops the teardown');
    }
    is_deeply([map { $_->[0][0] } @runs], ['kpartx'],
        'multipath and udevadm are skipped after kpartx exhausts the budget');

    my $activate_budget;
    local *{"${pkg}::_ensure_target_visible"} = sub {};
    local *{"${pkg}::_reconcile_stale_wwids"} = sub {
        $activate_budget = $pkg->can('_deadline_left')->();
    };
    $pkg->activate_storage('store', $scfg, {});
    ok(defined($activate_budget) && $activate_budget > 0 && $activate_budget <= 8,
        'activate_storage grants the sweep a finite pvestatd budget');
};

done_testing();
