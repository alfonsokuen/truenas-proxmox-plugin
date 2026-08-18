#!/usr/bin/perl
# One API call must be bounded in TIME, not just in attempts.
#
# _retry_with_backoff counted attempts and never looked at the clock, so the
# worst case was a product nobody multiplied: tn_api_retry_max times the
# per-attempt timeout, plus the backoff sum. The storages in the field carry
# tn_api_retry_max 5, which against an unreachable array is ~150s per call
# through the broker and closer to fourteen minutes against a direct
# connection. Measured with tools/i32-apiloss.sh: pvesm alloc had still not
# returned after 180s while holding the storage lock, and pvestatd stopped
# writing metrics for the whole time.
#
# The budget bounds when a new attempt may START. It cannot interrupt an
# attempt already blocked in a syscall, so the honest ceiling is "budget plus
# one attempt" -- these tests assert that, not something tighter that would
# be a lie.
#
# Assertions tagged EXPECT-FAIL(unfixed) must FAIL against the plugin without
# the budget. If they pass there, this file is not testing the defect.
#
# Run with:  prove -v t/nvme/12-api-budget.t

use strict;
use warnings;
use Test::More;
use Time::HiRes qw(time);
use FindBin;

my $PLUGIN = "$FindBin::Bin/../../TrueNASPlugin.pm";
unless (eval { require $PLUGIN; 1 }) {
    plan skip_all => "cannot load TrueNASPlugin.pm (needs PVE perl modules): $@";
}

my $PKG = 'PVE::Storage::Custom::TrueNASPlugin';
my $retry = $PKG->can('_retry_with_backoff');
plan skip_all => "_retry_with_backoff not found" unless $retry;

my @logs;
{
    no strict 'refs';
    no warnings 'redefine';
    *{"${PKG}::_log"} = sub { push @logs, [@_[1..3]]; 1 };
}

# A retryable failure, so the loop actually loops. "connection reset" is on
# the retryable list; if that ever changes this test would silently stop
# testing anything, so the first case pins the attempt count on its own.
my $RETRYABLE = "connection reset by peer\n";

sub drive {
    my (%opt) = @_;
    @logs = ();
    my $scfg = {
        tn_api_retry_max   => $opt{retry_max}   // 8,
        tn_api_retry_delay => $opt{retry_delay} // 0.05,
        (exists $opt{budget} ? (tn_api_budget_s => $opt{budget}) : ()),
    };
    my $attempts = 0;
    my $t0 = time();
    my $ok = eval {
        $retry->($scfg, 'test op', sub { $attempts++; die $RETRYABLE }, undef);
        1;
    };
    return { ok => $ok, err => $@, attempts => $attempts, elapsed => time() - $t0 };
}

# ------------------------------------------------------ the loop does loop --
# Pins the premise. If the error stops being retryable this fails loudly
# instead of making every other assertion below vacuously true.

{
    my $r = drive(retry_max => 3, retry_delay => 0.01, budget => 900);
    is($r->{attempts}, 4, 'a retryable error is attempted retry_max+1 times');
    ok(!$r->{ok}, '...and the call still fails in the end');
}

# ---------------------------------------------- a spent budget stops early --

{
    # 8 retries at 0.05s doubling is ~12.8s of pure backoff. A 2s budget must
    # cut that off long before the attempts run out.
    my $r = drive(retry_max => 8, retry_delay => 0.05, budget => 2);

    # EXPECT-FAIL(unfixed): without a budget this runs all 9 attempts.
    cmp_ok($r->{attempts}, '<', 9,
           'the call gives up before exhausting retry_max when the budget is spent')
        or diag("ran $r->{attempts} attempts in $r->{elapsed}s");

    # EXPECT-FAIL(unfixed): without a budget this takes ~12.8s.
    cmp_ok($r->{elapsed}, '<', 6,
           '...and returns in about the budget, not the full backoff sum')
        or diag("took $r->{elapsed}s");

    ok(!$r->{ok}, '...and it is a failure, not a silent success');

    # EXPECT-FAIL(unfixed): the old message says "after N retries", which
    # reads as "the array answered N times and refused".
    like($r->{err} // '', qr/gave up|budget/i,
         '...and the error says we stopped waiting, not that the array said no');
    like($r->{err} // '', qr/unknown/i,
         '...and admits the outcome is unknown');
}

# --------------------------------------- the budget never truncates success --
# If this breaks, the fix has traded a hang for an outage.

{
    @logs = ();
    my $scfg = { tn_api_retry_max => 3, tn_api_retry_delay => 0.01, tn_api_budget_s => 10 };
    my $calls = 0;
    my $res = $retry->($scfg, 'test op', sub { $calls++; return { ok => 1 } }, undef);
    is($calls, 1, 'a call that works is made exactly once');
    is_deeply($res, { ok => 1 }, '...and its result is returned untouched');
}

{
    # Succeeds on the third try, well inside the budget: retries must still work.
    my $scfg = { tn_api_retry_max => 5, tn_api_retry_delay => 0.01, tn_api_budget_s => 30 };
    my $n = 0;
    my $res = $retry->($scfg, 'test op', sub {
        $n++;
        die $RETRYABLE if $n < 3;
        return 'third time';
    }, undef);
    is($res, 'third time', 'a transient failure is still retried to success');
    is($n, 3, '...on the attempt where it recovered');
}

# --------------------------------------------- a bad budget is not obeyed ----

# A junk budget has two ways to be wrong, and they fail in opposite
# directions: treated as 0 it gives up before trying anything, treated as
# missing it goes back to being unbounded. The default (120s) is generous
# enough that this 12.8s backoff sequence runs to completion under it, so
# "all attempts ran, and it terminated" is exactly the signature of a sane
# fallback -- not of either failure mode.
{
    my $r = drive(retry_max => 8, retry_delay => 0.05, budget => 'banana');
    is($r->{attempts}, 9, 'a non-numeric budget falls back to the default, not to zero');
    cmp_ok($r->{elapsed}, '<', 30, '...and the call still terminates');
}

{
    my $r = drive(retry_max => 8, retry_delay => 0.05, budget => 0);
    is($r->{attempts}, 9, 'a zero budget falls back to the default, not to give-up-at-once');
    cmp_ok($r->{elapsed}, '<', 30, '...and the call still terminates');
}

# ------------------------------------------------- what the transport sees ---

{
    my $min = $PKG->can('_min_timeout');
    SKIP: {
        skip "_min_timeout not found", 3 unless $min;
        {
            # Outside any retry sequence there is no deadline, so the
            # configured timeout must be used unchanged.
            no strict 'refs';
            local ${"${PKG}::_api_deadline"} = undef;
            is($min->(30), 30, 'with no call in flight the configured timeout is used');

            # Mid-sequence with 5s left, a 30s window must shrink to fit.
            # _api_budget_remaining subtracts CORE time(), which is whole
            # seconds, so "5s left" can read as anything up to 5.99. That
            # granularity is immaterial against a 120s budget; the assertion
            # must not claim a precision the implementation does not have.
            local ${"${PKG}::_api_deadline"} = time() + 5;
            cmp_ok($min->(30), '<=', 6.05,
                   'with 5s of budget left, a 30s window is cut down to it');
            cmp_ok($min->(2), '<=', 2,
                   '...but a timeout already smaller than the budget is left alone');
        }
    }
}

done_testing();
