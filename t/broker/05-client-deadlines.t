#!/usr/bin/perl
# Deadlines must cover backlog time, silent upstreams and initial connect.
use strict;
use warnings;
use Test::More;
use FindBin;
use IO::Socket::INET;
use IO::Socket::UNIX;
use IO::Select;
use Fcntl qw(:flock);
use File::Temp qw(tempdir);
use Time::HiRes qw(time sleep);
use JSON::PP qw(encode_json decode_json);
use Digest::SHA qw(sha1);
use MIME::Base64 qw(encode_base64);

my $BROKER = "$FindBin::Bin/../../tools/truenas-plugin-broker";
plan skip_all => "broker not found" unless -f $BROKER;
my $dir = tempdir('/tmp/brkd.XXXXXX', CLEANUP => 1);
my $sock_path = "$dir/broker.sock";
my $events = "$dir/events";
my $release = "$dir/release";
my $listener = IO::Socket::INET->new(
    LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 16,
    ReuseAddr => 1, Proto => 'tcp',
) or plan skip_all => "cannot listen on loopback: $!";
my $port = $listener->sockport;

sub exact {
    my ($s, $n) = @_;
    my $out = '';
    while (length($out) < $n) {
        my $got = $s->sysread(my $part, $n - length($out));
        return undef unless defined($got) && $got > 0;
        $out .= $part;
    }
    return $out;
}

sub answer {
    my ($s, $id, $result) = @_;
    my $data = encode_json({ jsonrpc => '2.0', id => $id, result => $result });
    my $head = length($data) <= 125 ? pack('CC', 0x81, length($data))
             : pack('CCn', 0x81, 126, length($data));
    $s->syswrite($head . $data);
}

sub record_event {
    my ($name) = @_;
    open(my $fh, '>>', $events) or die $!;
    flock($fh, LOCK_EX) or die $!;
    print $fh "$name\n";
    close $fh;
}

my $upstream_pid = fork();
die "fork failed: $!" unless defined $upstream_pid;
if (!$upstream_pid) {
    $SIG{TERM} = sub { exit 0 };
    while (my $client = $listener->accept()) {
        my $pid = fork();
        next if $pid;
        alarm 12;
        my $request = '';
        while ($client->sysread(my $part, 1024)) {
            $request .= $part;
            last if $request =~ /\r\n\r\n/s;
        }
        my ($key) = $request =~ /Sec-WebSocket-Key:\s*(\S+)/i;
        exit 0 unless defined $key; # TLS ClientHello: deliberately no reply.
        my $accept = encode_base64(sha1($key . '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'), '');
        print $client "HTTP/1.1 101 Switching Protocols\r\n"
            . "Upgrade: websocket\r\nConnection: Upgrade\r\n"
            . "Sec-WebSocket-Accept: $accept\r\n\r\n";
        while (1) {
            my $header = exact($client, 2) // last;
            my ($first, $second) = unpack('CC', $header);
            my $length = $second & 0x7f;
            $length = unpack('n', exact($client, 2) // last) if $length == 126;
            $length = unpack('Q>', exact($client, 8) // last) if $length == 127;
            my $mask = exact($client, 4) // last;
            my $body = exact($client, $length) // last;
            for my $i (0 .. length($body) - 1) {
                substr($body, $i, 1) = chr(ord(substr($body, $i, 1)) ^ ord(substr($mask, $i % 4, 1)));
            }
            my $rpc = eval { decode_json($body) } // next;
            my $method = $rpc->{method};
            if ($method eq 'test.hold') {
                record_event('hold');
                sleep 0.02 until -e $release;
            } elsif ($method eq 'test.mutate') {
                record_event('mutate');
            } elsif ($method eq 'test.slow') {
                # An upstream that answers, but not at once: 0.6 s.
                record_event('slow');
                sleep 0.6;
            } elsif ($method eq 'test.mute') {
                next;
            }
            answer($client, $rpc->{id}, $method eq 'auth.login_with_api_key' ? JSON::PP::true() : 'ok');
        }
        exit 0;
    }
    exit 0;
}
$listener->close();

my $broker_pid = fork();
die "fork failed: $!" unless defined $broker_pid;
if (!$broker_pid) {
    $ENV{TRUENAS_BROKER_RUNDIR} = $dir;
    $ENV{TRUENAS_BROKER_LOG} = "$dir/broker.log";
    $ENV{TRUENAS_BROKER_WORKERS} = 2;
    open(STDERR, '>>', "$dir/broker.log");
    exec($^X, $BROKER, '--foreground') or exit 127;
}
END {
    kill 'TERM', $broker_pid if $broker_pid;
    kill 'TERM', $upstream_pid if $upstream_pid;
    waitpid($broker_pid, 0) if $broker_pid;
    waitpid($upstream_pid, 0) if $upstream_pid;
}
my $ready_by = time() + 10;
sleep 0.02 until -S $sock_path || time() >= $ready_by;
plan skip_all => 'broker socket did not appear' unless -S $sock_path;

sub mono { return Time::HiRes::clock_gettime(Time::HiRes::CLOCK_MONOTONIC()) }

sub send_request {
    my (%arg) = @_;
    my $s = IO::Socket::UNIX->new(Peer => $sock_path, Type => SOCK_STREAM)
        or die "connect broker: $!";
    my $req = {
        scfg => { api_host => '127.0.0.1', api_port => $port,
                  api_scheme => $arg{scheme} // 'ws',
                  api_key => $arg{api_key} // 'test-key' },
        method => $arg{method}, params => [],
    };
    $req->{timeout} = $arg{timeout} if exists $arg{timeout};
    $req->{sent_mono} = $arg{sent_mono} if exists $arg{sent_mono};
    $req->{sent_at} = $arg{sent_at} if exists $arg{sent_at};   # wall clock: must be ignored
    $s->syswrite(encode_json($req) . "\n");
    return $s;
}

sub read_reply {
    my ($s, $limit) = @_;
    my $sel = IO::Select->new($s);
    my $end = time() + $limit;
    my $data = '';
    while (time() < $end) {
        last unless $sel->can_read($end - time());
        my $n = $s->sysread(my $part, 4096);
        last unless defined($n) && $n > 0;
        $data .= $part;
        last if $data =~ /\n/;
    }
    $s->close();
    return eval { decode_json((split /\n/, $data)[0]) };
}

sub event_count {
    my ($wanted) = @_;
    return 0 unless -e $events;
    open(my $fh, '<', $events) or die $!;
    my $count = 0;
    while (<$fh>) { $count++ if $_ eq "$wanted\n" }
    close $fh;
    return $count;
}

# All occupied workers put the next request in the kernel backlog.
my @holding = map { send_request(method => 'test.hold', timeout => 30) } 1 .. 2;
my $held_by = time() + 10;
sleep 0.02 until event_count('hold') == 2 || time() >= $held_by;
is(event_count('hold'), 2, 'both workers are occupied');
my $queued = send_request(method => 'test.mutate', timeout => 0.5, sent_mono => mono());
sleep 0.8;
open(my $release_fh, '>', $release) or die $!;
close $release_fh;
my $queued_reply = read_reply($queued, 3);
$_->close() for @holding;
is(ref($queued_reply) eq 'HASH' ? $queued_reply->{error} : undef,
   'broker: request expired in queue', 'expired queued request is rejected');
is(event_count('mutate'), 0, 'expired mutation never reaches upstream');
{
    open(my $log_fh, '<', "$dir/broker.log") or die $!;
    my $log = do { local $/; <$log_fh> };
    close $log_fh;
    like($log, qr/request expired in queue.*count=1/, 'queue expiry is counted in the broker log');
}
my $legacy = send_request(method => 'test.mutate', sent_mono => mono() - 3600);
my $legacy_reply = read_reply($legacy, 3);
is(ref($legacy_reply) eq 'HASH' ? $legacy_reply->{result} : undef,
   'ok', 'requests without a timeout ignore the timestamp');

# A short client budget must not silently revert to the daemon's 30 seconds.
my $started = time();
my $mute = send_request(method => 'test.mute', timeout => 3, sent_mono => mono());
my $mute_reply = read_reply($mute, 3);
ok(ref($mute_reply) eq 'HASH' && exists $mute_reply->{error},
   'silent upstream releases its worker for a one-second budget');
cmp_ok(time() - $started, '<', 2.3, 'silent request finishes at its own bound (~1.5 s), not at the 30 s default');

# A TCP listener which never completes TLS must not retain a worker for 15 s.
$started = time();
my $tls = send_request(method => 'test.connect', scheme => 'wss', api_key => 'tls-key', timeout => 3,
                       sent_mono => mono());
my $tls_reply = read_reply($tls, 3);
ok(ref($tls_reply) eq 'HASH' && exists $tls_reply->{error},
   'silent TLS connect respects the request deadline');
cmp_ok(time() - $started, '<', 2.3, 'connect finishes at the request bound (~1.5 s), not at 15 s');

# A budget below the floor is not stretched to the floor: the client has given up
# before the broker could answer, and executing a mutation nobody will hear about
# is how a retry duplicates it. It is rejected without reaching the upstream.
my $before = event_count('mutate');
my $tiny = send_request(method => 'test.mutate', timeout => 0.2, sent_mono => mono());
my $tiny_reply = read_reply($tiny, 2);
is(ref($tiny_reply) eq 'HASH' ? $tiny_reply->{error} : undef,
   'broker: request expired in queue', 'a budget below the floor is rejected, not stretched');
is(event_count('mutate'), $before, '  ...and the mutation never reaches the upstream');

# The broker keeps a margin to answer: a 2 s budget on a silent upstream is given
# up at about 1 s, not at 2 s when the client is already gone.
$started = time();
my $margin = send_request(method => 'test.mute', timeout => 2, sent_mono => mono());
my $margin_reply = read_reply($margin, 2.5);
ok(ref($margin_reply) eq 'HASH' && exists $margin_reply->{error}, 'a 2 s budget on a silent upstream ends with an error');
cmp_ok(time() - $started, '<', 1.6, '  ...before the client deadline, leaving room to answer');

# Only the monotonic stamp counts. A wall-clock stamp an hour in the past (a clock
# step, or an old build) must neither expire the request nor shorten its budget.
$before = event_count('mutate');
my $wall = send_request(method => 'test.mutate', timeout => 5, sent_at => time() - 3600, sent_mono => mono());
my $wall_reply = read_reply($wall, 3);
is(ref($wall_reply) eq 'HASH' ? $wall_reply->{result} : undef, 'ok', 'the wall-clock stamp is ignored');
is(event_count('mutate'), $before + 1, '  ...and the request is executed once');

# A one-second budget is USABLE: a responsive upstream answers inside half of it.
# (Rejecting it would turn every call that reaches the end of tn_op_budget_s into
# a failure that never even tried.)
$before = event_count('mutate');
my $one = send_request(method => 'test.mutate', timeout => 1, sent_mono => mono());
my $one_reply = read_reply($one, 2);
is(ref($one_reply) eq 'HASH' ? $one_reply->{result} : undef, 'ok', 'a one-second budget with a responsive upstream succeeds');
is(event_count('mutate'), $before + 1, '  ...and executes exactly once');

# The margin to answer is small for short budgets. An upstream that takes 0.6 s on
# a 1 s deadline still has to be DELIVERED: halving the budget (0.5 s) would cut a
# valid answer, run the mutation and report "no response" - which the deployed
# broker (30 s budget below 2 s) never did.
my $slow = send_request(method => 'test.slow', timeout => 1, sent_mono => mono());
my $slow_reply = read_reply($slow, 2);
is(ref($slow_reply) eq 'HASH' ? $slow_reply->{result} : undef, 'ok',
   'an answer that takes 0.6 s on a 1 s deadline is delivered');

# The refusal is for a client that is all but gone, and says so in the log with
# the budget it had left, so it can be told apart from plain latency.
{
    open(my $log_fh, '<', "$dir/broker.log") or die $!;
    my $log = do { local $/; <$log_fh> };
    close $log_fh;
    like($log, qr/request expired in queue.*remaining=0[.][0-2]/, 'the refusal logs the budget that was left');
}

done_testing();
