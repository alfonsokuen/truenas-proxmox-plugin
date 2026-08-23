#!/usr/bin/perl
# The bulk helpers must actually be callable.
#
# _api_call_mutate is declared with a three-parameter Perl signature, and a
# surplus argument to a signatured sub is fatal, not ignored:
#
#   $ perl -e 'sub f($a,$b,$c){} f(1,2,3,sub{})'
#   Too many arguments for subroutine 'main::f' (got 4; expected 3)
#
# _api_bulk_call passed four, so every route through it died before reaching
# TrueNAS. Nothing in the plugin calls the bulk helpers today - they are
# reached only from bulk_delete_snapshots, which is documented as an entry
# point for external callers - so the crash sat there unexercised. That is
# exactly the shape of bug a test should hold down, because the day someone
# wires bulk deletion up is the day it fires, in the deletion path.
#
# Reported upstream as issue #77.
#
# Run with:  prove -v t/nvme/04-bulk-arity.t

use strict;
use warnings;
use Test::More;
use FindBin;

my $PLUGIN = "$FindBin::Bin/../../TrueNASPlugin.pm";
unless (eval { require $PLUGIN; 1 }) {
    plan skip_all => "cannot load TrueNASPlugin.pm (needs PVE perl modules): $@";
}

my $PKG = 'PVE::Storage::Custom::TrueNASPlugin';

# Confirm the premise rather than assuming it: a signatured sub really does
# die on a surplus argument on this perl. If that ever stopped being true the
# tests below would pass for the wrong reason.
{
    my $died = !eval {
        my $f = eval 'use feature "signatures"; no warnings; sub ($a, $b, $c) { 1 }';
        $f->(1, 2, 3, 4);
        1;
    };
    ok($died, 'a surplus argument to a signatured sub is fatal on this perl');
}

my %sent;
{
    no strict 'refs';
    no warnings 'redefine';
    *{"${PKG}::_log"} = sub { 1 };
    # Capture what the bulk helper hands to the API layer without going near a
    # network. Only _api_call is stubbed: _api_call_mutate is left real,
    # because it is the signature that rejects the surplus argument and
    # stubbing it would defeat the point of the test.
    *{"${PKG}::_api_call"} = sub {
        my ($scfg, $method, $params) = @_;
        %sent = (method => $method, params => $params);
        return [ { result => 'ok' } ];
    };
}

my $scfg = { tn_dataset => 'tank/pve', tn_api_host => '198.51.100.7' };

# The call that used to die. Any arity mismatch anywhere between here and
# _api_call surfaces as an exception, so a bare "it returned" is the assertion.
# The volname carries the plugin's own shape, vol-<zname>-lun<N>, not the bare
# zvol name - parse_volname rejects anything else.
{
    my $out = eval { $PKG->bulk_delete_snapshots($scfg, 'store', 'vol-vm-101-disk-0-lun1', ['snapA', 'snapB']) };
    my $err = $@;
    ok(!$err, 'bulk_delete_snapshots reaches the API layer instead of dying')
        or diag("died with: $err");
    unlike($err // '', qr/Too many arguments/,
        '...and specifically not on argument count');
}

# And that it asked for the right thing, so the test would notice a "fix" that
# merely silenced the crash.
{
    is($sent{method}, 'core.bulk', 'the request goes out as core.bulk');
    is($sent{params}[0], 'pool.snapshot.delete', '...wrapping the snapshot delete');
    is_deeply($sent{params}[1],
        [ ['tank/pve/vm-101-disk-0@snapA'], ['tank/pve/vm-101-disk-0@snapB'] ],
        '...with both snapshots, each fully qualified under the configured dataset');
}

# The other two bulk entry points share the same helper; exercise one so a
# regression in _api_bulk_call itself cannot hide behind the snapshot path.
{
    my $bulk = $PKG->can('_api_bulk_call');
    my $out = eval { $bulk->($scfg, 'iscsi.extent.delete', [[1], [2]], 'test') };
    ok(!$@, '_api_bulk_call is callable directly too') or diag("died with: $@");
    is($sent{params}[0], 'iscsi.extent.delete', '...and forwards the method it was given');
}

# Bulk can be switched off, and that path must still be a clean refusal.
{
    my $bulk = $PKG->can('_api_bulk_call');
    eval { $bulk->({ %$scfg, tn_enable_bulk_operations => 0 }, 'pool.snapshot.delete', [[1]], 'x') };
    like($@, qr/disabled/i, 'disabling bulk operations refuses with a clear message');
}

done_testing();
