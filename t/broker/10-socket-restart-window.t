#!/usr/bin/perl
use strict;
use warnings;
use Errno qw(EACCES ECONNREFUSED ENOENT);
use FindBin;
use IO::Socket::UNIX ();
use lib "$FindBin::Bin/../nvme/lib";
use Test::More;
use Time::HiRes ();

require "$FindBin::Bin/../../TrueNASPlugin.pm";
my $open = PVE::Storage::Custom::TrueNASPlugin->can('_ws_get_persistent');
local $ENV{TRUENAS_PLUGIN_ALLOW_DIRECT_WS};
local $PVE::Storage::Custom::TrueNASPlugin::_api_deadline;

my ($elapsed, $attempts);
no warnings 'redefine', 'once';
local *Time::HiRes::clock_gettime = sub { $elapsed };
local *Time::HiRes::sleep = sub { $elapsed += $_[0] };

subtest 'the client bridges a broker restart across ENOENT and ECONNREFUSED' => sub {
    ($elapsed, $attempts) = (0, 0);
    my $socket = bless {}, 'BrokerTest::Socket';
    local *IO::Socket::UNIX::new = sub {
        ++$attempts;
        return $socket if $elapsed >= 7.5;
        $! = $elapsed < 2 ? ENOENT : ECONNREFUSED;
        return undef;
    };

    my $conn = eval { $open->({}) };
    is($@, '', 'the first request survives the simulated restart');
    is($conn && $conn->{sock}, $socket, 'connects once the replacement broker is ready');
    cmp_ok($elapsed, '>=', 7.5, 'measured the complete simulated outage');
    cmp_ok($elapsed, '<=', 8, sprintf('recovered within one poll (%.2f s)', $elapsed));
};

subtest 'a permanently missing broker cannot hold the client past 30 seconds' => sub {
    ($elapsed, $attempts) = (0, 0);
    local *IO::Socket::UNIX::new = sub {
        ++$attempts;
        $! = ENOENT;
        return undef;
    };

    eval { $open->({}) };
    like($@, qr/broker socket missing/, 'connection exhaustion keeps the actionable error');
    cmp_ok($attempts, '>', 1, 'ENOENT is retried');
    cmp_ok($elapsed, '>=', 7.5, 'the restart window can cover a short drain');
    cmp_ok($elapsed, '<=', 30, sprintf('bounded maximum outage wait (%.2f s)', $elapsed));
};

subtest 'permission errors are not treated as a restart' => sub {
    ($elapsed, $attempts) = (0, 0);
    local *IO::Socket::UNIX::new = sub {
        ++$attempts;
        $! = EACCES;
        return undef;
    };

    eval { $open->({}) };
    like($@, qr/broker socket missing/, 'the call fails closed');
    is($attempts, 1, 'does not retry EACCES');
    is($elapsed, 0, 'does not wait for the restart window');
};

done_testing;
