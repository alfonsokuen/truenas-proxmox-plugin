#!/usr/bin/perl
# A request larger than one TLS record must arrive whole.
#
# This exists because the same assertion in 01-upstream-deadline.t is not
# enough on its own: that test drives the broker over plain ws, and over plain
# TCP a 256 KB syswrite to a peer that is draining promptly takes the lot, so
# the assertion passed against the very build that had the bug. It has to be
# TLS, which is also what a real deployment uses - api_scheme defaults to wss.
#
# Measured on IO::Socket::SSL 2.085: syswrite of 8 KB and 16 KB returned the
# full count, while 64 KB and 256 KB both returned 16384 - one TLS record. The
# daemon called syswrite once and discarded what it returned, so anything
# larger went out truncated. The far end then had a frame header promising
# more bytes than ever arrived, sat waiting for the rest, and the request died
# on its own deadline reporting a network fault.
#
# Run with:  prove -v t/broker/02-tls-short-write.t

use strict;
use warnings;
use Test::More;
use FindBin;
use IO::Socket::SSL;
use IO::Socket::UNIX;
use IO::Select;
use File::Temp qw(tempdir);
use Time::HiRes qw(time sleep);

my $BROKER = "$FindBin::Bin/../../tools/truenas-plugin-broker";
plan skip_all => "broker not found at $BROKER" unless -f $BROKER;
plan skip_all => "JSON::PP unavailable"    unless eval { require JSON::PP; 1 };
plan skip_all => "Digest::SHA unavailable" unless eval { require Digest::SHA; 1 };
plan skip_all => "openssl not on PATH"     unless system("command -v openssl >/dev/null 2>&1") == 0;
JSON::PP->import(qw(encode_json decode_json));
Digest::SHA->import(qw(sha1));
require MIME::Base64; MIME::Base64->import(qw(encode_base64));

my $rundir = tempdir("/tmp/brks.XXXXXX", CLEANUP => 1);
my $SOCK   = "$rundir/broker.sock";

system(qq{openssl req -x509 -newkey rsa:2048 -keyout $rundir/key.pem }
     . qq{-out $rundir/cert.pem -days 1 -nodes -subj "/CN=localhost" >/dev/null 2>&1});
plan skip_all => "could not generate a test certificate"
    unless -s "$rundir/cert.pem" && -s "$rundir/key.pem";

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

# A TrueNAS speaking TLS that reports how many bytes of each request reached it.
my $listener = IO::Socket::SSL->new(
    LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 8, ReuseAddr => 1,
    SSL_cert_file => "$rundir/cert.pem", SSL_key_file => "$rundir/key.pem",
) or plan skip_all => "cannot start a TLS listener: $SSL_ERROR";
my $PORT = $listener->sockport;

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
            if    ($len == 126) { my $e = rd_exact($c, 2) or last; $len = unpack('n',  $e) }
            elsif ($len == 127) { my $e = rd_exact($c, 8) or last; $len = unpack('Q>', $e) }
            my $mk = '';
            if ($masked) { $mk = rd_exact($c, 4) or last }
            my $pl = '';
            if ($len)    { $pl = rd_exact($c, $len) or last }
            $pl = unmask($pl, $mk) if $masked;
            my $o = eval { decode_json($pl) } or next;
            my $result = $o->{method} eq 'auth.login_with_api_key' ? JSON::PP::true()
                       : $o->{method} eq 'test.size'               ? length($pl)
                       :                                            'pong';
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

sub call_broker {
    my (%a) = @_;
    my $budget = $a{budget} // 30;
    my $s = IO::Socket::UNIX->new(Peer => $SOCK, Type => SOCK_STREAM) or return undef;
    my $env = {
        # api_insecure, because the certificate is self-signed. This is the
        # wss path either way, which is the point.
        scfg => { api_host => '127.0.0.1', api_port => $PORT, api_scheme => 'wss',
                  api_key => 'test-key', prefer_ipv4 => 1, api_insecure => 1 },
        method => $a{method}, params => $a{params} // [], timeout => $budget,
    };
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
        return undef if $remaining <= 0 || !$sel->can_read($remaining);
        my $got = $s->sysread(my $c, 4096);
        return undef if !defined $got || $got == 0;
        $buf .= $c;
        last if index($buf, "\n") >= 0;
    }
    $s->close();
    return scalar(eval { decode_json((split /\n/, $buf, 2)[0]) });
}

{
    my $r = call_broker(method => 'core.ping');
    is(ref($r) eq 'HASH' ? $r->{result} : undef, 'pong', 'the TLS upstream answers a small call');
}

# Under a TLS record, so this succeeded even before the write loop existed.
{
    my $r = call_broker(method => 'test.size', params => ['z' x 4096]);
    ok(ref($r) eq 'HASH' && ($r->{result} // 0) > 4096,
        'a request that fits in one TLS record arrives whole');
}

# Over it. This is the case that used to be silently truncated: syswrite
# returned 16384 and the rest was dropped on the floor.
for my $size (64 * 1024, 256 * 1024) {
    my $r = call_broker(method => 'test.size', params => ['z' x $size], budget => 30);
    ok(defined $r, "a ${\ int($size/1024) } KB request gets an answer at all")
        or next;
    ok(!exists $r->{error}, "...not an error")
        or diag("broker said: " . ($r->{error} // ''));
    cmp_ok($r->{result} // 0, '>', $size,
        "...and every byte of it reached the upstream, not just the first record");
}

done_testing();
