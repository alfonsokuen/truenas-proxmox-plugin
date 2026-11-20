#!/usr/bin/perl
# Verifies the per-storage TTL knob (#147). The fork keeps the existing
# default of 30 s in memory and 15 s on disk. An explicit value applies
# to both caches, including when it equals a default.
#
# Run with:  prove -v -I t/nvme/lib t/nvme/09-status-capacity-ttl-knob.t

use strict;
use warnings;
use Test::More;
use FindBin;

my $PLUGIN = "$FindBin::Bin/../../TrueNASPlugin.pm";
unless (eval { require $PLUGIN; 1 }) {
    plan skip_all => "cannot load TrueNASPlugin.pm: $@";
}
my $PKG = 'PVE::Storage::Custom::TrueNASPlugin';
plan skip_all => "_status_capacity_ttl_s helper missing"
    unless $PKG->can('_status_capacity_ttl_s');

sub _ttl { no strict 'refs'; return &{"${PKG}::_status_capacity_ttl_s"}(@_); }

# Defaults
is(_ttl({}), 30, "unset -> 30 (STATUS_CAPACITY_TTL_S)");
is(_ttl({ tn_status_capacity_ttl_s => undef }), 30, "undef -> 30");
is(_ttl({ tn_status_capacity_ttl_s => 'nope' }), 30, "non-numeric -> 30");
is(_ttl({ tn_status_capacity_ttl_s => 0 }), 30, "zero -> 30 (rejected as invalid)");
is(_ttl({ tn_status_capacity_ttl_s => -5 }), 30, "negative -> 30");

is(_ttl({}, 15), 15, "stamp keeps its 15 second default");
is(_ttl({ tn_status_capacity_ttl_s => 30 }, 15), 30, "stamp honors explicit 30");
is(_ttl({ tn_status_capacity_ttl_s => 10 }, 15), 10, "stamp honors explicit 10");
is(_ttl({ tn_status_capacity_ttl_s => 3601 }), 30, "over maximum falls back");

# Honoured values
is(_ttl({ tn_status_capacity_ttl_s => 1 }),   1,   "1 honoured");
is(_ttl({ tn_status_capacity_ttl_s => 60 }),  60,  "60 honoured");
is(_ttl({ tn_status_capacity_ttl_s => 120 }), 120, "120 (reporter's value) honoured");
is(_ttl({ tn_status_capacity_ttl_s => 3600 }),3600,"3600 (max) honoured");

# The stamp read path should pick up the knob too. We don't execute
# _read_status_stamp here (it touches /run); we assert the helper is
# used from status() by grep-ing the source once.
my $src = do { local $/; open(my $fh, '<', $PLUGIN) or die; <$fh> };
like($src, qr/_get_cached\(\s*\$host_key,\s*\$status_method,\s*_status_capacity_ttl_s\(\$scfg\)\)/,
    "status() in-process cache uses the knob");
like($src, qr/_status_capacity_ttl_s\(\$scfg, \$STATUS_CAPACITY_STAMP_TTL_S\)/,
    "stamp-read path reads the knob");

done_testing();
