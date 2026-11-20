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
# A lookup that cannot tell (it dies, answers nothing readable, the API query
# behind it failed, or the local sysfs enumeration did not complete) is NOT
# "not attached": the in-use check never ran,
# so free_image dies before touching TrueNAS. Only a selector that positively
# found no matching device on this node lets the free go on unchecked.
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

my (@events, @checked, $selector, $selector_dies, $resolve_err, $in_use, $dataset_delete_dies);
{
    no strict 'refs'; no warnings 'redefine';
    *{"${PKG}::_log"} = sub { 1 };
    *{"${PKG}::_defer_after_lock"} = sub { 1 };
    *{"${PKG}::_assert_nvme_cluster_unreferenced"} = sub { 1 };
    *{"${PKG}::_nvme_pending_free_mark"} = sub { 1 };
    *{"${PKG}::run_command"} = sub { 1 };
    *{"${PKG}::_assert_no_child_datasets"} = sub { 1 };
    *{"${PKG}::_nvme_disconnect"} = sub { push @events, 'nvme_disconnect'; 1 };
    *{"${PKG}::_nvme_find_device_by_subsystem"} = sub {
        push @events, 'lookup';
        die $selector_dies if $selector_dies;
        $selector;
    };
    *{"${PKG}::_resolve_nvme_uuid"} = sub {
        my ($s, $z, $known) = @_;
        return $known if defined $known;
        die $resolve_err if $resolve_err;
        return $UUID;
    };
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
    $selector_dies = $o{selector_dies};
    $resolve_err = $o{resolve_err};
    $in_use = $o{in_use};
    $dataset_delete_dies = $o{dataset_dies};
    (@events, @checked) = ();
    my ($worker_err, $worker);
    my $vol = $o{vol} // $VOL;
    my $ok = eval { $worker = $PKG->free_image('store', $scfg, $vol, 0, 'raw'); 1 };
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
    is_deeply(\@events, ['lookup', 'in_use_check'],
        '  ...with NO namespace delete, NO dataset delete, NO disconnect (nothing mutated)');
}
{
    my ($ok, $err, $werr) = run_free(in_use => 0);
    ok($ok, 'device not in use -> free_image works as before') or diag($err);
    is_deeply(\@events, ['lookup', 'in_use_check', 'delete_namespace', 'delete_dataset'],
        '  ...check first, then namespace, then the worker deletes the zvol');
    ok(!$werr, '  ...and the worker does not die');
}

# The lookup could not tell: fail closed, before any TrueNAS call.
my @undecided = (
    [ 'selector dies (sysfs/API exception)', selector_dies => "connection refused
" ],
    [ 'selector returns nothing (undef)', selector => undef ],
    [ 'selector returns a non-hash answer', selector => 'garbage' ],
    [ 'selector API query failed (TrueNAS down)', selector => {
        selector_outcome => 'metadata_failure', mismatch_reason => 'namespace_metadata_query_failed',
        linux_device_count => 1 } ],
    [ 'selector claims a match but names no device', selector => {
        selector_outcome => 'exact_match', linux_device_count => 1 } ],
    [ 'selector answers with an unknown outcome', selector => { linux_device_count => 1 } ],
    [ 'selector could not enumerate local NVMe devices (sysfs read failed)', selector => {
        selector_outcome => 'enumeration_failed', mismatch_reason => 'sysfs_enumeration_failed',
        underlying_outcome => 'publication_mismatch', linux_device_count => 2, enumeration_complete => 0,
        enumeration_errors => ['read /sys/block/nvme0n2/uuid: Is a directory'] } ],
    [ 'publication_mismatch not marked as a complete enumeration', selector => {
        selector_outcome => 'publication_mismatch', mismatch_reason => 'subsystem_not_visible',
        linux_device_count => 0 } ],
    [ 'cloud-init volume (no embedded UUID), namespace lookup errors (API down)',
        vol => 'vm-101-cloudinit', resolve_err => "API call nvmet.namespace.query failed: timeout
" ],
);
for my $c (@undecided) {
    my ($name, %o) = @$c;
    my ($ok, $err) = run_free(%o);
    ok(!$ok, "$name -> free_image dies");
    like($err // '', qr/could not (tell|check)/i, '  ...saying the in-use check could not be made');
    like($err // '', qr/\Q$VOL\E|vm-101-cloudinit/, '  ...naming the volume');
    ok(!grep({ /delete_namespace|delete_dataset|nvme_disconnect|in_use_check/ } @events),
        '  ...with nothing mutated on TrueNAS') or diag("events: @events");
}

# The selector positively found no device for this namespace here (the volume
# is not attached on this node: a stopped guest, the normal case): free goes on.
# "Positively" means enumeration_complete: every sysfs listing and read of the
# walk succeeded (t/nvme/44 runs the real selector over a scratch sysfs).
#
# Why "three local devices, none matched -> proceeds" is safe: those three are
# the complete set of this subsystem's devices on this node, each with a
# readable identity. The selector tries NGUID, then the namespace UUID, before
# NSID; a device carrying this namespace's UUID or NGUID is selected
# (exact_match) and then checked for use, never reported as a mismatch. None
# did, so this namespace is not attached here and no local guest can hold it
# open. nguid_contradicted says the same thing from the other side: the
# devices carry real identities that are not ours. Use on OTHER nodes is not
# visible here. The separate cluster reference check is exercised in t/nvme/48.
my @absent = (
    [ 'subsystem not connected on this node', {
        selector_outcome => 'publication_mismatch', mismatch_reason => 'subsystem_not_visible',
        linux_device_count => 0, enumeration_complete => 1 } ],
    [ 'subsystem connected, this namespace not among its three devices', {
        selector_outcome => 'publication_mismatch',
        mismatch_reason => 'namespace_metadata_did_not_match_visible_devices',
        linux_device_count => 3, nguid_contradicted => 1, enumeration_complete => 1 } ],
    [ 'namespace already gone on TrueNAS, no local device carries its UUID', {
        selector_outcome => 'metadata_failure', mismatch_reason => 'namespace_uuid_not_returned',
        linux_device_count => 2, enumeration_complete => 1 } ],
);
for my $c (@absent) {
    my ($name, $sel) = @$c;
    my ($ok, $err, $werr) = run_free(selector => $sel);
    ok($ok, "$name -> free proceeds") or diag($err);
    is_deeply(\@events, ['lookup', 'delete_namespace', 'delete_dataset'],
        '  ...with no in-use check (no local device to check)');
}
{
    my ($ok, $err) = run_free(vol => 'vm-101-cloudinit',
        resolve_err => "Could not locate NVMe namespace for 'vm-101-cloudinit'
");
    ok($ok, 'cloud-init volume whose namespace TrueNAS no longer has -> free proceeds') or diag($err);
    is_deeply(\@events, ['delete_namespace', 'delete_dataset'], '  ...nothing exported, nothing to check');
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
