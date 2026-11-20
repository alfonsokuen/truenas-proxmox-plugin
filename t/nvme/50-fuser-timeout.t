#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use FindBin;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC sleep);

my $PLUGIN = "$FindBin::Bin/../../TrueNASPlugin.pm";
unless (eval { require $PLUGIN; 1 }) {
    plan skip_all => "cannot load TrueNASPlugin.pm (needs PVE perl modules): $@";
}
my $PKG = 'PVE::Storage::Custom::TrueNASPlugin';
my $check = $PKG->can('_nvme_check_devices_in_use') or BAIL_OUT('missing in-use gate');

my $root = tempdir(CLEANUP => 1);
make_path("$root/block/nvme0n1/holders", "$root/proc");
open(my $dev, '>', "$root/block/nvme0n1/dev") or die "dev: $!";
print {$dev} "259:1\n";
close($dev) or die "dev: $!";
open(my $mi, '>', "$root/mountinfo") or die "mountinfo: $!";
close($mi) or die "mountinfo: $!";

my @logs;
no strict 'refs';
no warnings 'once', 'redefine';
local *{"${PKG}::_log"} = sub { push @logs, $_[3] };
local ${"${PKG}::_NVME_SYSFS"} = $root;
local ${"${PKG}::_NVME_MOUNTINFO"} = "$root/mountinfo";
local ${"${PKG}::_NVME_PROC_ROOT"} = "$root/proc";

for my $case ([1, 0], [0, 1], [2, 1], [undef, 1]) {
    my ($rc, $expected) = @$case;
    local ${"${PKG}::_NVME_FUSER_RC"} = sub { $rc };
    is($check->({}, '/dev/nvme0n1'), $expected,
        'the gate preserves fuser status ' . ($rc // 'unavailable'));
}

is(${"${PKG}::_NVME_FUSER_TIMEOUT"}, 10, 'the production fuser budget is 10 seconds');
{
    # Leave the rest of the in-use gate real. A late rc=1 must not turn a
    # timed-out probe into "free", or hold the storage lock until it returns.
    local ${"${PKG}::_NVME_FUSER_TIMEOUT"} = 0.15;
    local ${"${PKG}::_NVME_FUSER_RC"} = sub { sleep(1.2); return 1 };
    my $start = clock_gettime(CLOCK_MONOTONIC);
    is($check->({}, '/dev/nvme0n1'), 1, 'a timed-out fuser is treated as in use');
    cmp_ok(clock_gettime(CLOCK_MONOTONIC) - $start, '<', 1,
        'the gate returns before the stalled probe finishes');
    like(join(' ', @logs), qr/fuser.*timed out/, 'the timeout is reported');
}

done_testing;
