#!/usr/bin/perl
# #134: read the real NVMe sysfs layout. The fork validates the head
# and holders in the composed gate and does not use upstream fuser helpers.
use strict;
use warnings;
use Test::More;
use FindBin;
use File::Path qw(make_path);
use File::Temp qw(tempdir);

require "$FindBin::Bin/../../TrueNASPlugin.pm";
my $pkg = 'PVE::Storage::Custom::TrueNASPlugin';
my $check = $pkg->can('_nvme_check_devices_in_use');
my (@heads, @paths);
if (opendir(my $dh, '/sys/block')) {
    while (my $name = readdir($dh)) {
        push @heads, "/dev/$name" if $name =~ /^nvme\d+n\d+$/;
        push @paths, "/dev/$name" if $name =~ /^nvme\d+c\d+n\d+$/;
    }
    closedir($dh);
}
plan skip_all => 'no NVMe devices on this host' unless @heads;

my @log;
no strict 'refs';
no warnings 'redefine';
local *{$pkg . '::_log'} = sub { push @log, $_[3] };

# Empty fixture views isolate sysfs from host process permissions. A kernel
# holder is valid, but missing IDs on visible devices are probe failures.
my $root = tempdir(CLEANUP => 1);
make_path("$root/proc");
open(my $fh, '>', "$root/mountinfo") or die $!;
close($fh) or die $!;
{
    local ${$pkg . '::_NVME_PROC_ROOT'} = "$root/proc";
    local ${$pkg . '::_NVME_MOUNTINFO'} = "$root/mountinfo";
    for my $dev (sort @heads, @paths) {
        @log = ();
        my $result = $check->({}, $dev);
        like($result, qr/^[01]$/, "$dev returns a busy/idle result");
        my @errors = grep { /treating as in use/ } @log;
        is_deeply(\@errors, [], "$dev sysfs and head probe completes");
    }
}

my $result = $check->({}, @heads, @paths);
like($result, qr/^[01]$/, 'full real-host probe returns a busy/idle result');

done_testing;
