#!/usr/bin/perl
# v4 follow-ups from the dual review of v3. Three subjects share this file
# because they share one fixture (a captured _log):
#
#   1. _log_api_down_note's throttle - the piece that fixed v2's fatal flaw -
#      had ZERO test coverage: both earlier suites stub _log to `sub { 1 }`,
#      so collapsing the key to one bucket per host passed 33/33. Here _log is
#      captured into an array and the throttle contract is asserted directly.
#   2. activate_storage must CLASSIFY a failing ensure: its own probe budget
#      expiring under the marker is expected (throttled note), anything else
#      (401, DHCHAP, EINVAL) keeps the loud level-0 warning.
#   3. _nvme_reconcile_host_whitelist must not BEGIN the close-then-authorize
#      mutation without budget to finish it: dying between the two steps
#      leaves the subsystem closed with an empty host list.
#
# Run with:  prove -v t/nvme/15-api-down-log-and-guards.t

use strict;
use warnings;
use Test::More;
use FindBin;

my $PLUGIN = "$FindBin::Bin/../../TrueNASPlugin.pm";
unless (eval { require $PLUGIN; 1 }) {
    plan skip_all => "cannot load TrueNASPlugin.pm (needs PVE perl modules): $@";
}

my $PKG = 'PVE::Storage::Custom::TrueNASPlugin';
plan skip_all => "_capped_api_deadline not found (pre-v4 tree?)"
    unless $PKG->can('_capped_api_deadline');

my @LOG;
my (@MUTATIONS, $fail_api, $ensure_err, $repair_deadline);

my ($note, $capped, $host_key, $reconcile, $recently_down);
{ no strict 'refs';
  $note          = \&{"${PKG}::_log_api_down_note"};
  $capped        = \&{"${PKG}::_capped_api_deadline"};
  $host_key      = \&{"${PKG}::_cache_host_key"};
  $reconcile     = \&{"${PKG}::_nvme_reconcile_host_whitelist"};
  $recently_down = \&{"${PKG}::_api_recently_down"}; }

my $THROTTLE_STATE = do { no strict 'refs'; \%{"${PKG}::_api_down_log_last"} };

{
    no strict 'refs';
    no warnings 'redefine';
    # THE fixture: capture, don't discard. Stubbing this to `sub { 1 }` is
    # exactly how the throttle went untested through two review rounds.
    *{"${PKG}::_log"} = sub { my (undef, $lvl, $sev, $msg) = @_;
                              push @LOG, { lvl => $lvl, sev => $sev, msg => $msg }; };
    *{"${PKG}::_nvme_check_cli"} = sub { 1 };
    *{"${PKG}::_nvme_connect"}   = sub {
        my ($scfg, %opt) = @_;
        if ($opt{repair}) {
            my $dl = ${"${PKG}::_api_deadline"};
            $repair_deadline = defined($dl) ? $dl - time() : undef;
        }
        return 1;
    };
    *{"${PKG}::_nvme_ensure_subsystem"} = sub {
        die $ensure_err if defined $ensure_err; return 1; };
    *{"${PKG}::_nvme_get_hostnqn"} = sub { 'nqn.2014-08.org.nvmexpress:uuid:t15' };
    *{"${PKG}::_api_call"} = sub {
        my ($scfg, $method) = @_;
        die $fail_api if defined $fail_api;
        return [] if $method =~ /^nvmet\.(host|host_subsys)\.query$/;
        return {
            id => 'tank/pve', type => 'FILESYSTEM',
            available => { parsed => 500 }, used => { parsed => 500 },
            written   => { parsed => 500 }, quota => { parsed => 0 },
        } if $method eq 'pool.dataset.get_instance';
        return [ { name => 'tank', status => 'ONLINE', healthy => 1 } ]
            if $method eq 'pool.query';
        return [];
    };
    *{"${PKG}::_api_call_mutate"} = sub {
        my ($scfg, $method) = @_;
        push @MUTATIONS, $method;
        return { id => 5 } if $method eq 'nvmet.host.create';
        return 1;
    };
}

my $HOSTN = 0;
sub fresh_scfg {
    my (%extra) = @_;
    $HOSTN++;
    return {
        tn_dataset        => 'tank/pve',
        tn_api_host       => "203.0.113.$HOSTN",
        tn_transport_mode => 'nvme-tcp',
        tn_subsystem_nqn  => 'nqn.2011-06.com.example:t15',
        %extra,
    };
}

sub notes_logged { scalar grep { $_->{msg} =~ /marked down for another/ } @LOG }

# ------------------------------------------------ 1. the throttle contract --
{
    my $scfg = fresh_scfg();
    @LOG = ();
    $note->($scfg, 'status', 'store1', 25, 'reported inactive');
    is(notes_logged(), 1, 'first note logs');
    is($LOG[0]{lvl}, 0, '...at level 0, visible without tn_debug');
    $note->($scfg, 'status', 'store1', 24, 'reported inactive');
    is(notes_logged(), 1, 'immediate repeat with the same key is suppressed');
    $note->($scfg, 'activate_storage', 'store1', 24, 'capping');
    is(notes_logged(), 2, 'a different call site logs its own line');
    $note->($scfg, 'status', 'store2', 24, 'reported inactive');
    is(notes_logged(), 3, 'a sibling storeid on the same array logs its own line');
    $note->(fresh_scfg(), 'status', 'store1', 24, 'reported inactive');
    is(notes_logged(), 4, 'a different array logs its own line');
}

# ------------------------------------------------------- 2. tn_debug bypass --
{
    my $scfg = fresh_scfg(tn_debug => 1);
    @LOG = ();
    $note->($scfg, 'status', 'store1', 25, 'x');
    $note->($scfg, 'status', 'store1', 24, 'x');
    is(notes_logged(), 2, 'tn_debug >= 1 bypasses the throttle entirely');
}

# ----------------------------------- 3. the window follows a SHORT backoff --
{
    # This is the LOW that motivated the change: with the ceiling fixed at 60s
    # and the default 30s marker, every other marker period logged nothing.
    my $scfg = fresh_scfg(tn_status_probe_backoff_s => 30);
    my $key  = $host_key->($scfg) . '|status|store1';
    @LOG = ();
    $THROTTLE_STATE->{$key} = time() - 31;   # older than the 30s backoff, younger than 60
    $note->($scfg, 'status', 'store1', 25, 'x');
    is(notes_logged(), 1, 'backoff 30: a 31s-old entry no longer throttles');
    $THROTTLE_STATE->{$key} = time() - 20;
    $note->($scfg, 'status', 'store1', 25, 'x');
    is(notes_logged(), 1, '...but a 20s-old one still does');

    my $scfg2 = fresh_scfg(tn_status_probe_backoff_s => 300);
    my $key2  = $host_key->($scfg2) . '|status|store1';
    $THROTTLE_STATE->{$key2} = time() - 61;
    @LOG = ();
    $note->($scfg2, 'status', 'store1', 25, 'x');
    is(notes_logged(), 1, 'backoff 300: the ceiling (60s) wins, 61s-old logs');
    $THROTTLE_STATE->{$key2} = time() - 40;
    $note->($scfg2, 'status', 'store1', 25, 'x');
    is(notes_logged(), 1, '...and 40s-old is still inside the ceiling');
}

# ------------------------------------------------- 4. clock-backwards guard --
{
    my $scfg = fresh_scfg();
    my $key  = $host_key->($scfg) . '|status|store1';
    $THROTTLE_STATE->{$key} = time() + 9999;   # NTP stepped the clock back
    @LOG = ();
    $note->($scfg, 'status', 'store1', 25, 'x');
    is(notes_logged(), 1, 'a last-logged timestamp in the future does not mute forever');
}

# ---------------------------------------------- 5. _capped_api_deadline math --
{
    no strict 'refs';
    my $now = time();
    my $d = $capped->();
    ok($d >= $now + 1 && $d <= $now + 3, 'no outer deadline: cap is ~now+2');
    {
        local ${"${PKG}::_api_deadline"} = $now + 1;
        is($capped->(), $now + 1, 'a NEARER outer deadline wins - the cap only shrinks');
    }
    {
        local ${"${PKG}::_api_deadline"} = $now + 100;
        my $d2 = $capped->();
        ok($d2 <= $now + 3, 'a FARTHER outer deadline is ignored - the cap still caps');
    }
}

# ------------------------- 5b. the reserve threshold invariant, pinned down --
{
    no strict 'refs';
    my $probe = &{"${PKG}::API_DOWN_PROBE_BUDGET_S"}();
    my $wl    = &{"${PKG}::WHITELIST_MIN_BUDGET_S"}();
    ok($wl > $probe,
       "WHITELIST_MIN_BUDGET_S ($wl) > API_DOWN_PROBE_BUDGET_S ($probe): a "
       . 'marker-capped ensure must always defer the close, never start it');
}

# -------------------------- 6. activate_storage classifies a failing ensure --
sub arm_marker {
    my ($scfg) = @_;
    $fail_api = "broker: read timeout after 5s\n";
    $PKG->status('store1', $scfg, undef);
    $fail_api = undef;
    return defined($recently_down->($scfg));
}

{
    # Expected shape: probe budget expired while the marker stands.
    my $scfg = fresh_scfg();
    ok(arm_marker($scfg), 'marker armed');
    $ensure_err = "Gave up on nvmet.subsys.query after 2s (budget 2s, 1 attempt(s)); "
                . "the array did not answer in time, so the outcome is unknown: x\n";
    @LOG = ();
    $PKG->activate_storage('store1', $scfg, undef);
    ok(!(grep { $_->{sev} eq 'warning' && $_->{msg} =~ /ensure failed/ } @LOG),
       'budget-expired under the marker does NOT emit the level-0 warning');
    ok((grep { $_->{msg} =~ /hit the probe budget/ } @LOG),
       '...it emits the throttled ensure-budget note instead');

    # Unexpected shape: same marker, but the error is an auth failure.
    my $scfg2 = fresh_scfg();
    ok(arm_marker($scfg2), 'marker armed on second array');
    $ensure_err = "nvme_ensure_host: failed to update DHCHAP keys: 401 Unauthorized\n";
    @LOG = ();
    $PKG->activate_storage('store1', $scfg2, undef);
    ok((grep { $_->{sev} eq 'warning' && $_->{msg} =~ /ensure failed/ } @LOG),
       'a NON-timeout error under the marker keeps the loud warning');

    # Reviewer-1's counterexample: a NON-retryable integrity error whose
    # Python traceback happens to contain the word "timeout". The old substring
    # regex filed this as budget noise - erasing the only visible trace of the
    # one error class the retry engine logs at debug level only.
    my $scfg2b = fresh_scfg();
    ok(arm_marker($scfg2b), 'marker armed on third array');
    $ensure_err = "[EINVAL] FOREIGN KEY constraint failed: Traceback (most recent "
                . "call last): socket.timeout: timed out in middlewared/plugins
";
    @LOG = ();
    $PKG->activate_storage('store1', $scfg2b, undef);
    ok((grep { $_->{sev} eq 'warning' && $_->{msg} =~ /ensure failed/ } @LOG),
       'an integrity error towing "timeout" in its traceback stays LOUD');

    # Reviewer-2's counterexample: the retry engine's OTHER death sentence.
    # With a low retry delay the loop exhausts attempts before the deadline,
    # and that death must be filed as expected too or the warning storm the
    # classifier exists to stop comes back for those configs.
    my $scfg2c = fresh_scfg();
    ok(arm_marker($scfg2c), 'marker armed on fourth array');
    $ensure_err = "Operation failed after 3 retries: WS read failed: connection closed
";
    @LOG = ();
    $PKG->activate_storage('store1', $scfg2c, undef);
    ok(!(grep { $_->{sev} eq 'warning' && $_->{msg} =~ /ensure failed/ } @LOG),
       'retries-exhausted on a connection error under the marker is expected');
    ok((grep { $_->{msg} =~ /hit the probe budget.*connection closed/ } @LOG),
       '...and the throttled note carries the error excerpt, not just a verdict');

    # Round-3 finding (both reviewers): a WRAPPED death - the authorize dying
    # under the cap inside _nvme_ensure_host_registered - must never file as
    # probe budget (the ^ anchor is the load-bearing half of the classifier),
    # and must not re-open the per-poll warning storm either: one throttled
    # ensure-fault note per window, cause in the excerpt.
    my $scfg2d = fresh_scfg();
    ok(arm_marker($scfg2d), 'marker armed (wrapped-death case)');
    $ensure_err = "nvme_ensure_host: failed to authorize host nqn.a:uuid:x on "
                . "subsystem: Gave up on WS nvmet.host_subsys.create after 2s
";
    @LOG = ();
    $PKG->activate_storage('store1', $scfg2d, undef);
    $PKG->activate_storage('store1', $scfg2d, undef);   # second poll, same outage
    ok(!(grep { $_->{msg} =~ /hit the probe budget/ } @LOG),
       'a wrapped death never files as probe budget (anchors hold)');
    my @faults = grep { $_->{sev} eq 'warning' && $_->{msg} =~ /ensure-fault/ } @LOG;
    is(scalar @faults, 1, 'a repeated real fault under the marker throttles to ONE note');
    ok($faults[0]{msg} =~ /host_subsys\.create/, '...that carries the excerpt');
    ok(!(grep { $_->{msg} =~ /activate_storage: subsystem ensure failed/ } @LOG),
       '...replacing the unthrottled per-poll warning (6/min measured in review)');

    # No marker at all: any failure is loud.
    my $scfg3 = fresh_scfg();
    $ensure_err = "Gave up on nvmet.subsys.query after 10s (budget 10s...)\n";
    @LOG = ();
    $PKG->activate_storage('store1', $scfg3, undef);
    ok((grep { $_->{sev} eq 'warning' && $_->{msg} =~ /ensure failed/ } @LOG),
       'without the marker even a timeout stays a warning - classification is gated');
    $ensure_err = undef;
}

# ----------------------- 7. whitelist reconcile reserves budget before acting --
{
    no strict 'refs';
    my $scfg = fresh_scfg(tn_nvme_allow_any_host => 0);

    @MUTATIONS = ();
    {
        local ${"${PKG}::_api_deadline"} = time() + 1;   # marker-capped territory
        $reconcile->($scfg, 101, 1);
    }
    is(scalar @MUTATIONS, 0,
       'under a 1s budget the reconcile defers BEFORE touching allow_any_host');

    @MUTATIONS = ();
    {
        local ${"${PKG}::_api_deadline"} = time() + 30;
        $reconcile->($scfg, 102, 1);
    }
    my ($i_close) = grep { $MUTATIONS[$_] eq 'nvmet.subsys.update' } 0..$#MUTATIONS;
    my ($i_auth)  = grep { $MUTATIONS[$_] eq 'nvmet.host_subsys.create' } 0..$#MUTATIONS;
    ok(defined $i_close, 'with real budget it closes the subsystem...');
    ok(defined $i_auth && $i_auth > ($i_close // -1),
       '...and authorizes the host AFTER closing - the order the target demands');

    @MUTATIONS = ();
    $reconcile->($scfg, 103, 1);   # no deadline at all
    ok((grep { $_ eq 'nvmet.subsys.update' } @MUTATIONS),
       'no outer deadline (VM start path): unbounded budget, reconcile proceeds');

    # The HIGH from review round 2: both real call sites pass
    # cur_allow_any_host = FALSE in whitelist mode (subsystem already closed).
    # There the close is a no-op and the only work left is the authorize -
    # deferring THAT leaves the closed-and-empty state standing and kills the
    # repair-mode self-heal. The reserve must apply to the close step only.
    @MUTATIONS = ();
    {
        local ${"${PKG}::_api_deadline"} = time() + 1;
        $reconcile->($scfg, 104, 0);   # already closed, 1s budget
    }
    ok((grep { $_ eq 'nvmet.host_subsys.create' } @MUTATIONS),
       'authorize-only (already-closed subsystem) is NEVER deferred');
    ok(!(grep { $_ eq 'nvmet.subsys.update' } @MUTATIONS),
       '...and no close is re-issued for an already-closed subsystem');

    # cur=undef + short budget must DEFER: the close would run. Kills the
    # mutant that rewrites $will_close to defined()&& - which silently skipped
    # the reserve exactly where the original HIGH lived.
    @MUTATIONS = ();
    {
        local ${"${PKG}::_api_deadline"} = time() + 1;
        $reconcile->($scfg, 109, undef);
    }
    is(scalar @MUTATIONS, 0, 'cur=undef under a short budget defers (close would have run)');

    # Two subsystems deferring on the same array must EACH leave a note: the
    # per-host bucket let one storage's defer swallow its sibling's for good.
    my $scfgM = fresh_scfg(tn_nvme_allow_any_host => 0);
    ok(arm_marker($scfgM), 'marker armed (defer-key case)');
    @LOG = ();
    {
        local ${"${PKG}::_api_deadline"} = time() + 1;
        $reconcile->($scfgM, 110, 1);
        $reconcile->($scfgM, 111, 1);
    }
    is(scalar(grep { $_->{sev} eq 'warning' && $_->{msg} =~ /whitelist-defer/ } @LOG), 2,
       'defer notes are keyed per subsystem, not per host');

    # And the deferral was not sealed into the TTL cache: retrying id 101 with
    # budget must act, not skip.
    @MUTATIONS = ();
    {
        local ${"${PKG}::_api_deadline"} = time() + 30;
        $reconcile->($scfg, 101, 1);
    }
    ok((grep { $_ eq 'nvmet.subsys.update' } @MUTATIONS),
       'a deferral is not cached as success: the next budgeted ensure acts');
}

# ------------------ 8. the status() repair path observes the cap (mutant M5) --
{
    # Review round 2 proved this guard was the one v4 piece no test covered:
    # deleting it left 308/308 green. This is the assertion that kills it.
    # Two distinct arrays: a successful status() seals the capacity cache for
    # its host, and a later arm_marker() on the same host would answer from
    # cache without ever touching the API - so the marker would never arm.
    my $scfg_green = fresh_scfg();
    $repair_deadline = 12345;
    $PKG->status('store1', $scfg_green, undef);
    ok(!defined($repair_deadline) || $repair_deadline > 5,
       'no marker: the repair call runs without the short cap');

    my $scfg = fresh_scfg();
    ok(arm_marker($scfg), 'marker armed');
    $repair_deadline = undef;
    $PKG->status('store1', $scfg, undef);
    ok(defined($repair_deadline) && $repair_deadline <= 3,
       'marker standing: _nvme_connect(repair) observes a deadline <= cap');
}

# --------------- 9. the effective-budget message, exercised both ways --
{
    # Round-3: the one v5 change with zero coverage ("capped to" appears in no
    # test), plus the cosmetic negative ("capped to -3s") now clamped.
    no strict 'refs';
    my $retry = \&{"${PKG}::_retry_with_backoff"};
    my $dies  = sub { die "WS read failed: connection closed
" };
    my $opts  = { retry_max => 99, retry_delay => 0.5 };

    my $err = do { local $@;
        eval { $retry->(fresh_scfg(tn_api_budget_s => 2), 'test.op', $dies, $opts) }; $@ };
    like($err, qr/^Gave up on /, 'budget death still opens with the anchored phrase');
    unlike($err, qr/capped/, 'no outer deadline: the plain budget names itself');

    my $err2 = do { local $@; eval {
        local ${"${PKG}::_api_deadline"} = time() + 1;
        $retry->(fresh_scfg(tn_api_budget_s => 120), 'test.op', $dies, $opts);
    }; $@ };
    like($err2, qr/capped to \d+s by an outer deadline/,
        'a shrunken budget says so - and as a whole number');

    my $err3 = do { local $@; eval {
        local ${"${PKG}::_api_deadline"} = time() - 5;   # already expired
        $retry->(fresh_scfg(tn_api_budget_s => 120), 'test.op', $dies, $opts);
    }; $@ };
    like($err3, qr/capped to 0s/, 'an already-expired outer deadline clamps to 0');
    unlike($err3, qr/capped to -/, '...never a negative');
}

done_testing();
