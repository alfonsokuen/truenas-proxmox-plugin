#!/usr/bin/perl
# free_image on an NVMe volume that is still ACTIVE on this node.
#
# The free is two steps in two places: the namespace is deleted synchronously
# (under the storage lock), the zvol later, by the worker PVE runs outside the
# lock. Freeing a volume whose device is open here (a running guest, a mount, a
# dm holder) used to delete the namespace anyway and then fail at the zvol,
# leaving a zvol that no namespace points at and that list_images never shows:
# an orphan nobody is told about. The refusal has to come BEFORE the first
# mutating call, so it lives on the synchronous path; a check inside the worker
# would run after the namespace is already gone.
#
# Both directions are asserted: in use -> dies and nothing was touched;
# not in use / not attached on this node -> the free works as before.
# And when the zvol delete does fail after the namespace is gone, the error
# must name the zvol that is left.
#
# Run with:  prove -v t/nvme/41-free-refuses-while-in-use.t
use strict;
use warnings;
use Test::More;
use FindBin;

my $PLUGIN = "$FindBin::Bin/../../TrueNASPlugin.pm";
unless (eval { require $PLUGIN; 1 }) {
    plan skip_all => "cannot load TrueNASPlugin.pm (needs PVE perl modules): $@";
}
my $PKG  = 'PVE::Storage::Custom::TrueNASPlugin';
my $UUID = '11111111-2222-3333-4444-555555555555';
my $VOL  = "vol-vm-101-disk-0-ns$UUID";
my $DS   = 'tank/pve/vm-101-disk-0';
my $scfg = { tn_dataset => 'tank/pve', tn_api_host => '198.51.100.7', tn_transport_mode => 'nvme-tcp',
             tn_subsystem_nqn => 'nqn.x:y' };

my (@events, @checked, $selector, $in_use, $dataset_delete_dies);
{
    no strict 'refs'; no warnings 'redefine';
    *{"${PKG}::_log"} = sub { 1 };
    *{"${PKG}::_defer_after_lock"} = sub { 1 };
    *{"${PKG}::run_command"} = sub { 1 };
    *{"${PKG}::_assert_no_child_datasets"} = sub { 1 };
    *{"${PKG}::_nvme_disconnect"} = sub { push @events, 'nvme_disconnect'; 1 };
    *{"${PKG}::_nvme_find_device_by_subsystem"} = sub { $selector };
    *{"${PKG}::_nvme_check_devices_in_use"} = sub {
        my ($s, @paths) = @_;
        push @checked, @paths;
        push @events, 'in_use_check';
        return $in_use;
    };
    *{"${PKG}::_nvme_delete_namespace"} = sub { push @events, 'delete_namespace'; 1 };
    *{"${PKG}::_delete_dataset_with_retry"} = sub {
        push @events, 'delete_dataset';
        die "EBUSY: dataset is busy\n" if $dataset_delete_dies;
        1;
    };
    *{"${PKG}::_api_call"} = sub { [] };
}

sub run_free {
    my (%o) = @_;
    $selector = exists $o{selector} ? $o{selector} : {
        selector_outcome => 'exact_match', selected_device_path => '/dev/nvme0n1',
        linux_device_count => 1 };
    $in_use = $o{in_use};
    $dataset_delete_dies = $o{dataset_dies};
    (@events, @checked) = ();
    my ($worker_err, $worker);
    my $ok = eval { $worker = $PKG->free_image('store', $scfg, $VOL, 0, 'raw'); 1 };
    my $err = $@;
    if ($ok && ref($worker) eq 'CODE') {
        eval { $worker->('UPID:t'); 1 } or $worker_err = $@;
    }
    return ($ok, $err, $worker_err);
}

{
    my ($ok, $err) = run_free(in_use => 1);
    ok(!$ok, 'volume device in use on this node -> free_image dies');
    like($err, qr/in use/i, '  ...saying the volume is in use');
    like($err, qr/\Q$VOL\E|\Q$DS\E/, '  ...naming the volume');
    is_deeply(\@checked, ['/dev/nvme0n1'], '  ...after checking exactly that volume\'s device');
    is_deeply(\@events, ['in_use_check'],
        '  ...with NO namespace delete, NO dataset delete, NO disconnect (nothing mutated)');
}
{
    my ($ok, $err, $werr) = run_free(in_use => 0);
    ok($ok, 'device not in use -> free_image works as before') or diag($err);
    is_deeply(\@events, ['in_use_check', 'delete_namespace', 'delete_dataset'],
        '  ...check first, then namespace, then the worker deletes the zvol');
    ok(!$werr, '  ...and the worker does not die');
}
{
    my ($ok, $err) = run_free(selector => undef);
    ok($ok, 'volume not attached on this node (no device) -> free proceeds') or diag($err);
    is_deeply(\@events, ['delete_namespace', 'delete_dataset'], '  ...and no in-use check is needed');
}
{
    my ($ok, $err, $werr) = run_free(in_use => 0, dataset_dies => 1);
    ok($ok, 'namespace gone, zvol delete fails: free_image itself returned the worker');
    ok($werr, '  ...and the worker dies');
    like($werr // '', qr/\Q$DS\E/, '  ...naming the zvol that is left behind');
    like($werr // '', qr/left behind|orphan/i, '  ...saying it is left behind');
    like($werr // '', qr/namespace.*(already )?(removed|deleted)/i, '  ...and that the namespace is already gone');
    like($werr // '', qr/EBUSY/, '  ...keeping the original cause');
}

done_testing;
