#!/usr/bin/perl
# Waiting on a long-running TrueNAS job has to actually reach the job.
#
# _wait_for_job_completion polled with core.call wrapping core.get_jobs. Both
# halves of that were wrong on SCALE 25.10, and both were measured against a
# live target rather than inferred:
#
#   core.call([...])                 -> -32601 Method does not exist
#   core.get_jobs([{ id => 1 }])     -> EINVAL filters: Input should be a valid list
#   core.get_jobs([[['id','=',1]]])  -> ok
#
# core.call is gone from the JSON-RPC API entirely. So every poll threw, the
# consecutive-failure counter hit five, and the wait gave up with "API
# unavailable" - meaning no operation that returns a job id could be waited on
# at all. Nothing surfaced: the log line is level 1 and tn_debug defaults to 0.
#
# These tests pin the call down at the API layer, because that is where it was
# wrong. A stub records what the plugin asks for, and the assertions are about
# the method name and the shape of the filter - not about the plugin's return
# value, which was the same either way while the call was failing.
#
# Run with:  prove -v t/nvme/10-job-wait.t

use strict;
use warnings;
use Test::More;
use FindBin;

my $PLUGIN = "$FindBin::Bin/../../TrueNASPlugin.pm";
unless (eval { require $PLUGIN; 1 }) {
    plan skip_all => "cannot load TrueNASPlugin.pm (needs PVE perl modules): $@";
}

my $PKG = 'PVE::Storage::Custom::TrueNASPlugin';
my $wait = $PKG->can('_wait_for_job_completion');
plan skip_all => "_wait_for_job_completion not found" unless $wait;

my @calls;
my $reply = [ { id => 42, state => 'SUCCESS' } ];

{
    no strict 'refs';
    no warnings 'redefine';
    *{"${PKG}::_log"} = sub { 1 };
    *{"${PKG}::_api_call"} = sub {
        my ($scfg, $method, $params) = @_;
        push @calls, { method => $method, params => $params };
        return $reply;
    };
}

my $scfg = { tn_dataset => 'tank/pve', tn_api_host => '198.51.100.7' };

sub run_wait {
    @calls = ();
    my $r = eval { $wait->($scfg, 42, 5) };
    return ($r, $@, [@calls]);
}

# ---------------------------------------------------------------------------
# The method that is actually called
# ---------------------------------------------------------------------------

{
    my ($r, $err, $calls) = run_wait();
    ok(!$err, 'waiting on a job does not die') or diag("died with: $err");
    ok(scalar @$calls, 'it does poll the API at least once');

    my %used; $used{ $_->{method} }++ for @$calls;
    ok(!$used{'core.call'},
        'core.call is not used - it does not exist on SCALE 25.10')
        or diag("still calling: " . join(', ', sort keys %used));
    ok($used{'core.get_jobs'}, 'core.get_jobs is called directly instead');
}

# ---------------------------------------------------------------------------
# The shape of the filter
# ---------------------------------------------------------------------------

# A hash where the API wants a list is rejected with EINVAL, which the polling
# loop cannot tell apart from any other failure - it just counts to five and
# gives up. So the shape matters as much as the name.
{
    my (undef, undef, $calls) = run_wait();
    my ($poll) = grep { $_->{method} eq 'core.get_jobs' } @$calls;
    ok($poll, 'found the core.get_jobs call') or done_testing(), exit;

    is(ref $poll->{params}, 'ARRAY', 'params is an array');
    is(ref $poll->{params}[0], 'ARRAY', 'the first argument is a filter LIST, not a hash');
    is(ref $poll->{params}[0][0], 'ARRAY', '...containing a filter triple');
    is_deeply($poll->{params}[0][0], [ 'id', '=', 42 ],
        '...that selects the job we are waiting on');
}

# ---------------------------------------------------------------------------
# And that the answer is still read correctly
# ---------------------------------------------------------------------------

{
    $reply = [ { id => 42, state => 'SUCCESS' } ];
    my ($r) = run_wait();
    ok($r && $r->{success}, 'a SUCCESS job is reported as success');
}
{
    $reply = [ { id => 42, state => 'FAILED', error => 'dataset is busy' } ];
    my ($r) = run_wait();
    ok($r && !$r->{success}, 'a FAILED job is reported as failure');
    like($r->{error} // '', qr/busy/, '...carrying the reason back to the caller');
}

# An empty result is "not yet", not "gone". It must not be mistaken for success.
{
    $reply = [];
    my ($r) = run_wait();
    ok($r && !$r->{success}, 'a job that never appears times out rather than passing');
}

done_testing();
