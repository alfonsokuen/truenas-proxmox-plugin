#!/usr/bin/perl
# #134: run the fork gate against a fixture tree. This fork checks holders,
# mountinfo and /proc descriptors directly, without upstream fuser helpers.
use strict;
use warnings;
use Test::More;
use FindBin;
use File::Path qw(make_path);
use File::Temp qw(tempdir);

require "$FindBin::Bin/../../TrueNASPlugin.pm";
my $pkg = 'PVE::Storage::Custom::TrueNASPlugin';
my $check = $pkg->can('_nvme_check_devices_in_use');
my $root = tempdir(CLEANUP => 1);
my $head = "$root/sys/block/nvme0n1";
my $part = "$head/nvme0n1p1";
my $path = "$root/sys/block/nvme0c0n1";
make_path("$head/holders", "$part/holders", "$path/holders", "$root/proc");

sub write_file {
    my ($path, $content) = @_;
    open(my $fh, '>', $path) or die "open $path: $!";
    print $fh $content or die "write $path: $!";
    close($fh) or die "close $path: $!";
}

write_file("$head/dev", "259:0\n");
write_file("$part/dev", "259:1\n");
write_file("$path/hidden", "1\n");
write_file("$root/mountinfo", "26 1 8:3 / / rw - ext4 /dev/sda3 rw\n");

no strict 'refs';
no warnings 'redefine';
local ${$pkg . '::_NVME_SYSFS'} = "$root/sys";
local ${$pkg . '::_NVME_PROC_ROOT'} = "$root/proc";
local ${$pkg . '::_NVME_MOUNTINFO'} = "$root/mountinfo";
# Fork adaptation: the fuser step is an injectable runner. This fixture has no
# /usr/bin/fuser (and no real PIDs), so answer "nobody holds it" (rc 1); the
# sysfs, mountinfo and /proc signals below are what this test exercises.
local ${$pkg . q(::_NVME_FUSER_RC)} = sub { return 1 };
local *{$pkg . '::_log'} = sub {};
my @devices = ('/dev/nvme0c0n1');

is($check->({}), 0, 'empty device list is idle');
is($check->({}, @devices), 0, 'hidden path is covered by its idle head');

make_path("$part/holders/dm-0");
is($check->({}, @devices), 1, 'partition holder makes the head busy');
rmdir "$part/holders/dm-0" or die $!;

write_file("$root/mountinfo", "26 1 259:1 / /mnt/data rw - ext4 /dev/alias rw\n");
is($check->({}, @devices), 1, 'mount identified by major:minor through an alias');
unlink "$root/mountinfo" or die $!;
is($check->({}, @devices), 1, 'unreadable mountinfo fails closed');
write_file("$root/mountinfo", "26 1 8:3 / / rw - ext4 /dev/sda3 rw\n");

# Fork adaptation (#134): upstream's /proc descriptor helper (_nvme_proc_device_ids)
# and its maps/fd cases are not part of this fork's probe. This fork reads
# /proc through the PID-namespace loop covered by t/nvme/33-inuse-other-mount-namespace.t,
# so those cases are not repeated here.
unlink "$head/dev" or die $!;
is($check->({}, @devices), 1, 'hidden path with unreadable head ID fails closed');

done_testing;
