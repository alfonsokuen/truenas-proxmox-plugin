#!/usr/bin/perl
# r6 point 1: a resize whose TrueNAS grow landed but whose NVMe rescan found no
# controller died after pool.dataset.update. Retrying with the same size must
# not be refused as a shrink: it is an idempotent retry that skips the grow and
# redoes only the initiator rescan.
use strict;
use warnings;
use Test::More;
use FindBin;

require "$FindBin::Bin/../../TrueNASPlugin.pm";
my $pkg = 'PVE::Storage::Custom::TrueNASPlugin';
my $vol = 'vol-vm-100-disk-0-ns11111111-2222-3333-4444-555555555555';
my $zvol = 'tank/pve/vm-100-disk-0';
my $scfg = { tn_dataset => 'tank/pve', tn_transport_mode => 'nvme-tcp', tn_subsystem_nqn => 'nqn.test' };

my ($volsize, $controllers, @updates, $rescans, @runs);
no strict 'refs';
no warnings 'redefine';
local *{"${pkg}::_log"} = sub {};
local *{"${pkg}::_invalidate_status_capacity_cache"} = sub {};
local *{"${pkg}::_handle_api_result_with_job_support"} = sub { { success => 1 } };
local *{"${pkg}::_tn_dataset_get"} = sub {
    my (undef, $name) = @_;
    return { available => 1024 * 1024 * 1024 } if $name eq 'tank/pve';
    die "unexpected dataset $name\n" unless $name eq $zvol;
    return { volsize => $volsize, volblocksize => 512 };
};
local *{"${pkg}::_api_call"} = sub {
    my (undef, $method, $params) = @_;
    die "unexpected RPC $method\n" unless $method eq 'pool.dataset.update';
    push @updates, $params->[1]{volsize};
    $volsize = $params->[1]{volsize};
    return {};
};
local *{"${pkg}::_nvme_rescan_subsystem_controllers"} = sub { $rescans++; $controllers };
local *{"${pkg}::_nvme_rescan_controller_fallback"} = sub { $rescans++; 0 };
local *{"${pkg}::_try_run"} = sub { push @runs, join(' ', @{$_[0]}); 1 };
local *{"${pkg}::run_command"} = sub {};

my $reset = sub { ($volsize, $controllers, $rescans, @updates, @runs) = (1024, 0, 0) };

subtest 'retry with the same size after a rescan that found no controller' => sub {
    $reset->();
    ok(!eval { $pkg->volume_resize($scfg, 'store', $vol, 2048); 1 }, 'first attempt dies: 0 controllers rescanned');
    like($@, qr/no NVMe controller rescanned/, 'it says the host may still see the old size');
    is_deeply(\@updates, [2048], 'the grow itself landed on TrueNAS');

    $controllers = 1;
    $rescans = 0;
    my $kib = eval { $pkg->volume_resize($scfg, 'store', $vol, 2048) };
    is($@, '', 'the retry is not refused as a shrink');
    is($kib, 2, 'the retry returns the size in KiB');
    is(scalar(@updates), 1, 'pool.dataset.update total = 1 (the retry does not grow again)');
    cmp_ok($rescans, '>=', 1, 'the retry rescans the transport');
};

subtest 'retry with an unaligned size that the first attempt aligned up' => sub {
    $reset->();
    ok(!eval { $pkg->volume_resize($scfg, 'store', $vol, 1537); 1 }, 'first attempt dies after the grow');
    is_deeply(\@updates, [2048], 'the first attempt grew to the aligned size');
    $controllers = 1;
    $rescans = 0;
    my $kib = eval { $pkg->volume_resize($scfg, 'store', $vol, 1537) };
    is($@, '', 'the unaligned retry is not refused as a shrink');
    is($kib, 2, 'it returns the aligned size in KiB');
    is(scalar(@updates), 1, 'pool.dataset.update total = 1');
    cmp_ok($rescans, '>=', 1, 'the retry rescans the transport');
};

subtest 'a retry that still rescans no controller still fails' => sub {
    $reset->();
    $volsize = 2048;
    ok(!eval { $pkg->volume_resize($scfg, 'store', $vol, 2048); 1 }, 'retry with 0 controllers dies');
    like($@, qr/no NVMe controller rescanned/, 'with the rescan error');
    is(scalar(@updates), 0, 'and does not touch the zvol');
    cmp_ok($rescans, '>=', 1, 'it did try to rescan');
};

subtest 'a real shrink is still refused' => sub {
    $reset->();
    $volsize = 2048;
    ok(!eval { $pkg->volume_resize($scfg, 'store', $vol, 1024); 1 }, 'smaller aligned size dies');
    like($@, qr/shrink not supported/, 'as a shrink');
    is(scalar(@updates), 0, 'no pool.dataset.update');
    is($rescans, 0, 'no rescan');
};

subtest 'iSCSI: an equal-size retry rescans the sessions without growing' => sub {
    $reset->();
    $volsize = 2048;
    my $kib = eval { $pkg->volume_resize({ %$scfg, tn_transport_mode => 'iscsi' }, 'store', $vol, 2048) };
    is($@, '', 'the retry succeeds');
    is($kib, 2, 'with the size in KiB');
    is(scalar(@updates), 0, 'no pool.dataset.update');
    is_deeply(\@runs, ['iscsiadm -m session -R'], 'the iSCSI sessions are rescanned');
};

done_testing;
