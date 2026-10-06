#!/usr/bin/perl
# The in-use gate in front of `nvme disconnect` must fail CLOSED. It used to run
# `fuser -s` and read every failure as "free"; a mounted filesystem or a dm/LVM
# holder has no process with the node open, and rc=1 mixes "nobody has it" with
# "could not look". Built here on a fake sysfs / mountinfo / fuser, no hardware.
#
# Run with:  prove -v t/nvme/33-in-use-gate.t
use strict;
use warnings;
use Test::More;
use FindBin;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

my $PLUGIN = "$FindBin::Bin/../../TrueNASPlugin.pm";
unless (eval { require $PLUGIN; 1 }) {
    plan skip_all => "cannot load TrueNASPlugin.pm (needs PVE perl modules): $@";
}
my $PKG = 'PVE::Storage::Custom::TrueNASPlugin';
my $check = $PKG->can('_nvme_check_devices_in_use') or BAIL_OUT('missing');
my $busy  = $PKG->can('_nvme_subsystem_busy');
my $NQN = 'nqn.2011-06.com.example:pilot';
my $scfg = { tn_subsystem_nqn => $NQN };

{
    no strict 'refs'; no warnings 'redefine';
    *{"${PKG}::_log"} = sub { 1 };
}

# One fake host: nvme0n1 (+ partition nvme0n1p1) and its path nvme0c0n1, both
# on our subsystem, major:minor 259:0 / 259:1 / 259:2.
sub world {
    my (%o) = @_;
    my $root = tempdir(CLEANUP => 1);
    for my $d (['nvme0n1', '259:0'], ['nvme0c0n1', '259:2']) {
        my ($n, $mm) = @$d;
        make_path("$root/block/$n/device", "$root/block/$n/holders");
        open(my $f, '>', "$root/block/$n/dev") or die; print $f "$mm\n"; close $f;
        open($f, '>', "$root/block/$n/device/subsysnqn") or die; print $f "$NQN\n"; close $f;
    }
    make_path("$root/block/nvme0n1/nvme0n1p1/holders");
    open(my $f, '>', "$root/block/nvme0n1/nvme0n1p1/dev") or die; print $f "259:1\n"; close $f;
    open($f, '>', "$root/mountinfo") or die;
    print $f "26 1 8:3 / / rw - ext4 /dev/sda3 rw\n";
    print $f $o{mount} . "\n" if $o{mount};
    close $f;
    make_path("$root/block/nvme0n1/holders/dm-0") if $o{holder};
    return $root;
}
sub gate {
    my ($root, $fuser_rc, @paths) = @_;
    no strict 'refs';
    local ${"${PKG}::_NVME_SYSFS"}     = $root;
    local ${"${PKG}::_NVME_MOUNTINFO"} = "$root/mountinfo";
    local ${"${PKG}::_NVME_FUSER_RC"}  = sub { $fuser_rc };
    @paths = ('/dev/nvme0n1') unless @paths;
    return $check->($scfg, @paths);
}

# --- RED cases: each of these used to read as "free" ------------------------
is(gate(world(mount => '40 26 259:0 / /mnt/data rw - ext4 /dev/nvme0n1 rw'), 1), 1,
    '(1) a mounted filesystem with no process holding the node is IN USE');
is(gate(world(mount => '40 26 259:1 / /mnt/p rw - ext4 /dev/nvme0n1p1 rw'), 1), 1,
    '(1b) a mounted PARTITION is in use');
is(gate(world(mount => '40 26 259:0 / /mnt/data rw - ext4 /dev/nvme0n1 rw'), 1, '/dev/nvme0c0n1'), 1,
    '(1c) a mount on the HEAD makes its path device nvme0c0n1 in use');
is(gate(world(holder => 1), 1), 1, '(2) a dm/LVM holder is IN USE');
is(gate(world(), 2), 1, '(3) fuser exiting 2 (could not look) is IN USE');
is(gate(world(), undef), 1, '(3b) fuser that could not run at all is IN USE');
is(gate(world(), 0), 1, '(a) fuser exiting 0 is in use');
{
    no strict 'refs';
    my $r = world();
    local ${"${PKG}::_NVME_SYSFS"}     = "$r/does-not-exist";
    local ${"${PKG}::_NVME_MOUNTINFO"} = "$r/mountinfo";
    local ${"${PKG}::_NVME_FUSER_RC"}  = sub { 1 };
    is($check->($scfg, '/dev/nvme0n1'), 1, '(4) an unreadable sysfs is IN USE, not "no devices"');
    my @r = $busy->($scfg);
    is($r[0], 1, '(4b) the enumeration that fails is BUSY, not an empty "free" list');
}
{
    no strict 'refs';
    my $r = world();
    unlink "$r/block/nvme0n1/dev";
    is(gate($r, 1), 1, '(e) a device with no readable dev number is IN USE');
    local ${"${PKG}::_NVME_SYSFS"}     = $r;
    local ${"${PKG}::_NVME_MOUNTINFO"} = "$r/nope";
    local ${"${PKG}::_NVME_FUSER_RC"}  = sub { 1 };
    is($check->($scfg, '/dev/nvme0c0n1'), 1, '(e2) an unreadable mountinfo is IN USE');
}
is(gate(world(), 1, '/dev/sda'), 1, 'an unrecognised device name is treated as in use');

# --- GREEN: positively free --------------------------------------------------
is(gate(world(), 1), 0, 'a really free device (no mount, no holder, fuser rc=1) is free');
is(gate(world(), 1, '/dev/nvme0n1', '/dev/nvme0c0n1'), 0, '  ...including its multipath path device');
is(gate(world(mount => '40 26 8:5 / /mnt/other rw - ext4 /dev/sdb1 rw'), 1), 0,
    '  ...an unrelated mount does not count');
{
    no strict 'refs';
    my $r = world();
    local ${"${PKG}::_NVME_SYSFS"}     = $r;
    local ${"${PKG}::_NVME_MOUNTINFO"} = "$r/mountinfo";
    local ${"${PKG}::_NVME_FUSER_RC"}  = sub { 1 };
    my ($b, @p) = $busy->($scfg);
    is($b, 0, 'the subsystem gate: enumerated, nothing in use -> not busy');
    is_deeply([sort @p], ['/dev/nvme0c0n1', '/dev/nvme0n1'], '  ...and it enumerated both devices');
}
is(gate(world(), 1, ()), 0, 'default path list works');
is($check->($scfg), 0, 'no devices at all is free (nothing to protect)');

done_testing;
