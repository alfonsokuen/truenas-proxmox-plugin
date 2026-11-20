#!/usr/bin/perl
# free_image and a local NVMe enumeration that could not be completed.
#
# free_image skips the in-use check only when the device selector says, with
# certainty, that no device of this node carries the volume's namespace
# (publication_mismatch). That certainty rests on the sysfs walk having seen
# everything: the nvme-subsystem class, our subsystem's NQN, /sys/block, and
# the NQN and identity (nsid, uuid) of every candidate device. The selector
# used to answer publication_mismatch also when that walk FAILED (opendir or a
# read refused), so a device still open by a guest could be freed unchecked.
# A failed or partial walk is now its own outcome, enumeration_failed, and
# free_image dies on it before any TrueNAS call. A complete walk that finds no
# match still lets the free go on.
#
# Runs the REAL _nvme_find_device_by_subsystem against a scratch sysfs tree
# ($_NVME_SYSFS). Read failures are made the way root can still hit them: a
# directory where an attribute file should be (read gives EISDIR) and a file
# where a directory should be (opendir gives ENOTDIR).
#
# Run with:  prove -v t/nvme/44-free-selector-enumeration.t
use strict;
use warnings;
use Test::More;
use FindBin;
use File::Temp qw(tempdir);
use File::Path qw(make_path remove_tree);

my $PLUGIN = "$FindBin::Bin/../../TrueNASPlugin.pm";
unless (eval { require $PLUGIN; 1 }) {
    plan skip_all => "cannot load TrueNASPlugin.pm (needs PVE perl modules): $@";
}
my $PKG   = 'PVE::Storage::Custom::TrueNASPlugin';
my $NQN   = 'nqn.2011-06.com.truenas:uuid:test:pve';
my $UUID  = '11111111-2222-3333-4444-555555555555';
my $VOL   = "vol-vm-101-disk-0-ns$UUID";
my $scfg  = { tn_dataset => 'tank/pve', tn_api_host => '198.51.100.7', tn_transport_mode => 'nvme-tcp',
              tn_subsystem_nqn => $NQN };
my @OTHER = map { sprintf('aaaaaaaa-0000-0000-0000-%012d', $_) } 1 .. 3;

my $root = tempdir(CLEANUP => 1);
my (@events, @checked, $in_use);
{
    no strict 'refs'; no warnings 'redefine', 'once';
    ${"${PKG}::_NVME_SYSFS"} = $root;
    *{"${PKG}::_log"} = sub { 1 };
    *{"${PKG}::_defer_after_lock"} = sub { 1 };
    *{"${PKG}::_assert_nvme_cluster_unreferenced"} = sub { 1 };
    *{"${PKG}::_nvme_pending_free_mark"} = sub { 1 };
    *{"${PKG}::run_command"} = sub { 1 };
    *{"${PKG}::_assert_no_child_datasets"} = sub { 1 };
    *{"${PKG}::_verify_devices_disconnected"} = sub { 1 };
    *{"${PKG}::_nvme_disconnect"} = sub { push @events, 'nvme_disconnect'; 1 };
    *{"${PKG}::_nvme_get_namespace_selector_metadata"} = sub {
        push @events, 'lookup';
        return { namespace => { device_uuid => $UUID, nsid => 9, subsys => 1 },
                 api_namespace_count => 4, metadata_state => 'ok', metadata_error => undef };
    };
    *{"${PKG}::_nvme_check_devices_in_use"} = sub {
        my ($s, @paths) = @_;
        push @checked, @paths;
        push @events, 'in_use_check';
        return $in_use;
    };
    *{"${PKG}::_nvme_delete_namespace"} = sub { push @events, 'delete_namespace'; 1 };
    *{"${PKG}::_delete_dataset_with_retry"} = sub { push @events, 'delete_dataset'; 1 };
    *{"${PKG}::_api_call"} = sub { [] };
}

sub put {
    my ($path, $val) = @_;
    (my $dir = $path) =~ s{/[^/]+$}{};
    make_path($dir);
    open(my $fh, '>', $path) or die "$path: $!";
    print $fh "$val\n";
    close $fh;
}

# A directory where a file is expected: open succeeds, the read fails (EISDIR).
sub unreadable { make_path($_[0]) }

# %o: subsys => { name => nqn }, devs => { name => { nqn, nsid, uuid } },
# then a list of paths (relative to the root) to turn unreadable / into files.
sub tree {
    my (%o) = @_;
    remove_tree("$root/class", "$root/block");
    make_path("$root/class/nvme-subsystem", "$root/block");
    for my $s (keys %{ $o{subsys} // {} }) {
        put("$root/class/nvme-subsystem/$s/subsysnqn", $o{subsys}{$s});
    }
    for my $d (keys %{ $o{devs} // {} }) {
        my $a = $o{devs}{$d};
        put("$root/block/$d/device/subsysnqn", $a->{nqn} // $NQN);
        put("$root/block/$d/nsid", $a->{nsid}) if defined $a->{nsid};
        put("$root/block/$d/uuid", $a->{uuid}) if defined $a->{uuid};
    }
    for my $p (@{ $o{unreadable} // [] }) {
        unlink("$root/$p");
        unreadable("$root/$p");
    }
    for my $p (@{ $o{as_file} // [] }) {
        remove_tree("$root/$p");
        put("$root/$p", 'not a directory');
    }
    remove_tree("$root/$_") for @{ $o{remove} // [] };
}

sub ours { (subsys => { 'nvme-subsys0' => $NQN, %{ $_[0] // {} } }) }
sub three_others {
    return (devs => { map { ("nvme0n$_" => { nsid => $_, uuid => $OTHER[$_ - 1] }) } 1 .. 3 });
}

sub run_free {
    (@events, @checked) = ();
    $in_use = $_[0] // 0;
    my $ok = eval { my $w = $PKG->free_image('store', $scfg, $VOL, 0, 'raw'); $w->('UPID:t') if ref($w) eq 'CODE'; 1 };
    return ($ok, $@);
}

my @failed = (
    [ 'nvme-subsystem class cannot be listed (ENOTDIR)',
        ours(), three_others(), as_file => ['class/nvme-subsystem'] ],
    [ "our subsystem's subsysnqn cannot be read",
        ours(), three_others(), unreadable => ['class/nvme-subsystem/nvme-subsys0/subsysnqn'] ],
    [ '/sys/block cannot be listed',
        ours(), as_file => ['block'] ],
    [ "a block device's subsystem NQN cannot be read (it may be ours)",
        ours(), three_others(), unreadable => ['block/nvme0n2/device/subsysnqn'] ],
    [ "a device of our subsystem: its uuid cannot be read",
        ours(), three_others(), unreadable => ['block/nvme0n3/uuid'] ],
    [ "a device of our subsystem: its nsid cannot be read",
        ours(), three_others(), unreadable => ['block/nvme0n1/nsid'] ],
);
for my $c (@failed) {
    my ($name, %t) = @$c;
    tree(%t);
    my ($ok, $err) = run_free();
    ok(!$ok, "enumeration failed: $name -> free_image dies");
    like($err // '', qr/could not tell/i, '  ...saying the in-use check could not be made');
    like($err // '', qr/enumerat/i, '  ...blaming the local NVMe enumeration');
    ok(!grep({ /delete_namespace|delete_dataset|nvme_disconnect|in_use_check/ } @events),
        '  ...with nothing mutated on TrueNAS') or diag("events: @events");
}

# The selector's own answer, as the activate path and its error message see it.
{
    tree(ours(), three_others(), unreadable => ['block/nvme0n3/uuid']);
    my $r = $PKG->can('_nvme_find_device_by_subsystem')->($scfg, $UUID);
    is($r->{selector_outcome}, 'enumeration_failed', 'selector reports enumeration_failed, not publication_mismatch');
    ok(!$r->{enumeration_complete}, '  ...and does not mark the enumeration complete');
    is($r->{linux_device_count}, 3, '  ...keeping the device count the activate path keys on');
    like($PKG->can('_nvme_selector_failure_detail')->($r, $NQN) // '', qr/nvme0n3\/uuid/,
        '  ...and the failure detail names the read that failed');
}

# A complete walk that positively finds no device of ours: free goes on.
my @complete = (
    [ 'nvme core not loaded (no nvme-subsystem class at all)', remove => ['class/nvme-subsystem'] ],
    [ 'subsystem not connected on this node', subsys => { 'nvme-subsys0' => 'nqn.other:subsys' } ],
    # The case rev2 questioned. Three local devices of our subsystem, none ours:
    # every one has a readable, real uuid that is NOT this namespace's, so the
    # UUID tier (tried before NSID, see _nvme_select_namespace_device) would
    # have selected ours had it been here, and none has our nsid. The volume is
    # not attached on this node; there is no local device to check.
    [ 'our subsystem, three devices, none carries this namespace', ours(), three_others() ],
    [ 'an unrelated subsystem is unreadable, ours is found and has no match',
        ours({ 'nvme-subsys1' => 'nqn.other:subsys' }), three_others(),
        unreadable => ['class/nvme-subsystem/nvme-subsys1/subsysnqn'] ],
);
for my $c (@complete) {
    my ($name, %t) = @$c;
    tree(%t);
    my ($ok, $err) = run_free();
    ok($ok, "enumeration complete: $name -> free proceeds") or diag($err);
    is_deeply([grep { !/lookup/ } @events], ['delete_namespace', 'delete_dataset'],
        '  ...with no in-use check (no local device to check)') or diag("events: @events");
}

# And the walk still finds ours when it is there: checked, refused while open.
{
    tree(ours(), devs => { nvme0n1 => { nsid => 1, uuid => $OTHER[0] }, nvme0n2 => { nsid => 9, uuid => $UUID } });
    my ($ok, $err) = run_free(1);
    ok(!$ok, 'device carrying this namespace, open here -> free_image dies');
    is_deeply(\@checked, ['/dev/nvme0n2'], '  ...after checking exactly that device');
    ok(!grep({ /delete_namespace|delete_dataset/ } @events), '  ...with nothing mutated');
}

done_testing;
