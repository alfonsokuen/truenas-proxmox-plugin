#!/usr/bin/perl
# The broker must not be wedged by an upstream that stops answering.
#
# This is a regression test for a measured failure, not a hypothetical one.
# The socket constructors set Timeout => 15, which covers connect() and nothing
# else; every read was a bare blocking sysread. A TrueNAS that accepted the TCP
# connection and then went silent WITHOUT closing it - which is what a reboot,
# a fabric blip, or a firewall dropping the flow all look like from this end -
# left ws_read_exact waiting forever. Because the daemon serves clients inline
# on a single thread, that was not one stalled request: the whole broker
# stopped answering anyone, for good, and systemd's Restart=on-failure never
# fired because the process was still alive. Recorded against the pre-fix
# daemon: call 1 = 0.00s ok, upstream goes mute, call 2 = client timeout,
# call 3 from a brand-new client = timeout, still wedged minutes later.
#
# The upstream here is a local server that speaks just enough WebSocket and
# JSON-RPC to be accepted, and that can be told to go quiet while keeping the
# socket open. Everything runs on the loopback with no privileges and no real
# TrueNAS.
#
# Run with:  prove -v t/broker/01-upstream-deadline.t

use strict;
use warnings;
use Test::More;
use FindBin;
use IO::Socket::INET;
use IO::Socket::UNIX;
use IO::Select;
use File::Temp qw(tempdir);
use POSIX qw(:sys_wait_h);
use Time::HiRes qw(time sleep);

my $BROKER = "$FindBin::Bin/../../tools/truenas-plugin-broker";
plan skip_all => "broker not found at $BROKER" unless -f $BROKER;
plan skip_all => "JSON::PP unavailable"        unless eval { require JSON::PP; 1 };
plan skip_all => "Digest::SHA unavailable"     unless eval { require Digest::SHA; 1 };
JSON::PP->import(qw(encode_json decode_json));
Digest::SHA->import(qw(sha1));
require MIME::Base64; MIME::Base64->import(qw(encode_base64));

# Keep the run dir short: a Unix socket path is capped near 108 bytes.
my $rundir = tempdir("/tmp/brkt.XXXXXX", CLEANUP => 1);
my $SOCK   = "$rundir/broker.sock";
my $MUTE   = "$rundir/mute";

# ---------------------------------------------------------------------------
# A TrueNAS that can be told to stop talking without hanging up
# ---------------------------------------------------------------------------

my $listener = IO::Socket::INET->new(
    LocalAddr => '127.0.0.1', LocalPort => 0,
    Listen => 8, ReuseAddr => 1, Proto => 'tcp',
) or plan skip_all => "cannot listen on loopback: $!";
my $UPSTREAM_PORT = $listener->sockport;

sub rd_exact {
    my ($s, $n) = @_;
    my $b = '';
    while (length($b) < $n) {
        my $got = $s->sysread(my $t, $n - length($b));
        return undef unless defined $got && $got > 0;
        $b .= $t;
    }
    return $b;
}

sub unmask {
    my ($d, $m) = @_;
    my $o = $d;
    for my $i (0 .. length($d) - 1) {
        substr($o, $i, 1) = chr(ord(substr($d, $i, 1)) ^ ord(substr($m, $i % 4, 1)));
    }
    return $o;
}

my $upstream_pid = fork();
die "fork failed: $!" unless defined $upstream_pid;
if (!$upstream_pid) {
    $SIG{TERM} = sub { exit 0 };
    while (my $c = $listener->accept()) {
        next if fork();
        my $req = '';
        while ($c->sysread(my $b, 1024)) { $req .= $b; last if $req =~ /\r\n\r\n/s }
        my ($k) = $req =~ /Sec-WebSocket-Key:\s*(\S+)/i;
        my $accept = encode_base64(sha1(($k // '') . '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'), '');
        print $c "HTTP/1.1 101 Switching Protocols\r\n"
               . "Upgrade: websocket\r\nConnection: Upgrade\r\n"
               . "Sec-WebSocket-Accept: $accept\r\n\r\n";
        while (1) {
            my $h = rd_exact($c, 2) or last;
            my ($b1, $b2) = unpack('CC', $h);
            my $len    = $b2 & 0x7F;
            my $masked = $b2 & 0x80;
            if    ($len == 126) { $len = unpack('n',  rd_exact($c, 2) // last) }
            elsif ($len == 127) { $len = unpack('Q>', rd_exact($c, 8) // last) }
            my $mk = $masked ? (rd_exact($c, 4) // last) : '';
            my $pl = $len ? (rd_exact($c, $len) // last) : '';
            $pl = unmask($pl, $mk) if $masked;
            my $o = eval { decode_json($pl) } or next;
            # The failure being reproduced: stop answering, stay connected.
            next if -e $MUTE;
            # test.size reports how many bytes of request actually arrived, so
            # a truncated send is visible from the client end.
            my $result = $o->{method} eq 'auth.login_with_api_key' ? JSON::PP::true()
                       : $o->{method} eq 'core.ping'               ? 'pong'
                       : $o->{method} eq 'test.size'               ? length($pl)
                       :                                            { ok => 1 };
            my $txt = encode_json({ jsonrpc => '2.0', id => $o->{id}, result => $result });
            my $l = length($txt);
            my $hd = pack('C', 0x81);
            if    ($l <= 125)    { $hd .= pack('C',    $l) }
            elsif ($l <= 0xFFFF) { $hd .= pack('C n',  126, $l) }
            else                 { $hd .= pack('C Q>', 127, $l) }
            $c->syswrite($hd . $txt);
        }
        exit 0;
    }
    exit 0;
}
$listener->close();

# ---------------------------------------------------------------------------
# The broker under test
# ---------------------------------------------------------------------------

my $broker_pid = fork();
die "fork failed: $!" unless defined $broker_pid;
if (!$broker_pid) {
    $ENV{TRUENAS_BROKER_RUNDIR} = $rundir;
    $ENV{TRUENAS_BROKER_LOG}    = "$rundir/broker.log";
    open(STDERR, '>>', "$rundir/broker.log");
    exec($^X, $BROKER, '--foreground') or exit 127;
}

my $waited = 0;
while (!-S $SOCK && $waited < 100) { sleep 0.1; $waited++ }

END {
    kill 'TERM', $broker_pid   if $broker_pid;
    kill 'TERM', $upstream_pid if $upstream_pid;
    waitpid($broker_pid, 0)    if $broker_pid;
    waitpid($upstream_pid, 0)  if $upstream_pid;
}

plan skip_all => "broker socket never appeared at $SOCK" unless -S $SOCK;

# One round trip per connection, with a deadline of our own, timed.
# Returns ($elapsed, $decoded_or_undef). $decoded is undef when WE gave up
# first - which is the pre-fix behaviour and what these tests must not see.
sub call_broker {
    my (%a) = @_;
    my $budget = $a{budget} // 30;
    my $t0 = time();
    my $s = IO::Socket::UNIX->new(Peer => $SOCK, Type => SOCK_STREAM)
        or return (time() - $t0, undef, 'connect failed');
    my $env = {
        scfg => {
            api_host => '127.0.0.1', api_port => $UPSTREAM_PORT,
            api_scheme => 'ws', api_key => 'test-key', prefer_ipv4 => 1,
        },
        method => $a{method} // 'core.ping',
        params => [],
    };
    # Older clients omit this field entirely; exercised below.
    $env->{timeout} = $budget unless $a{omit_timeout};
    $env->{params} = $a{params} if $a{params};
    my $payload = encode_json($env) . "\n";
    my $off = 0;
    while ($off < length($payload)) {
        my $n = $s->syswrite(substr($payload, $off));
        last if !defined $n || $n == 0;
        $off += $n;
    }

    my $sel = IO::Select->new($s);
    my $deadline = time() + $budget;
    my $buf = '';
    while (1) {
        my $remaining = $deadline - time();
        return (time() - $t0, undef, 'client gave up first') if $remaining <= 0;
        return (time() - $t0, undef, 'client gave up first') unless $sel->can_read($remaining);
        my $got = $s->sysread(my $c, 4096);
        return (time() - $t0, undef, 'eof') if !defined $got || $got == 0;
        $buf .= $c;
        last if index($buf, "\n") >= 0;
    }
    $s->close();
    my ($line) = split /\n/, $buf, 2;
    return (time() - $t0, scalar(eval { decode_json($line) }), undef);
}

# ---------------------------------------------------------------------------
# A healthy upstream answers, and leaves a connection in the pool
# ---------------------------------------------------------------------------

{
    my ($el, $r) = call_broker();
    is(ref($r) eq 'HASH' ? $r->{result} : undef, 'pong', 'a healthy upstream answers');
    cmp_ok($el, '<', 5, '...promptly');
}

# ---------------------------------------------------------------------------
# The upstream goes silent without closing
# ---------------------------------------------------------------------------

open(my $mfh, '>', $MUTE) or die "cannot create $MUTE: $!"; close $mfh;

# The pooled connection is now half-open: the daemon can still write to it and
# will wait on a reply that never comes. Before the fix this call never
# returned and neither did any call after it.
my $first_after_mute;
{
    my ($el, $r, $why) = call_broker(budget => 40);
    $first_after_mute = $el;
    ok(defined $r, 'a silent upstream produces an answer rather than a hang')
        or diag("client gave up after ${el}s: " . ($why // 'unknown'));
    ok(defined $r && exists $r->{error}, '...and that answer is an error');
    cmp_ok($el, '<', 40, '...delivered inside the budget');
}

# The heart of it. A brand-new client, on a brand-new connection, must be
# served. Against the pre-fix daemon this timed out no matter how long it
# waited, because the accept loop never came back round.
{
    my ($el, $r, $why) = call_broker(budget => 40);
    ok(defined $r, 'the daemon still serves a new client afterwards')
        or diag("client gave up after ${el}s: " . ($why // 'unknown'));
    cmp_ok($el, '<', 40, '...also inside the budget');
}

# A client that says it will only wait 10s must be answered inside 10s, so its
# own deadline does not fire first and replace the daemon's account of the
# failure with a bare "read timeout".
{
    my ($el, $r, $why) = call_broker(budget => 10);
    ok(defined $r, 'an impatient client is answered before its own deadline')
        or diag("client gave up after ${el}s: " . ($why // 'unknown'));
    cmp_ok($el, '<', 10, '...strictly inside the budget it declared');
}

# A client from before the envelope carried a timeout must still be served.
{
    my ($el, $r, $why) = call_broker(budget => 60, omit_timeout => 1);
    ok(defined $r, 'a client that sends no timeout is still answered')
        or diag("client gave up after ${el}s: " . ($why // 'unknown'));
    cmp_ok($el, '<', 60, '...on the daemon default rather than never');
}

# ---------------------------------------------------------------------------
# Recovery is automatic
# ---------------------------------------------------------------------------

unlink $MUTE;

{
    my ($el, $r, $why) = call_broker(budget => 30);
    is(ref($r) eq 'HASH' ? $r->{result} : undef, 'pong',
        'the daemon recovers by itself once the upstream answers again')
        or diag("after ${el}s: " . ($why // 'no result'));
    cmp_ok($el, '<', 10, '...without waiting out another timeout');
}

# ---------------------------------------------------------------------------
# A local client that stops mid-request must not take the daemon with it
# ---------------------------------------------------------------------------

# The upstream read was bounded first and this one was not, which left the
# daemon just as wedgeable from the near side: measured against that build, a
# client that connected and sent a request WITHOUT its trailing newline stopped
# the accept loop dead, and a healthy client behind it went unanswered for as
# long as it cared to wait. A client that dies is harmless - the socket reports
# EOF - but one that merely stops is not.
{
    my $stalled = IO::Socket::UNIX->new(Peer => $SOCK, Type => SOCK_STREAM);
    ok($stalled, 'a client can connect and then stall');
    $stalled->syswrite('{"scfg":{"api_host":"127.0.0.1"');   # no newline, ever

    my ($el, $r, $why) = call_broker(budget => 20);
    ok(defined $r, 'a healthy client is still served while another sits half-spoken')
        or diag("client gave up after ${el}s: " . ($why // 'unknown'));
    cmp_ok($el, '<', 20, '...without waiting out the stalled one');
    $stalled->close() if $stalled;
}

# ---------------------------------------------------------------------------
# A request larger than one TLS record must arrive whole
# ---------------------------------------------------------------------------

# A smoke test only. It is NOT the coverage for the short-write bug, and
# saying so here because it looked like it was: run against the build that
# still had that bug, these two assertions passed. This file drives the broker
# over plain ws, and over plain TCP a 256 KB syswrite to a peer that is
# draining promptly takes the lot in one go, so the truncation never happens.
# It only appears on TLS, where one syswrite is capped at a single record -
# and TLS is what a real deployment uses. That case lives in
# 02-tls-short-write.t, where it fails against the unfixed build as it should.
{
    my $big = 'y' x (256 * 1024);
    my ($el, $r, $why) = call_broker(method => 'test.size', params => [$big], budget => 30);
    ok(defined $r, 'a request larger than one TLS record gets an answer')
        or diag("client gave up after ${el}s: " . ($why // 'unknown'));
    cmp_ok(ref($r) eq 'HASH' ? ($r->{result} // 0) : 0, '>', 256 * 1024,
        '...and the upstream received all of it, not just the first record');
}

# ---------------------------------------------------------------------------
# The failure is visible to an operator
# ---------------------------------------------------------------------------

{
    my $log = '';
    if (open(my $fh, '<', "$rundir/broker.log")) { local $/; $log = <$fh>; close $fh }
    like($log, qr/timed out/i, 'a stalled upstream is recorded in the log');
    unlike($log, qr/authentication failed/i,
        'a timeout is not reported as an authentication failure');
}

done_testing();
