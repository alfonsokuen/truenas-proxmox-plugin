#!/usr/bin/perl
use strict;
use warnings;
use Errno qw(EAGAIN);
use FindBin;
use Test::More;

my ($fork, $waitpid, $kill);
BEGIN {
    *CORE::GLOBAL::fork = sub () { $fork->() };
    *CORE::GLOBAL::waitpid = sub ($$) { $waitpid->(@_) };
    *CORE::GLOBAL::kill = sub { $kill->(@_) };
    *CORE::GLOBAL::exit = sub (;$) { die "exit $_[0]\n" };
    *CORE::GLOBAL::unlink = sub { return scalar @_ };
}

local $ENV{TRUENAS_BROKER_WORKERS} = 2;
do "$FindBin::Bin/../../tools/truenas-plugin-broker";
die $@ if $@;
ok(defined &main, 'loaded the real broker supervisor');

{
    package BrokerTest::Listener;
    sub close {}
    sub shutdown { 1 }
}

my ($elapsed, $reaped, $ready) = (0, 0, 0);
my (@attempt_times, @draining);
$fork = sub {
    push @attempt_times, $elapsed;
    return 41 if @attempt_times == 1;
    return 43 if @attempt_times == 3;
    return 45 if @attempt_times == 5;
    $! = EAGAIN;
    return undef;
};
$kill = sub { @draining = @_[1 .. $#_]; return scalar @draining };
$waitpid = sub {
    return shift @draining if @draining;
    return 43 if @attempt_times == 3 && !$reaped++;
    $SIG{TERM}->() if @attempt_times >= 5 || $elapsed >= 20;
    return 0;
};

no warnings 'redefine', 'once';
local *ensure_rundir = sub {};
local *daemonize = sub {};
local *write_pidfile = sub {};
local *linfo = sub {};
local *ldebug = sub {};
local *lwarn = sub {};
local *lerr = sub {};
local *sd_notify_ready = sub { ++$ready };
local *make_listener = sub { bless {}, 'BrokerTest::Listener' };
local *Time::HiRes::clock_gettime = sub { $elapsed };
local *Time::HiRes::sleep = sub { $elapsed += $_[0] };

eval { main() };
is($@, "exit 0\n", 'supervisor stops after restoring the pool or reaching the test deadline');
is($ready, 1, 'one surviving worker keeps the service ready');
is(scalar @attempt_times, 5, 'initial and replacement fork failures both get retried');
SKIP: {
    skip 'the supervisor never attempted the replacements', 3 if @attempt_times < 5;
    cmp_ok($attempt_times[2], '>', $attempt_times[1], 'waits before filling the initial vacancy');
    cmp_ok($attempt_times[3], '>', $attempt_times[2], 'does not instantly respawn a crashing worker');
    cmp_ok($attempt_times[4] - $attempt_times[3], '>', $attempt_times[2] - $attempt_times[1],
        'repeated failures lengthen the retry interval');
}

done_testing;
