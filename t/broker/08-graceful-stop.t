#!/usr/bin/perl
use strict;
use warnings;
use FindBin;
use Test::More;
use Errno qw(EAGAIN ECHILD);

my ($fork, $waitpid, $kill, $unlink);
BEGIN {
    *CORE::GLOBAL::fork = sub () { $fork->() };
    *CORE::GLOBAL::waitpid = sub ($$) { $waitpid->(@_) };
    *CORE::GLOBAL::kill = sub { $kill->(@_) };
    *CORE::GLOBAL::exit = sub (;$) { die "exit $_[0]\n" };
    *CORE::GLOBAL::unlink = sub { $unlink->(@_) };
}

my $broker = "$FindBin::Bin/../../tools/truenas-plugin-broker";
my $unit = "$FindBin::Bin/../../debian/truenas-plugin-broker.service";
local $ENV{TRUENAS_BROKER_WORKERS} = 1;
local $ENV{TRUENAS_BROKER_MAX_BUDGET};
local $ENV{TRUENAS_BROKER_TIMEOUT};
do $broker;
die $@ if $@;
ok(defined &main, 'loaded the real broker entry point');

{
    package BrokerTest::Socket;
    sub accept {
        my ($self) = @_;
        ++$self->{accepts};
        return $self->{client};
    }
    sub close { push @{ $_[0]->{events} }, $_[0]->{close_event} if $_[0]->{close_event} }
}

{
    package BrokerTest::Select;
    sub can_read {
        my ($self) = @_;
        die "worker accepted another request after TERM" if ++$self->{reads} > 1;
        return $self->{listener};
    }
}

my @events;
no warnings 'redefine', 'once';
local *ensure_rundir = sub {};
local *daemonize = sub {};
local *write_pidfile = sub {};
local *linfo = sub {};
local *ldebug = sub {};
local *lwarn = sub {};
local *lerr = sub { push @events, "error: $_[0]" };
local *sd_notify_ready = sub { push @events, 'ready' };
my $listener = bless {}, 'BrokerTest::Socket';
local *make_listener = sub { $listener };
$unlink = sub { return scalar @_ };

subtest 'TERM lets a mutation finish and sends its response before the worker exits' => sub {
    local $SIG{TERM};
    local $SIG{INT};
    @events = ();
    $fork = sub { 0 };
    my $client = bless { events => \@events, close_event => 'client closed' }, 'BrokerTest::Socket';
    local $listener->{client} = $client;
    local $listener->{accepts} = 0;
    my $selector = bless { listener => $listener }, 'BrokerTest::Select';
    local *IO::Select::new = sub { $selector };
    local *read_line_blocking = sub {
        '{"scfg":{"api_host":"tn.test","api_key":"stub"},"method":"pool.dataset.create"}'
    };
    local *get_or_open_ws = sub { { next_id => 1 } };
    local *ws_rpc = sub {
        push @events, "sent $_[1]->{method}";
        $SIG{TERM}->();
        push @events, 'upstream replied';
        return { result => 'tank/test' };
    };
    local *write_all = sub {
        my $response = decode_json($_[1]);
        push @events, 'reply ' . ($response->{result} // '<error>');
        return 1;
    };
    eval { main() };
    is($@, "exit 0\n", 'worker exits successfully');
    is_deeply([grep { $_ ne 'ready' } @events],
        ['sent pool.dataset.create', 'upstream replied', 'reply tank/test', 'client closed'],
        'TERM does not discard the in-flight RPC result');
    is($listener->{accepts}, 1, 'worker accepts no further connections');
};

open(my $unit_fh, '<', $unit) or die "cannot read $unit: $!";
my $service = do { local $/; <$unit_fh> };
close $unit_fh;
open(my $broker_fh, '<', $broker) or die "cannot read $broker: $!";
my $broker_source = do { local $/; <$broker_fh> };
close $broker_fh;
my ($rpc_budget) = $broker_source =~ /my \$MAX_BUDGET = .*? \|\| (\d+);/;
my ($client_framing) = $broker_source =~ /my \$CLIENT_READ_TIMEOUT = (\d+);/;
my $max_request = $rpc_budget + 2 * $client_framing;
my ($service_stop) = $service =~ /^TimeoutStopSec=(\d+)$/m;
cmp_ok($service_stop // 0, '>', $max_request, 'systemd stop timeout covers RPC and both client frames');

subtest 'supervisor waits for workers but kills any who exceed the drain limit' => sub {
    local $SIG{TERM};
    local $SIG{INT};
    @events = ();
    my $pid = 42;
    $fork = sub { $pid };
    $kill = sub {
        push @events, "signal @_";
        return 1;
    };
    my $elapsed = 0;
    my $waits = 0;
    $waitpid = sub {
        if (++$waits == 1) {
            $SIG{TERM}->();
        }
        die "supervisor did not stop\n" if $waits > 1000;
        return 0;
    };
    local *Time::HiRes::clock_gettime = sub { $elapsed };
    local *Time::HiRes::sleep = sub { $elapsed += $_[0] };
    eval { main() };
    is($@, "exit 0\n", 'parent exits after bounding the wait');
    is_deeply([grep { /^signal / } @events], ["signal TERM $pid", "signal KILL $pid"],
        'only the lingering worker is escalated to KILL');
    cmp_ok($elapsed, '>=', $max_request, 'worker gets the full request window to finish');
    cmp_ok($elapsed, '<', $service_stop // 0, 'parent stops before the systemd deadline');
};

subtest 'supervisor exits with failure when every worker fork fails' => sub {
    local $SIG{TERM};
    local $SIG{INT};
    @events = ();
    $fork = sub { $! = EAGAIN; return undef };
    my $waits = 0;
    $waitpid = sub {
        die "supervisor still waiting with no children\n" if ++$waits > 1;
        $! = ECHILD;
        return -1;
    };
    eval { main() };
    is($@, "exit 1\n", 'systemd gets a failure exit instead of a busy loop');
    ok(!grep($_ eq 'ready', @events), 'broker never announces readiness without a worker');
};

subtest 'supervisor exits with failure when the last worker cannot be replaced' => sub {
    local $SIG{TERM};
    local $SIG{INT};
    @events = ();
    my $pid = 42;
    my $attempts = 0;
    $fork = sub { return ++$attempts == 1 ? $pid : undef };
    my $waits = 0;
    $waitpid = sub {
        return $pid if ++$waits == 1;
        die "supervisor still waiting with no children\n" if $waits > 2;
        $! = ECHILD;
        return -1;
    };
    eval { main() };
    is($attempts, 2, 'supervisor attempted a replacement');
    is($@, "exit 1\n", 'systemd gets a failure exit when capacity reaches zero');
};

done_testing();
