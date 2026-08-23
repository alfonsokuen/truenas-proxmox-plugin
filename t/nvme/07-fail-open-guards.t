#!/usr/bin/perl
# Three fail-open guards in the free path, driven both ways.
#
# Defect A: free_image's "base image still has linked clones" guard queries
# pool.dataset.query for datasets whose origin.parsed is <base>@__base__,
# inside an eval. A query that dies, or that answers with something other
# than an array, used to read as "no clones" - and the recursive+force
# destroy of the template went ahead on the strength of a transport blip.
#
# Defect B: when a namespace delete fails "in use" under
# tn_force_delete_on_inuse, _free_image_nvme counts the subsystem's active
# namespaces to decide whether a subsystem-wide _nvme_disconnect is safe. A
# FAILED count query fell into the same branch as "last namespace"
# ($active_ns_count starts at 0, so the died eval lands in the <= 1 arm even
# without the || $@), and one flaky API answer disconnected every NVMe disk
# of every VM on the node. The skip was also logged at level 2, which
# tn_debug's default of 0 discards.
#
# Defect C: _delete_dataset_with_retry treats _wait_for_job_completion's
# "Job timed out after N seconds" as a plain non-retryable failure, although
# the destroy job was accepted and usually finishes server-side moments
# later. The fix re-queries the dataset before deciding what to report, and
# when it must still fail, says "we stopped waiting", not "it did not work".
#
# These tests drive the real subs with a stubbed API layer and assert on the
# sequence of methods the code tried to call. As in 05-free-destroy-guard.t,
# the assertions that matter are the negative ones: the destructive call
# (pool.dataset.delete for A, nvme_disconnect for B) must NOT appear.
#
# Run this file against the unfixed and the fixed plugin. Every assertion
# tagged EXPECT-FAIL(unfixed) must fail against the current code - if it
# passes there, the test is not testing the defect. Every untagged assertion
# must pass in both worlds; those pin the behaviour the fix must not change,
# idempotency under PVE's retries above all.
#
# Intended location: t/nvme/06-fail-open-guards.t
# Run with:  prove -v t/nvme/06-fail-open-guards.t

use strict;
use warnings;
use Test::More;
use FindBin;

my $PLUGIN = "$FindBin::Bin/../../TrueNASPlugin.pm";
unless (eval { require $PLUGIN; 1 }) {
    plan skip_all => "cannot load TrueNASPlugin.pm (needs PVE perl modules): $@";
}

my $PKG = 'PVE::Storage::Custom::TrueNASPlugin';
my $free_nvme = $PKG->can('_free_image_nvme');
my $del_retry = $PKG->can('_delete_dataset_with_retry');
plan skip_all => "_free_image_nvme not found"          unless $free_nvme;
plan skip_all => "_delete_dataset_with_retry not found" unless $del_retry;
plan skip_all => "free_image not found"                 unless $PKG->can('free_image');

my @calls;        # every method the code tried to call, in order
my @logs;         # every _log as [level, priority, message]
my %fail;         # method => error string to throw
my %ret;          # method => canned return (or coderef), overrides defaults
my $wait_result;  # what the stubbed job wait reports; default is a timeout

{
    no strict 'refs';
    no warnings 'redefine';
    *{"${PKG}::_log"} = sub { push @logs, [@_[1..3]]; 1 };
    # Keep the destructive steps off any real machine while still recording
    # the intent. Deferred work would otherwise try to touch nvme-cli.
    *{"${PKG}::_defer_after_lock"}  = sub { 1 };
    *{"${PKG}::_nvme_disconnect"}   = sub { push @calls, 'nvme_disconnect'; 1 };
    *{"${PKG}::_nvme_connect"}      = sub { push @calls, 'nvme_connect'; 1 };
    *{"${PKG}::run_command"}        = sub { 1 };

    # The job wait is the API layer's time domain: driving the real one
    # through a RUNNING job would make this file sleep for the full
    # DATASET_DELETE_TIMEOUT_S. Defect C lives in what the caller does
    # with the wait's verdict, so the verdict itself is canned.
    *{"${PKG}::_wait_for_job_completion"} = sub {
        push @calls, 'wait_for_job';
        return $wait_result // { success => 0, error => "Job timed out after 30 seconds" };
    };

    *{"${PKG}::_api_call"} = sub {
        my ($scfg, $method, $params) = @_;
        push @calls, $method;
        die $fail{$method} if exists $fail{$method};
        if (exists $ret{$method}) {
            my $r = $ret{$method};
            return ref($r) eq 'CODE' ? $r->($params) : $r;
        }
        # One namespace, pointing at our zvol.
        return [ { id => 42, device_path => 'zvol/tank/pve/vm-101-disk-0' } ]
            if $method eq 'nvmet.namespace.query';
        return [] if $method eq 'nvmet.subsys.query';
        # The clone lookup: default is a well-formed empty answer, i.e. a
        # base image with no clones. Cases override it deliberately.
        return [] if $method eq 'pool.dataset.query';
        return { id => 'tank/pve/some-dataset', type => 'VOLUME' }
            if $method eq 'pool.dataset.get_instance';
        return { id => 1 };
    };
    *{"${PKG}::_api_call_mutate"} = sub { goto &{"${PKG}::_api_call"} };
}

my %SCFG = (
    tn_dataset => 'tank/pve', tn_api_host => '198.51.100.7',
    tn_transport_mode => 'nvme-tcp',
    tn_subsystem_nqn => 'nqn.2011-06.com.example:test',
);

sub reset_world {
    @calls = (); @logs = (); %fail = (); %ret = (); $wait_result = undef;
}

sub run_free_image {
    my (%opt) = @_;
    reset_world();
    %fail = %{ $opt{fail} // {} };
    %ret  = %{ $opt{ret}  // {} };
    my $scfg = { %SCFG, %{ $opt{scfg} // {} } };
    my $ok = eval {
        $PKG->free_image('store', $scfg, $opt{volname}, $opt{isBase}, 'raw');
        1;
    };
    return ($ok, $ok ? '' : $@, [@calls], [@logs]);
}

sub run_free_nvme {
    my (%opt) = @_;
    reset_world();
    %fail = %{ $opt{fail} // {} };
    %ret  = %{ $opt{ret}  // {} };
    my $scfg = { %SCFG, %{ $opt{scfg} // {} } };
    # ($class, $storeid, $scfg, $volname, $zname, $full_ds, $metadata)
    my $ok = eval {
        $free_nvme->($PKG, 'store', $scfg, 'vol-vm-101-disk-0-lun1',
                     'vm-101-disk-0', 'tank/pve/vm-101-disk-0', undef);
        1;
    };
    return ($ok, $ok ? '' : $@, [@calls], [@logs]);
}

sub run_delete {
    my (%opt) = @_;
    reset_world();
    %fail = %{ $opt{fail} // {} };
    %ret  = %{ $opt{ret}  // {} };
    $wait_result = $opt{wait} if exists $opt{wait};
    my $scfg = { %SCFG };
    my $ok = eval { $del_retry->($scfg, 'tank/pve/vm-101-disk-9'); 1 };
    return ($ok, $ok ? '' : $@, [@calls], [@logs]);
}

sub destroyed    { scalar grep { $_ eq 'pool.dataset.delete' }       @{$_[0]} }
sub disconnects  { scalar grep { $_ eq 'nvme_disconnect' }           @{$_[0]} }
sub verified     { scalar grep { $_ eq 'pool.dataset.get_instance' } @{$_[0]} }
sub log0_matching {
    my ($logs, $re) = @_;
    return scalar grep { $_->[0] == 0 && $_->[2] =~ $re } @$logs;
}

my $BASE_VOL = 'vol-base-9001-disk-0-nsfeedface1234';   # zname base-9001-disk-0

# ---------------------------------------------------------------------------
# Defect A: the clone lookup dies - the guard must fail closed
# ---------------------------------------------------------------------------

{
    my ($ok, $err, $calls) = run_free_image(
        volname => $BASE_VOL, isBase => 1,
        fail => { 'pool.dataset.query' => "WS read timeout after 30s\n" },
    );
    # EXPECT-FAIL(unfixed): the blip reads as "no clones" and the free succeeds
    ok(!$ok, 'a failed clone lookup makes the base free fail');
    # EXPECT-FAIL(unfixed): the template is destroyed
    is(destroyed($calls), 0, '...and the base dataset is NOT destroyed');
    # EXPECT-FAIL(unfixed): there is no error at all on the unfixed code
    like($err, qr/Cannot delete base image/, '...with an error that names the base');
}

# ---------------------------------------------------------------------------
# Defect A: the clone lookup answers with a non-array - same rule
# ---------------------------------------------------------------------------

# A hashref is what a stray get_instance-shaped reply, or a middleware that
# stopped accepting the origin.parsed filter, actually looks like.
{
    my ($ok, $err, $calls) = run_free_image(
        volname => $BASE_VOL, isBase => 1,
        ret => { 'pool.dataset.query' => { id => 1 } },
    );
    # EXPECT-FAIL(unfixed)
    ok(!$ok, 'a non-array clone lookup makes the base free fail');
    # EXPECT-FAIL(unfixed)
    is(destroyed($calls), 0, '...and the base dataset is NOT destroyed');
    # EXPECT-FAIL(unfixed)
    like($err, qr/instead of a dataset list/, '...and the error says what came back');
}

# ---------------------------------------------------------------------------
# Defect A: rows without ids are still rows, i.e. still clones
# ---------------------------------------------------------------------------

{
    my ($ok, $err, $calls) = run_free_image(
        volname => $BASE_VOL, isBase => 1,
        ret => { 'pool.dataset.query' => [ { foo => 1 } ] },
    );
    # EXPECT-FAIL(unfixed): the id-less row is grepped away and the guard passes
    ok(!$ok, 'a clone row with no id field still blocks the free');
    # EXPECT-FAIL(unfixed)
    is(destroyed($calls), 0, '...and the base dataset is NOT destroyed');
    # EXPECT-FAIL(unfixed)
    like($err, qr/linked clone/, '...reported as a live clone');
}

# ---------------------------------------------------------------------------
# Defect A control: real clones block, in both worlds
# ---------------------------------------------------------------------------

{
    my ($ok, $err, $calls) = run_free_image(
        volname => $BASE_VOL, isBase => 1,
        ret => { 'pool.dataset.query' =>
            [ { id => 'tank/pve/vm-201-disk-0' }, { id => 'tank/pve/vm-202-disk-0' } ] },
    );
    ok(!$ok, 'a base with live clones cannot be freed');
    is(destroyed($calls), 0, '...and the base dataset is NOT destroyed');
    like($err, qr/2 linked clone/, '...with the clone count');
    like($err, qr/vm-201-disk-0/, '...and the clones named');
}

# ---------------------------------------------------------------------------
# Defect A control: no clones means the free proceeds - the guard must not
# break idempotency. An already-deleted base produces exactly this: a
# successful query with an empty answer.
# ---------------------------------------------------------------------------

{
    # isBase deliberately undef here: the base-<vmid> zname convention alone
    # must route through the guard, and then through it.
    my ($ok, $err, $calls) = run_free_image(volname => $BASE_VOL, isBase => undef);
    ok($ok, 'a base with no clones frees cleanly') or diag("died with: $err");
    ok(destroyed($calls), '...and does destroy the dataset');
}

# ---------------------------------------------------------------------------
# Defect B: unknown namespace count - the subsystem must be left alone
# ---------------------------------------------------------------------------

# The namespace delete fails "in use" (so the force path engages), then the
# subsystem query dies. The unfixed code treats that as "must be the last
# namespace" and disconnects the whole subsystem by NQN - every VM disk on
# the node.
{
    my ($ok, $err, $calls, $logs) = run_free_nvme(
        scfg => { tn_force_delete_on_inuse => 1 },
        fail => {
            'nvmet.namespace.delete' => "Namespace is in use\n",
            'nvmet.subsys.query'     => "WS read timeout after 30s\n",
        },
    );
    # EXPECT-FAIL(unfixed): this is the defect - the disconnect fires
    is(disconnects($calls), 0, 'an unknown namespace count must NOT disconnect the subsystem');
    # EXPECT-FAIL(unfixed): and the zvol is then force-destroyed while exported
    is(destroyed($calls), 0, '...and the still-exported dataset is NOT destroyed');
    # EXPECT-FAIL(unfixed): the unfixed code reports success after the teardown
    ok(!$ok, '...and the free fails instead of pretending to succeed');
    # EXPECT-FAIL(unfixed)
    like($err, qr/namespace count could not be determined/,
        '...with an error that says why');
    # EXPECT-FAIL(unfixed): the unfixed skip/act decision logs at level 2 only
    ok(log0_matching($logs, qr/skipping subsystem disconnect/),
        '...and the skip is visible at log level 0');
}

# ---------------------------------------------------------------------------
# Defect B control: a known count above one skips the disconnect, both worlds
# ---------------------------------------------------------------------------

{
    my ($ok, $err, $calls) = run_free_nvme(
        scfg => { tn_force_delete_on_inuse => 1 },
        fail => { 'nvmet.namespace.delete' => "Namespace is in use\n" },
        ret  => {
            'nvmet.subsys.query'    => [ { id => 7 } ],
            'nvmet.namespace.query' => [
                { id => 42, device_path => 'zvol/tank/pve/vm-101-disk-0' },
                { id => 43, device_path => 'zvol/tank/pve/vm-102-disk-0' },
                { id => 44, device_path => 'zvol/tank/pve/vm-103-disk-0' },
            ],
        },
    );
    is(disconnects($calls), 0, 'three known namespaces: no subsystem disconnect');
    # This pins today's behaviour: the > 1 branch still falls through to the
    # force destroy with the namespace attached. That residual is documented
    # in failopen.patch.md as out of scope; when it is fixed, flip these two.
    ok($ok, '...the free itself currently still succeeds') or diag("died with: $err");
    ok(destroyed($calls), '...and currently still destroys the dataset');
}

# ---------------------------------------------------------------------------
# Defect B control: the known last namespace still disconnects, both worlds
# ---------------------------------------------------------------------------

# Subsystem lookup answers cleanly with nothing: count is a known zero, the
# operator opted into force_delete_on_inuse, and the disconnect-and-retry
# machinery must keep working or the option is dead.
{
    my ($ok, $err, $calls) = run_free_nvme(
        scfg => { tn_force_delete_on_inuse => 1 },
        fail => { 'nvmet.namespace.delete' => "Namespace is in use\n" },
    );
    is(disconnects($calls), 1, 'a known last namespace still disconnects to retry');
    ok($ok, '...and the free completes') or diag("died with: $err");
}

# ---------------------------------------------------------------------------
# Defect C: job wait timed out, dataset actually gone - that is a success
# ---------------------------------------------------------------------------

# pool.dataset.delete returns a job id; the (stubbed) wait times out; the
# re-query says the dataset does not exist. The destroy worked, we just
# stopped watching it.
{
    my ($ok, $err, $calls, $logs) = run_delete(
        ret  => { 'pool.dataset.delete' => 7331 },
        fail => { 'pool.dataset.get_instance' =>
                  "[ENOENT] Path tank/pve/vm-101-disk-9 does not exist\n" },
    );
    # EXPECT-FAIL(unfixed): the unfixed code dies on the timeout string
    ok($ok, 'a timed-out delete whose dataset is gone is a success')
        or diag("died with: $err");
    # EXPECT-FAIL(unfixed): the unfixed code never re-queries
    ok(verified($calls), '...because the dataset was re-queried');
    # EXPECT-FAIL(unfixed)
    ok(log0_matching($logs, qr/treating as success/),
        '...and the late completion is visible at level 0');
    is(destroyed($calls), 1, '...with no blind re-issue of the delete');
}

# ---------------------------------------------------------------------------
# Defect C: job wait timed out, dataset still present - fail, but say what
# actually happened
# ---------------------------------------------------------------------------

{
    my ($ok, $err, $calls) = run_delete(
        ret => {
            'pool.dataset.delete'       => 7331,
            'pool.dataset.get_instance' => { id => 'tank/pve/vm-101-disk-9' },
        },
    );
    ok(!$ok, 'a timed-out delete whose dataset remains is still a failure');
    like($err, qr/timed out/i, '...that mentions the timeout');
    # EXPECT-FAIL(unfixed): the unfixed code never re-queries
    ok(verified($calls), '...after re-querying the dataset');
    # EXPECT-FAIL(unfixed): the unfixed error is the bare "job failed: timed out"
    like($err, qr/stopped waiting/, '...and says we stopped waiting');
    # EXPECT-FAIL(unfixed)
    like($err, qr/may yet complete|may still be running/,
        '...not that the delete is known to have failed');
    is(destroyed($calls), 1, '...with no blind re-issue of the delete');
}

# ---------------------------------------------------------------------------
# Defect C: job wait timed out and the re-query fails too - outcome unknown
# ---------------------------------------------------------------------------

{
    my ($ok, $err, $calls) = run_delete(
        ret  => { 'pool.dataset.delete' => 7331 },
        fail => { 'pool.dataset.get_instance' => "Connection refused\n" },
    );
    ok(!$ok, 'timeout plus unverifiable outcome is a failure');
    # EXPECT-FAIL(unfixed): the unfixed code never re-queries
    ok(verified($calls), '...after attempting the re-query');
    # EXPECT-FAIL(unfixed)
    like($err, qr/Outcome unknown/, '...reported as unknown, not as a failed delete');
}

# ---------------------------------------------------------------------------
# Defect C: the sibling abandonment - "API unavailable" from the job poller
# gets the same verification, not a hard failure
# ---------------------------------------------------------------------------

{
    my ($ok, $err, $calls) = run_delete(
        wait => { success => 0, error => "API unavailable: WS handshake failed" },
        ret  => { 'pool.dataset.delete' => 7331 },
        fail => { 'pool.dataset.get_instance' =>
                  "[ENOENT] Path tank/pve/vm-101-disk-9 does not exist\n" },
    );
    # EXPECT-FAIL(unfixed)
    ok($ok, 'a lost job poll with the dataset gone is a success')
        or diag("died with: $err");
    is(destroyed($calls), 1, '...with no blind re-issue of the delete');
}

done_testing();
