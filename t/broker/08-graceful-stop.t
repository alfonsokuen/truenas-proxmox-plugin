#!/usr/bin/perl
use strict;
use warnings;
use FindBin;
use Test::More;
use Errno qw(EAGAIN ECHILD);

my ($fork, $waitpid, $kill, $unlink, @alarms);
BEGIN {
    *CORE::GLOBAL::fork = sub () { $fork->() };
    # The worker below runs inline (fork returns 0 in this process), so its
    # parent is this process; it exits early if getppid() says otherwise.
    *CORE::GLOBAL::getppid = sub () { $$ };
    *CORE::GLOBAL::alarm = sub (;$) { push @alarms, $_[0]; 0 };
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
    sub shutdown { ++$_[0]->{shutdowns}; return 1 }
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
    # The parent no longer waits for or escalates a draining worker, so the
    # worker bounds its own request with the window the parent used to allow.
    is(scalar(@alarms), 2, 'the request is bracketed by one alarm and one disarm');
    cmp_ok($alarms[0] // 0, '>=', $max_request, 'the worker alarm covers the RPC and both client frames');
    is($alarms[-1], 0, 'the alarm is disarmed once the request is done');
};

cmp_ok($service_stop // 0, '>', $max_request, 'systemd stop timeout covers RPC and both client frames');

# The parent used to wait up to the drain window and then SIGKILL; under
# KillMode=mixed that held the next broker back for the whole drain. Now it
# signals the workers and exits at once (they bound themselves, see the alarm
# assertions above); t/broker/13 shows the in-flight reply still arrives.
subtest 'supervisor signals the workers and exits without waiting or escalating' => sub {
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
    my $socket_removals = 0;
    $unlink = sub {
        ++$socket_removals if $_[0] =~ /broker\.sock$/;
        return scalar @_;
    };
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
    is($@, "exit 0\n", 'parent exits right after the TERM');
    is_deeply([grep { /^signal / } @events], ["signal TERM $pid"],
        'the worker is signalled once and never escalated to KILL');
    cmp_ok($elapsed, '<', 1, 'the parent does not wait for the drain');
    is($socket_removals, 1, 'the parent unpublishes the socket for the next broker');
    $unlink = sub { return scalar @_ };
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

# Inverted on purpose: the old parent kept the path until the drain ended, so
# the next broker (which can only start once the parent is gone) waited for it.
# Clients now retry ENOENT/ECONNREFUSED until the next broker binds (t/broker/10).
subtest 'the parent unpublishes the socket and pidfile before the in-flight worker exits' => sub {
    local $SIG{TERM};
    local $SIG{INT};
    @events = ();
    my $elapsed = 0;
    my $started_drain = 0;
    my $worker = 42;
    $fork = sub { $worker };
    $kill = sub { $started_drain = 1; return 1 };
    $unlink = sub {
        push @events, ['socket removed', $elapsed] if $_[0] =~ /broker\.sock$/;
        push @events, ['pidfile removed', $elapsed] if $_[0] =~ /broker\.pid$/;
        return scalar @_;
    };
    $waitpid = sub {
        if (!$started_drain) {
            $SIG{TERM}->();
            return 0;
        }
        return 0 if $elapsed < 4;
        push @events, ['worker finished', $elapsed];
        return $worker;
    };
    local *Time::HiRes::clock_gettime = sub { $elapsed };
    local *Time::HiRes::sleep = sub { $elapsed += $_[0] };
    eval { main() };
    is($@, "exit 0\n", 'supervisor exits normally');
    is_deeply([grep { ref } @events], [['socket removed', 0], ['pidfile removed', 0]],
        'both paths go at the TERM, without waiting out the four-second request');
};

subtest 'new connections are refused from the TERM until the path is unpublished' => sub {
    local $SIG{TERM};
    local $SIG{INT};
    my $elapsed = 0;
    my $worker = 43;
    my @order;
    $listener->{shutdowns} = 0;
    $fork = sub { $worker };
    # TERM first, so no idle worker wakes up for the refused connections.
    $kill = sub { push @order, 'TERM'; 1 };
    # By the time the parent unpublishes the path the listener must refuse.
    $unlink = sub {
        push @order, $listener->{shutdowns} ? 'drain refusing' : 'drain accepting'
            if $_[0] =~ /broker\.sock$/;
        return scalar @_;
    };
    $waitpid = sub {
        $SIG{TERM}->() if !@order;
        return 0;
    };
    local *Time::HiRes::clock_gettime = sub { $elapsed };
    local *Time::HiRes::sleep = sub { $elapsed += $_[0] };
    eval { main() };
    is($@, "exit 0
", 'supervisor exits normally');
    is_deeply(\@order, ['TERM', 'drain refusing'],
        'a client connecting during the drain is refused, not left in the backlog');
    is($listener->{shutdowns}, 1, 'the listener is shut down for reading exactly once');
};

done_testing();
