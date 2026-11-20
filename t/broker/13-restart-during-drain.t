#!/usr/bin/perl
# A broker restart must not hold every RPC on the node for the slowest
# in-flight request, and must not lose that request either.
#
# The unit runs with KillMode=process: on TERM systemd signals only the main
# process and starts the next broker as soon as it exits. Before this change
# the main process waited for its workers to drain (up to ~115 s), so the next
# broker could not start for that long. Now it signals the workers, unpublishes
# the socket and exits; the worker that accepted a request still answers it.
#
# This drives REAL processes: an upstream that answers like TrueNAS (and takes
# 8 s for test.slow), broker 1 serving that slow request, a TERM to broker 1's
# main process only (as systemd does), and broker 2 started on the same path
# once that process is gone (as systemd's restart does).

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

my $SLOW_SECONDS = 8;
my $RESTART_LIMIT = 5;

# Keep the run dir short: a Unix socket path is capped near 108 bytes.
my $rundir = tempdir("/tmp/brkr.XXXXXX", CLEANUP => 1);
my $SOCK   = "$rundir/broker.sock";
my $PIDF   = "$rundir/broker.pid";
my $SLOW_SEEN = "$rundir/slow-seen";

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
            my $result = $o->{method} eq 'auth.login_with_api_key' ? JSON::PP::true() : 'pong';
            if ($o->{method} eq 'test.slow') {
                if (open(my $fh, '>', $SLOW_SEEN)) { close($fh) }
                sleep $SLOW_SECONDS;
                $result = { slow => 'complete', tail => 'z' x 4096 };
            }
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

my @brokers;
sub start_broker {
    my $pid = fork();
    die "fork failed: $!" unless defined $pid;
    if (!$pid) {
        $ENV{TRUENAS_BROKER_RUNDIR} = $rundir;
        $ENV{TRUENAS_BROKER_LOG}    = "$rundir/broker.log";
        open(STDERR, '>>', "$rundir/broker.log");
        exec($^X, $BROKER, '--foreground') or exit 127;
    }
    push @brokers, $pid;
    return $pid;
}

END {
    kill 'TERM', grep { $_ } @brokers, $upstream_pid;
    waitpid($_, 0) for grep { $_ } @brokers, $upstream_pid;
}

sub envelope {
    my ($method, $budget) = @_;
    return encode_json({
        scfg => {
            api_host => '127.0.0.1', api_port => $UPSTREAM_PORT,
            api_scheme => 'ws', api_key => 'test-key', prefer_ipv4 => 1,
        },
        method => $method, params => [], timeout => $budget,
    }) . "\n";
}

sub read_reply {
    my ($s, $budget) = @_;
    my $sel = IO::Select->new($s);
    my $deadline = time() + $budget;
    my $buf = '';
    while (index($buf, "\n") < 0) {
        my $remaining = $deadline - time();
        return undef if $remaining <= 0 || !$sel->can_read($remaining);
        my $got = $s->sysread(my $c, 65536);
        return undef if !defined $got || $got == 0;
        $buf .= $c;
    }
    my ($line) = split /\n/, $buf, 2;
    return scalar(eval { decode_json($line) });
}

# Connect the way the plugin client does (_broker_open_socket): a missing path
# or a refused connection is a restart in progress, so retry until it binds.
sub ping_with_retry {
    my ($limit) = @_;
    my $deadline = time() + $limit;
    while (time() < $deadline) {
        my $s = IO::Socket::UNIX->new(Peer => $SOCK, Type => SOCK_STREAM);
        if ($s) {
            $s->syswrite(envelope('core.ping', 10));
            my $r = read_reply($s, $deadline - time() > 0 ? $deadline - time() : 0.1);
            return $r if $r && defined $r->{result};
        }
        sleep 0.05;
    }
    return undef;
}

my $broker1 = start_broker();
my $waited = 0;
while (!-S $SOCK && $waited < 100) { sleep 0.1; $waited++ }
plan skip_all => "broker socket never appeared at $SOCK" unless -S $SOCK;

my $warm = ping_with_retry(10);
is($warm && $warm->{result}, 'pong', 'broker 1 serves a request');

# The in-flight request: accepted by a broker 1 worker and forwarded upstream.
my $slow = IO::Socket::UNIX->new(Peer => $SOCK, Type => SOCK_STREAM) or die "connect: $!";
$slow->syswrite(envelope('test.slow', 30));
$waited = 0;
while (!-e $SLOW_SEEN && $waited < 100) { sleep 0.05; $waited++ }
ok(-e $SLOW_SEEN, 'the slow request reached the upstream before the restart');

my $t0 = time();
kill 'TERM', $broker1;
# What systemd does with KillMode=process: wait for the main process only.
my $exited = 0;
while (time() - $t0 < $SLOW_SECONDS + 15) {
    if (waitpid($broker1, WNOHANG) == $broker1) { $exited = 1; last }
    sleep 0.05;
}
@brokers = grep { $_ != $broker1 } @brokers if $exited;
my $main_exit = time() - $t0;
ok($exited, 'broker 1 main process exits after TERM');
cmp_ok($main_exit, '<', $RESTART_LIMIT, sprintf('without waiting out the in-flight request (%.2f s)', $main_exit));
ok(!-e $PIDF, 'broker 1 removed its pidfile');

my $broker2 = start_broker();
my $first = ping_with_retry($SLOW_SECONDS + 15);
my $restart = time() - $t0;
is($first && $first->{result}, 'pong', 'broker 2 serves the first RPC after the restart');
cmp_ok($restart, '<', $RESTART_LIMIT, sprintf('TERM to first RPC accepted by broker 2: %.2f s', $restart));

my $reply = read_reply($slow, $SLOW_SECONDS + 15);
is(ref($reply) eq 'HASH' && ref($reply->{result}) eq 'HASH' ? $reply->{result}{slow} : undef, 'complete',
    'the in-flight request of broker 1 still gets its complete reply');
is(ref($reply) eq 'HASH' && ref($reply->{result}) eq 'HASH' ? length($reply->{result}{tail} // '') : 0, 4096,
    '...with the whole payload');

# Let broker 1's worker notice the TERM and exit, then check it left broker 2's
# paths alone.
sleep 2.5;
ok(-S $SOCK, "broker 1's exiting worker did not remove broker 2's socket");
my $pidfile = '';
if (open(my $fh, '<', $PIDF)) { $pidfile = <$fh> // ''; close($fh) }
chomp $pidfile;
is($pidfile, "$broker2", "broker 1's exiting worker did not remove broker 2's pidfile");
my $after = ping_with_retry(10);
is($after && $after->{result}, 'pong', 'broker 2 keeps serving');

done_testing();
