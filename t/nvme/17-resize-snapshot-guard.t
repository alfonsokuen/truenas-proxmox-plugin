#!/usr/bin/perl
# volume_resize() must refuse a snapshot target, loudly, before touching TrueNAS.
#
# Storage APIVER 15 added an optional 7th argument to volume_resize():
#
#   sub volume_resize { my ($class, $scfg, $storeid, $volname, $size,
#                           $running, $snapname) = @_; ... }
#
# This plugin used to capture (..., $new_size_bytes, @rest) and swallow
# $snapname. A caller passing a snapshot target would then have grown the LIVE
# zvol instead, with no error - silent corruption of a volume in use. ZFS
# snapshots are immutable, so there is nothing to resize: the only correct
# answer is to refuse.
#
# The guard shipped in 2.1.24~alpha1+idk10 with no test at all. An audit
# deleted the die() and all 348 tests in t/nvme stayed green, which is exactly
# the coverage gap this file closes: a fix whose declared failure mode is
# silent data corruption must have a regression test that goes red without it.
#
# Run with:  prove -v t/nvme/17-resize-snapshot-guard.t

use strict;
use warnings;
use Test::More;
use FindBin;
use File::Spec;

my $PLUGIN_FILE = File::Spec->rel2abs("$FindBin::Bin/../../TrueNASPlugin.pm");
plan skip_all => "TrueNASPlugin.pm not found at $PLUGIN_FILE" unless -f $PLUGIN_FILE;

# Only a missing PVE installation earns a skip. Anything else is a failure:
# a test that cannot tell "no PVE here" from "the plugin is broken" reports
# green for a plugin that does not load.
unless (eval { require $PLUGIN_FILE; 1 }) {
    my $err = $@ || 'unknown error';
    plan skip_all => "no PVE perl modules here (needs libpve-storage-perl)"
        if $err =~ m{Can't locate PVE/(?:Tools|JSONSchema|Storage/Plugin)\.pm};
    plan tests => 1;
    fail("the plugin did not load, and not for lack of PVE");
    diag($err);
    exit 1;
}

my $P = 'PVE::Storage::Custom::TrueNASPlugin';
plan tests => 6;

# Deliberately incomplete: no api_host, no api_key, no dataset. If the guard
# lets a call through, it dies further down on the missing config - which is
# how we prove the refusal happens BEFORE anything reaches the array.
my $scfg = { tn_transport_mode => 'nvme-tcp' };
my $RE   = qr/resizing a snapshot is not supported/;

sub resize_dies {
    my (@args) = @_;
    my $ok = eval { $P->volume_resize($scfg, 'tn-prod', 'vol-zz-lun0', 1024, @args); 1 };
    return $ok ? '' : ($@ // '');
}

# 1-2. With a snapshot name: must refuse, by name, not by accident.
my $err = resize_dies(0, 'snap1');
ok($err, 'con snapname: volume_resize muere en vez de continuar');
like($err, $RE, '  ...y lo hace con el mensaje del guard, no con otro fallo');

# 3. The refusal must precede any call to the array. If the guard were absent,
#    execution would reach the API layer and die about the missing config
#    instead - so the ABSENCE of that error is what proves the ordering.
unlike($err, qr/api_host|api_key|broker|JSON-RPC|scfg missing/i,
    '  ...antes de tocar la API de TrueNAS (no hay error de conexion ni de config)');

# 4. $running must not change the verdict: a snapshot is immutable either way.
like(resize_dies(1, 'snap1'), $RE, 'con snapname y running=1: tambien refuta');

# 5. The guard keys on defined(), so the empty string is NOT a snapshot target.
#    The base plugin uses truthiness and '' is falsy there too, so this keeps
#    the two in step rather than diverging.
unlike(resize_dies(0, ''), $RE, "snapname vacio: el guard NO dispara");

# 6. And the direction that matters for regressions: a normal resize must get
#    past the guard. It still dies - there is no TrueNAS to talk to - but the
#    message must not be the guard's.
unlike(resize_dies(0), $RE, 'sin snapname: el guard no sobredispara');
