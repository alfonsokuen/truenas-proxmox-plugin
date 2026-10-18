#!/usr/bin/perl
# A CT rootfs can be mounted only in its own mount namespace. No hardware needed.
use strict;
use warnings;
use Test::More;
use FindBin;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

# Windows cannot create proc-style mnt:[inode] symlinks. Supply only their
# readlink values; all directory enumeration and mountinfo reads stay real.
our %NS_LINK;
BEGIN {
    *CORE::GLOBAL::readlink = sub {
        return $NS_LINK{$_[0]} if exists $NS_LINK{$_[0]};
        return CORE::readlink($_[0]);
    };
}

my $PLUGIN = "$FindBin::Bin/../../TrueNASPlugin.pm";
unless (eval { require $PLUGIN; 1 }) {
    plan skip_all => "cannot load TrueNASPlugin.pm (needs PVE perl modules): $@";
}
my $PKG = 'PVE::Storage::Custom::TrueNASPlugin';
my $check = $PKG->can('_nvme_check_devices_in_use') or BAIL_OUT('missing');
{
    no strict 'refs'; no warnings 'redefine';
    *{"${PKG}::_log"} = sub { 1 };
}

sub write_file {
    my ($path, $body) = @_;
    open(my $fh, '>', $path) or die "cannot write $path: $!";
    print $fh $body;
    close($fh) or die "cannot close $path: $!";
}

sub world {
    my (%o) = @_;
    my $root = tempdir(CLEANUP => 1);
    make_path("$root/block/nvme6n45/holders", "$root/proc/101/ns", "$root/proc/202/ns");
    write_file("$root/block/nvme6n45/dev", "259:45\n");
    write_file("$root/host-mountinfo", "26 1 8:3 / / rw - ext4 /dev/sda3 rw\n");
    write_file("$root/proc/101/mountinfo", "26 1 8:3 / / rw - ext4 /dev/sda3 rw\n");
    write_file("$root/proc/202/mountinfo", $o{ct_mount} // "26 1 8:3 / / rw - ext4 /dev/sda3 rw\n");
    %NS_LINK = (
        "$root/proc/self/ns/mnt" => 'mnt:[101]',
        "$root/proc/101/ns/mnt" => 'mnt:[101]',
        "$root/proc/202/ns/mnt" => 'mnt:[202]',
    );
    return $root;
}

sub gate {
    my ($root, $proc) = @_;
    no strict 'refs';
    local ${"${PKG}::_NVME_SYSFS"}     = $root;
    local ${"${PKG}::_NVME_MOUNTINFO"} = "$root/host-mountinfo";
    local ${"${PKG}::_NVME_PROC_ROOT"} = $proc // "$root/proc";
    local ${"${PKG}::_NVME_FUSER_RC"}  = sub { 1 };
    return $check->({}, '/dev/nvme6n45');
}

my $ct_mount = "40 26 259:45 / / rw - ext4 /dev/nvme6n45 rw\n";
is(gate(world(ct_mount => $ct_mount)), 1,
    'CT-only mount in a second namespace is in use despite host mountinfo and fuser rc=1');
is(gate(world(ct_mount => "40 26 259:45 / / rw - ext4 /dev/mapper/other rw\n")), 1,
    'CT mount also matches the device major:minor');
is(gate(world(ct_mount => "40 26 8:3 / / rw - ext4 /dev/nvme6n45 rw\n")), 1,
    'CT mount also matches the device source name');
is(gate(world()), 0, 'two namespaces without an NVMe mount are free');
{
    my $root = world();
    write_file("$root/not-a-directory", "x");
    is(gate($root, "$root/not-a-directory"), 1, 'unreadable proc directory fails closed');
}
{
    my $root = world();
    make_path("$root/proc/303"); # disappears before its ns/mnt can be read
    is(gate($root), 0, 'a PID whose namespace link vanished is ignored');
}
{
    my $root = world();
    unlink "$root/proc/202/mountinfo" or die $!;
    is(gate($root), 0, 'a PID whose mountinfo vanished after readlink is ignored');
}
{
    my $root = world();
    make_path("$root/proc/404/ns/mnt"); # readlink fails with EINVAL, not ENOENT
    is(gate($root), 1, 'an existing PID whose namespace cannot be read fails closed');
}

done_testing;
