#!/usr/bin/perl
# The retry classifier against what TrueNAS really sends.
#
# middlewared answers a failed method call with the full Python traceback in
# data.trace. Dying with the whole payload fed that text to
# _is_retryable_error, whose /WebSocket.*closed/ pattern matched
# "RpcWebSocketApp object ... closed=False" inside the trace: a deterministic
# "dataset already exists" was retried and logged at err level on every LXC
# snapshot backup (PVE activates the backup snapshot twice per disk).
#
# The fixture is a real journal line from a PVE 9.2.4 node (pool name and
# addresses anonymised). Both directions are asserted: definitive server
# verdicts are not retried, real transport failures still are.

use strict;
use warnings;
use Test::More;
use FindBin;

my $PLUGIN = "$FindBin::Bin/../../TrueNASPlugin.pm";
unless (eval { require $PLUGIN; 1 }) {
    plan skip_all => "cannot load plugin: $@";
}
my $PKG = 'PVE::Storage::Custom::TrueNASPlugin';
my $retryable = $PKG->can('_is_retryable_error') or BAIL_OUT('no _is_retryable_error');
my $message   = $PKG->can('_rpc_error_message')  or BAIL_OUT('no _rpc_error_message');
{
    no strict 'refs';
    no warnings 'redefine';
    *{"${PKG}::_log"} = sub { 1 };
}

my $fixture = "$FindBin::Bin/fixtures/tn-clone-already-exists.err";
open my $fh, '<', $fixture or BAIL_OUT("fixture missing: $fixture");
my $real = do { local $/; <$fh> };
close $fh;
chomp $real;

# --- the real line: what the old code died with -----------------------------
like($real, qr/WebSocket.*closed/i,
    'fixture still carries the traceback text that false-matched the connection pattern');
ok(!$retryable->($real), 'real "dataset already exists" payload is NOT retryable');

# --- what the new code dies with --------------------------------------------
my ($json) = $real =~ /(\{"code":.*\}\})/s;
ok($json, 'fixture contains the JSON-RPC error object');
my $short = $message->($json);
like($short, qr/^JSON-RPC error \[EFAULT\]: \[EFAULT\] Failed to clone snapshot: cannot create '[^']+': dataset already exists$/,
    'message is [errname]: reason, without the traceback');
ok(length($short) < 300, 'message is short (' . length($short) . ' chars)');
ok(!$retryable->($short), 'the short message is not retryable either');

# hashref input (the direct WebSocket path) and passthrough of plain strings
use JSON::PP;
is($message->(decode_json($json)), $short, 'same message from the decoded hashref');
is($message->('WS read timeout after 30s'), 'JSON-RPC error: WS read timeout after 30s',
    'plain string errors pass through');

# --- other definitive verdicts: never retried -------------------------------
ok(!$retryable->($_), "not retryable: $_") for (
    'JSON-RPC error [EEXIST]: dataset already exists',
    'EZFS_EXISTS: dataset already exists',
    "zfs_create('pool/x') failed: already exists",
    'IntegrityError: FOREIGN KEY constraint failed',
    'JSON-RPC error [EINVAL]: Invalid params',
);

# --- transport failures: still retried --------------------------------------
ok($retryable->($_), "retryable: $_") for (
    'WS read timeout after 30s',
    'connection reset by peer',
    'WebSocket connection closed unexpectedly',
    'broker: read failed: Broken pipe',
    '503 Service Unavailable',
);

done_testing();
