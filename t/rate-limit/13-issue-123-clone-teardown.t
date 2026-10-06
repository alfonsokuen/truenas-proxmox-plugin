#!/usr/bin/perl
# Unit tests for the three #123 fixes:
#
#   Fix A — _teardown_snapshot_device gains a readiness barrier and a
#           bounded EBUSY retry around _tn_dataset_delete. The retry
#           also readbacks via _tn_dataset_get after each "success"
#           reported by TN, because TN 26.0 BETA.36 can return
#           deleted=true while leaving the zvol live (observed on this
#           test env; Barbapapade's 25.10.6 surfaces a visible EBUSY
#           and takes the explicit-EBUSY branch instead).
#
#   Fix B — _is_retryable_error reorders its classifiers so that
#           authoritative error types (EBUSY, EINVAL, auth, not-found,
#           "has dependent clones", ZFSPathAlreadyExistsException) run
#           BEFORE the loose substring heuristic in _is_connection_error.
#           Without this, any error whose embedded Python traceback
#           mentions a frame or local named "timeout", "connection
#           reset", etc. gets misclassified as retryable and loops.
#
#   Fix C — volume_snapshot_delete now DIES when _teardown_snapshot_device
#           fails, instead of warning + continuing to pool.snapshot.delete.
#           The old path produced the exact outcome Barbapapade reported:
#           a vzdump archive is written to PBS, the dependent clone is
#           not cleaned, the origin snapshot delete fails, PVE's vzdump
#           reports TASK OK despite the failure, and every subsequent
#           backup trips on lock=snapshot-delete.
#
# Everything here is in-process and does NOT require a TrueNAS, a
# broker, or a running storage. We monkey-patch the plugin's internal
# helpers to drive deterministic behavior.
#
# What we assert:
#   Fix B:
#     - EBUSY errors with "timeout" string inside their Python traceback
#       are NOT retryable (regression gate on the ordering fix).
#     - "has dependent clones" is NOT retryable.
#     - EINVAL with "connection reset" in traceback is NOT retryable.
#     - ZFSPathAlreadyExistsException is NOT retryable.
#     - A pure connection timeout IS retryable.
#   Fix A:
#     - A transient EBUSY on _tn_dataset_delete that clears on the
#       second attempt completes without an error.
#     - A persistent EBUSY exhausts the ladder and dies with the
#       "after bounded retry" message.
#     - A non-EBUSY error (EINVAL) breaks out immediately — no further
#       dataset-delete calls after the first failure.
#     - "does not exist" is treated as success (concurrent teardown
#       won the race).
#     - TN silent-success (reports deleted, zvol still live) is caught
#       by the post-delete readback via _tn_dataset_get. Looks the same
#       to the ladder as a visible EBUSY and dies after the budget with
#       the "TN masked EBUSY" message.
#   Fix C:
#     - When _teardown_snapshot_device dies, volume_snapshot_delete
#       dies BEFORE calling _api_call_mutate on pool.snapshot.delete,
#       and the die message names the clone-teardown cause.
#     - When _teardown_snapshot_device succeeds, pool.snapshot.delete
#       is reached (positive-path control).

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/lib";
use Test::More;

my $plugin_loaded = eval {
    require PVE::Storage::Custom::TrueNASPlugin;
    1;
};
if (!$plugin_loaded) {
    plan skip_all => "PVE::Storage::Custom::TrueNASPlugin not loadable: $@";
}

my $pkg = 'PVE::Storage::Custom::TrueNASPlugin';

# _is_retryable_error is a FUNCTION, not a method — call it fully
# qualified so Perl does not inject $pkg as the first argument. (The
# previous version of this test used $pkg->_is_retryable_error(...)
# and the tests passed by accident: $pkg itself never matches any
# retry pattern, so the function returned 0 regardless of the real
# input. The regression is in #123's offline test suite as well.)
my $is_retryable = \&PVE::Storage::Custom::TrueNASPlugin::_is_retryable_error;

# ============================================================
# Fix B — _is_retryable_error classifier ordering
# ============================================================

# A real EBUSY payload from middlewared includes a Python traceback. The
# plain substring "timeout" shows up in socket.c / timeout.py frames even
# when the actual error has nothing to do with a timeout. Pre-fix, this
# matched _is_connection_error and classified the error as retryable.
my $ebusy_with_traceback_timeout = <<'EOF';
JSON-RPC error: {"data":{"errname":"EBUSY","reason":"[EBUSY] cannot destroy 'tank/proxmox/vzdump-vm-100-disk-0-vzdump-e52a4751': dataset is busy","trace":{"formatted":"Traceback (most recent call last):\n  File \"/usr/lib/python3/dist-packages/middlewared/plugins/zfs/dataset_crud.py\", line 221, in do_delete\n    dataset.delete(timeout=30)\n  File \"/usr/lib/python3/dist-packages/middlewared/utils/service/call_mixin.py\", line 88, in call_sync2\n    return self.middleware.call_sync2(...timeout=self.timeout)\n"}}}
EOF

ok(!$is_retryable->($ebusy_with_traceback_timeout),
    'Fix B: EBUSY with "timeout" inside traceback is NOT retryable');

my $einval_dependent_clone = <<'EOF';
JSON-RPC error: {"data":{"errname":"EINVAL","reason":"[EINVAL] cannot destroy 'tank/proxmox/vm-100-disk-0@vzdump': snapshot has dependent clones\nconnection reset while enumerating holders","trace":{"formatted":"..."}}}
EOF

ok(!$is_retryable->($einval_dependent_clone),
    'Fix B: EINVAL "has dependent clones" with "connection reset" in trace is NOT retryable');

ok(!$is_retryable->('ZFSPathAlreadyExistsException: path already exists on the pool'),
    'Fix B: ZFSPathAlreadyExistsException is NOT retryable');

ok(!$is_retryable->("CallError: [EBUSY] dataset tank/x is busy\n  File \"middlewared/utils.py\" timeout_handler"),
    'Fix B: bare EBUSY with "timeout_handler" in trace is NOT retryable');

# Positive control: a pure network timeout IS still retryable.
ok($is_retryable->('Operation timed out'),
    'Fix B: pure network timeout IS still retryable');
ok($is_retryable->('WS read payload failed'),
    'Fix B: WS framing error IS still retryable');

# ============================================================
# Fix A — bounded EBUSY retry inside _teardown_snapshot_device
# ============================================================
# Approach: monkey-patch every helper _teardown_snapshot_device touches
# so we can drive the retry ladder deterministically. We only care
# about the delete-ladder behavior; the transport-specific branch is
# collapsed to a no-op.

# Minimal $scfg sufficient for parse_volname and _snapshot_clone_paths.
my $scfg = {
    tn_transport_mode  => 'nvme-tcp',   # choose the simpler branch
    tn_dataset         => 'tank/proxmox',
    tn_subsystem_nqn   => 'nqn.test',
    tn_discovery_portal=> '192.0.2.1:4420',
    tn_api_host        => '192.0.2.1',
    tn_api_key         => 'x',
};

# A valid volname of the NVMe form, so parse_volname succeeds.
my $volname  = 'vol-vm-100-disk-0-ns11111111-1111-1111-1111-111111111111';
my $snapname = 'vzdump';

# Collapse the nvme-tcp transport branch and udev settle.
no warnings 'redefine';
*PVE::Storage::Custom::TrueNASPlugin::_nvme_delete_namespace = sub { return 1; };
*PVE::Tools::run_command = sub { return 0; };

my @delete_calls;
my $delete_outcomes;   # arrayref of outcomes keyed by call index

*PVE::Storage::Custom::TrueNASPlugin::_tn_dataset_delete = sub {
    my ($s, $full) = @_;
    push @delete_calls, $full;
    my $idx = $#delete_calls;
    my $outcome = $delete_outcomes->[$idx] // $delete_outcomes->[-1];
    if (ref($outcome) eq 'CODE') { return $outcome->(); }
    if ($outcome eq 'ok')         { return 1; }  # TN says deleted + readback agrees
    if ($outcome eq 'silent_ok')  { return 1; }  # TN says deleted BUT readback finds it
    if ($outcome eq 'ebusy') { die "[EBUSY] dataset is busy\n"; }
    if ($outcome eq 'gone')  { die "InstanceNotFound: dataset does not exist\n"; }
    if ($outcome eq 'einval'){ die "[EINVAL] bad argument\n"; }
    die "test harness: unknown outcome $outcome\n";
};

# Readback used by Fix A to catch TN's silent-success. Behavior keyed on
# the current $delete_outcomes[idx-1]: a prior "ok" → return undef+die
# (gone); a prior "silent_ok" → return a hashref (still there).
my @get_calls;
*PVE::Storage::Custom::TrueNASPlugin::_tn_dataset_get = sub {
    my ($s, $full) = @_;
    push @get_calls, $full;
    my $idx = $#delete_calls;  # last delete attempt index
    my $outcome = $delete_outcomes->[$idx] // $delete_outcomes->[-1];
    if ($outcome eq 'silent_ok') {
        return { id => $full, name => $full };   # dataset still exists
    }
    # 'ok' → gone; raise ENOENT so Fix A takes the "readback confirms gone" branch.
    die "InstanceNotFound: $full does not exist\n";
};

# usleep is used by Fix A for the backoff ladder. Replace with a no-op
# so tests run fast rather than literally sleeping 7.5 s. Perl needs the
# ($) prototype to match Time::HiRes::usleep's signature or it emits a
# "Prototype mismatch" warning on redefinition.
*PVE::Storage::Custom::TrueNASPlugin::usleep = sub ($) { return 1; };
use warnings 'redefine';

# Case: transient EBUSY on first attempt, success on second
@delete_calls = (); $delete_outcomes = ['ebusy', 'ok'];
my $err = eval { $pkg->_teardown_snapshot_device($scfg, $volname, $snapname); $@ // '' };
is($@, '', 'Fix A: transient EBUSY retries and succeeds');
is(scalar(@delete_calls), 2, 'Fix A: transient EBUSY took exactly 2 dataset-delete attempts');

# Case: persistent EBUSY exhausts the ladder (5 attempts)
@delete_calls = (); $delete_outcomes = ['ebusy'];
eval { $pkg->_teardown_snapshot_device($scfg, $volname, $snapname) };
like($@, qr/after bounded retry/i,
    'Fix A: persistent EBUSY dies with "after bounded retry" message');
is(scalar(@delete_calls), 5,
    'Fix A: persistent EBUSY attempted the full 5-step ladder');

# Case: concurrent teardown won the race (dataset already gone) → success
@delete_calls = (); $delete_outcomes = ['gone'];
eval { $pkg->_teardown_snapshot_device($scfg, $volname, $snapname) };
is($@, '', 'Fix A: "does not exist" treated as success');
is(scalar(@delete_calls), 1, 'Fix A: "does not exist" takes exactly 1 attempt');

# Case: non-EBUSY, non-notfound error (EINVAL) breaks immediately
@delete_calls = (); $delete_outcomes = ['einval'];
eval { $pkg->_teardown_snapshot_device($scfg, $volname, $snapname) };
like($@, qr/EINVAL/, 'Fix A: EINVAL propagates');
is(scalar(@delete_calls), 1,
    'Fix A: EINVAL breaks the ladder immediately — no further attempts');

# Case: TN masks EBUSY (reports delete success but readback still finds
# the dataset). Fix A's readback synthesizes an EBUSY and loops.
@delete_calls = (); @get_calls = (); $delete_outcomes = ['silent_ok'];
eval { $pkg->_teardown_snapshot_device($scfg, $volname, $snapname) };
like($@, qr/TN masked EBUSY/,
    'Fix A: silent-success caught by readback dies with "TN masked EBUSY"');
is(scalar(@delete_calls), 5,
    'Fix A: silent-success runs full 5-step ladder (readback refuses each)');
is(scalar(@get_calls), 5,
    'Fix A: silent-success triggers readback after every successful delete');

# Case: silent-success on first attempt, real gone on second. Covers the
# recovery path when the holder releases the FD mid-ladder.
@delete_calls = (); @get_calls = (); $delete_outcomes = ['silent_ok', 'gone'];
eval { $pkg->_teardown_snapshot_device($scfg, $volname, $snapname) };
is($@, '', 'Fix A: silent-success then gone completes without error');
is(scalar(@delete_calls), 2,
    'Fix A: silent-success-then-gone took exactly 2 delete attempts');

# ============================================================
# Fix C — volume_snapshot_delete propagates teardown failure
# ============================================================
# cluster_lock_storage normally serializes via pmxcfs; here we just
# invoke the callback inline. Patch _api_call_mutate so we can observe
# whether pool.snapshot.delete got called despite a failed teardown.

my @mutate_calls;
no warnings 'redefine';
*PVE::Storage::Custom::TrueNASPlugin::cluster_lock_storage = sub {
    my ($class, $sid, $x, $y, $cb) = @_;
    return $cb->();
};
*PVE::Storage::Custom::TrueNASPlugin::_api_call_mutate = sub {
    my ($s, $method, @rest) = @_;
    push @mutate_calls, $method;
    return 1;
};
*PVE::Storage::Custom::TrueNASPlugin::_handle_api_result_with_job_support = sub {
    return { success => 1, result => 1 };
};
use warnings 'redefine';

# Case: teardown dies → pool.snapshot.delete MUST NOT be called.
@mutate_calls = ();
no warnings 'redefine';
*PVE::Storage::Custom::TrueNASPlugin::_teardown_snapshot_device = sub {
    die "simulated teardown EBUSY\n";
};
use warnings 'redefine';

eval { $pkg->volume_snapshot_delete($scfg, 'teststore', $volname, $snapname) };
like($@, qr/refusing to delete.*ephemeral vzdump clone/i,
    'Fix C: teardown failure causes volume_snapshot_delete to die with specific message');
is(scalar(grep { $_ eq 'pool.snapshot.delete' } @mutate_calls), 0,
    'Fix C: pool.snapshot.delete NOT called when teardown fails');

# Case: teardown succeeds → pool.snapshot.delete IS called (positive control).
@mutate_calls = ();
no warnings 'redefine';
*PVE::Storage::Custom::TrueNASPlugin::_teardown_snapshot_device = sub { return 1; };
use warnings 'redefine';

eval { $pkg->volume_snapshot_delete($scfg, 'teststore', $volname, $snapname) };
is($@, '', 'Fix C: positive path — teardown success does not die');
is(scalar(grep { $_ eq 'pool.snapshot.delete' } @mutate_calls), 1,
    'Fix C: pool.snapshot.delete called exactly once on positive path');

done_testing();
