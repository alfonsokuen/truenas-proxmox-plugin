#!/usr/bin/perl
# The command-size cap lives in two places: the in-plugin _nvme_cap_max_io
# (default NVME_DEFAULT_MAX_IO_KB, rewritten on every revalidation) and the
# packaged udev rule. If they disagree, each revalidation "repairs" the other's
# value and logs a drift that is not one. The rule must carry the plugin's
# default.
#
# Run with:  prove -v t/nvme/31-udev-cap-single-source.t
use strict;
use warnings;
use Test::More;
use FindBin;

my $PLUGIN = "$FindBin::Bin/../../TrueNASPlugin.pm";
my $RULE   = "$FindBin::Bin/../../tools/udev/99-nvme-tcp-max-sectors.rules";
open(my $fh, '<', $PLUGIN) or die; my $src = do { local $/; <$fh> }; close $fh;
my ($default) = $src =~ /NVME_DEFAULT_MAX_IO_KB\s*=>\s*(\d+)/;
ok($default, "plugin default found ($default)");
open($fh, '<', $RULE) or die; my $rule = do { local $/; <$fh> }; close $fh;
my ($value) = $rule =~ /^[^#\n]*ATTR\{queue\/max_sectors_kb\}="(\d+)"/m;
ok($value, "rule value found ($value)");
is($value, $default, 'the udev rule and the in-plugin default are the same number');
my ($says) = $rule =~ /# must say (\d+)/;
is($says, $default, '  ...and the rule\'s own verification line says the same');
done_testing;
