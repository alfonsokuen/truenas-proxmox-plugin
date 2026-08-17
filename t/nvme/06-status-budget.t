#!/usr/bin/perl
# status() must not hold pvestatd hostage.
#
# pvestatd is one long-lived process that calls status() every 10 seconds for
# every configured storage, one after another. There is no per-storage timeout
# and no way for a plugin to say "skip me, I'm slow". So time spent inside this
# plugin's status() is time no OTHER storage on the node gets to report - a
# slow TrueNAS stops the node's metrics entirely, not just its own.
#
# Two things made that reachable. The pool-health lookup ran with the default
# three retries, so one slow call became four broker deadlines plus backoff -
# on the order of two minutes - while the capacity lookup right beside it had
# already been given retry_max => 0 for exactly this reason. And the capacity
# cache, which exists to absorb pvestatd, had a TTL of 10 seconds against a 10
# second poll: an entry written at t=0 is read at t=10, the freshness test is a
# strict "age < ttl", and 10 < 10 is false, so it missed every single time.
#
# These tests assert on WALL CLOCK, which nothing else in the suite does. They
# are deliberately generous - the point is to catch a retry storm or an
# unbounded wait, not to measure milliseconds.
#
# Run with:  prove -v t/nvme/06-status-budget.t

use strict;
use warnings;
use Test::More;
use FindBin;
use Time::HiRes qw(time sleep);

my $PLUGIN = "$FindBin::Bin/../../TrueNASPlugin.pm";
unless (eval { require $PLUGIN; 1 }) {
    plan skip_all => "cannot load TrueNASPlugin.pm (needs PVE perl modules): $@";
}

my $PKG = 'PVE::Storage::Custom::TrueNASPlugin';

my @calls;
my $latency = 0;      # seconds each simulated API call takes
my $throw   = undef;  # error to throw from every API call

{
    no strict 'refs';
    no warnings 'redefine';
    *{"${PKG}::_log"} = sub { 1 };
    # status() also reconciles NVMe portals; that path is pure sysfs and is
    # covered elsewhere. Stub it so this file measures the API side only.
    *{"${PKG}::_nvme_connect"} = sub { 1 };
    *{"${PKG}::_api_call"} = sub {
        my ($scfg, $method, $params, $opts) = @_;
        # Read the option exactly as the real _api_call does - only
        # $opts->{retry_opts} - and deliberately not the flat
        # $opts->{retry_max}. An earlier draft of this stub accepted both, and
        # that is precisely how it came to approve a fix that did nothing: the
        # call site had been given { retry_max => 0 }, _api_call ignored it and
        # kept its default of three retries, and this test reported the policy
        # as disabled because the stub was more forgiving than the code. A stub
        # that accepts more shapes than the thing it stands in for measures its
        # own tolerance.
        my $rmax = $opts->{retry_opts} ? $opts->{retry_opts}{retry_max} : undef;
        push @calls, { method => $method, retry_max => $rmax };
        sleep($latency) if $latency;
        die $throw if defined $throw;
        return [ { name => 'tank', status => 'ONLINE', healthy => 1 } ]
            if $method eq 'pool.query';
        return { id => 'tank/pve', available => { parsed => 1000 },
                 used => { parsed => 500 }, type => 'FILESYSTEM' };
    };
}

my $scfg = {
    tn_dataset => 'tank/pve', tn_api_host => '198.51.100.7',
    tn_transport_mode => 'nvme',
};

sub call_status {
    @calls = ();
    my $t0 = time();
    my @r = eval { $PKG->status('store', $scfg, {}) };
    return (time() - $t0, $@, [@calls], \@r);
}

# ---------------------------------------------------------------------------
# The retry policy on the status path
# ---------------------------------------------------------------------------

# The important assertion in this file. A slow backend must cost roughly one
# round trip per call, not one round trip times the retry count: pvestatd is
# serial, so the multiplier lands on every storage the node has.
{
    $throw = "broker: read timeout after 30s\n";
    $latency = 0.4;
    my ($el, $err, $calls) = call_status();
    $throw = undef; $latency = 0;

    my %tried;
    $tried{$_->{method}}++ for @$calls;
    for my $m (sort keys %tried) {
        cmp_ok($tried{$m}, '<=', 1, "$m is attempted once on the status path, not retried");
    }
    cmp_ok($el, '<', 3,
        'a failing backend does not multiply into a multi-second stall')
        or diag(sprintf("status() took %.2fs making %d call(s)", $el, scalar @$calls));
}

# And the calls that do go out must say so explicitly, so a later edit cannot
# silently reinstate the default retry count.
{
    my ($el, $err, $calls) = call_status();
    my @retrying = grep { !defined($_->{retry_max}) || $_->{retry_max} > 0 } @$calls;
    is(scalar(@retrying), 0, 'every API call reachable from status() disables retries')
        or diag("still retrying: " . join(', ', map { $_->{method} } @retrying));
}

# ---------------------------------------------------------------------------
# The capacity cache has to be able to hit
# ---------------------------------------------------------------------------

# A TTL equal to the poll interval can never hit, which is how the cache came
# to be bypassed on every single poll.
{
    my $ttl = eval { no strict 'refs'; ${"${PKG}::STATUS_CAPACITY_TTL_S"} };
    # The variable is a file lexical, so read it from the source instead.
    unless (defined $ttl) {
        if (open my $fh, '<', $PLUGIN) {
            while (my $l = <$fh>) {
                if ($l =~ /^my \$STATUS_CAPACITY_TTL_S\s*=\s*(\d+)/) { $ttl = $1; last }
            }
            close $fh;
        }
    }
    ok(defined $ttl, 'the capacity cache TTL is discoverable');
    cmp_ok($ttl, '>', 10,
        'the capacity TTL is longer than pvestatd\'s 10s poll, so the cache can hit');
}

# Back to back polls against a healthy backend: the second must be cheaper than
# the first, or the cache is not doing its job.
{
    my ($el1, undef, $calls1) = call_status();
    my ($el2, undef, $calls2) = call_status();
    cmp_ok(scalar(@$calls2), '<=', scalar(@$calls1),
        'a second poll costs no more API calls than the first');
}

# ---------------------------------------------------------------------------
# A dead backend is reported, not waited on
# ---------------------------------------------------------------------------

{
    $throw = "Connection refused\n";
    my ($el, $err, $calls, $r) = call_status();
    $throw = undef;
    ok(!$err, 'a dead backend does not throw out of status()') or diag("died: $err");
    cmp_ok($el, '<', 3, '...and returns promptly rather than blocking pvestatd');
}

done_testing();
