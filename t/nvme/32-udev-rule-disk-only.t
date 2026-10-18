#!/usr/bin/perl
# The NVMe namespace-head queue limit is not writable on partition devices.
# Keep the packaged rule scoped to whole disks.
#
# Run with:  prove -v t/nvme/32-udev-rule-disk-only.t
use strict;
use warnings;
use Test::More;
use FindBin;

my $RULE = $ENV{UDEV_RULE_FILE}
    || "$FindBin::Bin/../../tools/udev/99-nvme-tcp-max-sectors.rules";
open(my $fh, '<', $RULE) or die "cannot read $RULE: $!";
my $rule = do { local $/; <$fh> };
close $fh;

my $active = join ' ', grep { /^\s*[^#\s]/ } split /\n/, $rule;
ok(length($active), 'active udev rule found');
$active =~ s/\\\s*/ /g;
my ($kernel) = $active =~ /\bKERNEL=="([^"]+)"/;
my ($devtype) = $active =~ /\bENV\{DEVTYPE\}=="([^"]+)"/;
ok(defined $kernel, 'KERNEL glob found in active rule');
ok(defined $devtype, 'DEVTYPE condition found in active rule');

sub glob_matches {
    my ($glob, $value) = @_;
    $glob =~ s/([.\+\^\$\(\)\{\}\|\\])/\\$1/g;
    $glob =~ s/\*/.*/g;
    $glob =~ s/\?/./g;
    return $value =~ /^$glob$/;
}

sub rule_matches {
    my ($kernel_glob, $expected_type, $name, $type) = @_;
    return glob_matches($kernel_glob, $name) && $type eq $expected_type;
}

for my $disk (qw(nvme6n2 nvme6n64)) {
    ok(rule_matches($kernel // '', $devtype // '', $disk, 'disk'), "$disk whole disk matches");
}
for my $partition (qw(nvme6n2p1 nvme6n64p3)) {
    ok(!rule_matches($kernel // '', $devtype // '', $partition, 'partition'), "$partition partition does not match");
}

like($active, qr/\bATTRS\{subsysnqn\}=="nqn\.\*truenas\*"/, 'TrueNAS subsystem NQN condition is preserved');
like($active, qr/\bATTR\{queue\/max_sectors_kb\}="1024"/, 'queue cap remains 1024');
done_testing;
