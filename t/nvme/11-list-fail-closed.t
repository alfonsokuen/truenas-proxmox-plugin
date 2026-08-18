#!/usr/bin/perl
# list_images must not answer "this storage is empty" when what actually
# happened is "I could not ask".
#
# Found by tools/i32-apiloss.sh. With the array's API blacked out at the
# packet level, `pvesm list <storage>` reported 0 volumes and exited 0 on a
# storage that held 2. Reproduced three times, in 155s, 90s and 35s: it is
# not a timeout decaying into a partial answer, it is a confident wrong
# answer that is sometimes fast.
#
# Why this one matters more than a hang. Reconciliation -- the job that
# compares PVE's view against the array to decide which datasets are
# orphans -- is built on exactly this call. Fed an empty list it concludes
# that every dataset on the array is garbage. It is the same shape as the
# namespace syncer that unexported everything because a failed query was
# indistinguishable from "there is nothing here", and the same shape as the
# three fail-open guards in 07-fail-open-guards.t. An empty list is a
# claim. The code may only make it when it actually knows.
#
# _list_images_nvme had three doors onto that claim:
#   A. nvmet.subsys.query dies                  -> logged, returned []
#   B. the configured subsystem is not found    -> logged, returned []
#   C. nvmet.namespace.query dies               -> eval {...} // [], silent
#
# D is the deliberate exception: the pool.dataset.query batch fetch is a
# performance optimisation with a documented per-volume fallback, so its
# failure must NOT be fatal. That one is pinned here so a fix for A-C does
# not turn a working fallback into an outage.
#
# Every assertion tagged EXPECT-FAIL(unfixed) must FAIL against the current
# code. If it passes there, this file is not testing the defect. Untagged
# assertions must pass in both worlds.
#
# Run with:  prove -v t/nvme/11-list-fail-closed.t

use strict;
use warnings;
use Test::More;
use FindBin;

my $PLUGIN = "$FindBin::Bin/../../TrueNASPlugin.pm";
unless (eval { require $PLUGIN; 1 }) {
    plan skip_all => "cannot load TrueNASPlugin.pm (needs PVE perl modules): $@";
}

my $PKG = 'PVE::Storage::Custom::TrueNASPlugin';
my $list_nvme = $PKG->can('_list_images_nvme');
plan skip_all => "_list_images_nvme not found" unless $list_nvme;

my @calls;
my @logs;
my %fail;
my %ret;

{
    no strict 'refs';
    no warnings 'redefine';
    *{"${PKG}::_log"} = sub { push @logs, [@_[1..3]]; 1 };
    *{"${PKG}::_api_call"} = sub {
        my ($scfg, $method, $params) = @_;
        push @calls, $method;
        die $fail{$method} if exists $fail{$method};
        if (exists $ret{$method}) {
            my $r = $ret{$method};
            return ref($r) eq 'CODE' ? $r->($params) : $r;
        }
        return [ { id => 7, subnqn => 'nqn.2011-06.com.example:test' } ]
            if $method eq 'nvmet.subsys.query';
        # Two namespaces on our subsystem -- the situation the field bug hit.
        # device_uuid is required: _list_images_nvme skips any namespace
        # without one, because the volname is vol-<zname>-ns<device_uuid>.
        return [
            { id => 1, subsys => 7, device_path => 'zvol/tank/pve/vm-101-disk-0',
              device_uuid => '11111111-1111-4111-8111-111111111111' },
            { id => 2, subsys => 7, device_path => 'zvol/tank/pve/vm-102-disk-0',
              device_uuid => '22222222-2222-4222-8222-222222222222' },
        ] if $method eq 'nvmet.namespace.query';
        return [
            { id => 'tank/pve/vm-101-disk-0', type => 'VOLUME',
              volsize => { parsed => 1073741824 } },
            { id => 'tank/pve/vm-102-disk-0', type => 'VOLUME',
              volsize => { parsed => 2147483648 } },
        ] if $method eq 'pool.dataset.query';
        return { id => 1 };
    };
    *{"${PKG}::_api_call_mutate"} = sub { goto &{"${PKG}::_api_call"} };
}

my %SCFG = (
    tn_dataset        => 'tank/pve',
    tn_api_host       => '198.51.100.7',
    tn_transport_mode => 'nvme-tcp',
    tn_subsystem_nqn  => 'nqn.2011-06.com.example:test',
);

# Returns (ok, result, error). ok is false when the sub died, which is the
# behaviour every A/B/C case below demands.
sub run_list {
    my (%opt) = @_;
    @calls = (); @logs = ();
    %fail = %{ $opt{fail} // {} };
    %ret  = %{ $opt{ret}  // {} };
    my $scfg = { %SCFG, %{ $opt{scfg} // {} } };
    my $res;
    my $ok = eval { $res = $list_nvme->($PKG, 'store1', $scfg, undef, undef, undef); 1 };
    return ($ok, $res, $@);
}

sub nvols { my $r = shift; return (ref($r) eq 'ARRAY') ? scalar(@$r) : -1 }

# ---------------------------------------------------------------- baseline --
# Must pass in both worlds. If this breaks, the fix broke listing itself.

{
    my ($ok, $res, $err) = run_list();
    ok($ok, 'the happy path still lists') or diag("died with: $err");
    is(nvols($res), 2, '...and reports both volumes');
}

# ------------------------------------------------- A. subsystem query dies --

{
    my ($ok, $res, $err) = run_list(
        fail => { 'nvmet.subsys.query' => "WS read timeout\n" },
    );
    # EXPECT-FAIL(unfixed): today this logs and returns [].
    ok(!$ok, 'A: a failed subsystem query must not produce a volume list');
    isnt(nvols($res), 0, 'A: ...and must not hand back an empty list')
        if $ok;
    like($err // '', qr/could not|unable|failed/i,
         'A: ...and the error says the query failed, not that the storage is empty');
}

# ---------------------------------------------- B. subsystem does not exist --

{
    my ($ok, $res, $err) = run_list(
        ret => { 'nvmet.subsys.query' => [] },
    );
    # EXPECT-FAIL(unfixed): today this logs and returns [].
    ok(!$ok, 'B: a configured subsystem that is absent is an error, not an empty storage');
    like($err // '', qr/\Qnqn.2011-06.com.example:test\E/,
         'B: ...and the error names the NQN that was not found');
}

# ------------------------------------------------- C. namespace query dies --

{
    my ($ok, $res, $err) = run_list(
        fail => { 'nvmet.namespace.query' => "connection reset by peer\n" },
    );
    # EXPECT-FAIL(unfixed): today `eval {...} // []` swallows this silently.
    ok(!$ok, 'C: a failed namespace query must not read as "no namespaces"');
    like($err // '', qr/could not|unable|failed/i,
         'C: ...and it says so rather than staying quiet');
    # The silence is half the defect: nothing was logged at a visible level.
    ok(scalar(@logs) > 0, 'C: ...and it does not fail silently');
}

# ------------------------- C2. namespace query answers with the wrong shape --

{
    my ($ok, $res, $err) = run_list(
        ret => { 'nvmet.namespace.query' => { error => 'nope' } },
    );
    ok(!$ok, 'C2: a non-array answer is not an empty list either');
}

# ------------------ D. the batch dataset fetch may fail without being fatal --
# Pinned deliberately: it has a documented per-volume fallback. A fix for
# A-C that also made this fatal would turn a working degraded mode into an
# outage, so this assertion must pass in BOTH worlds.

{
    my ($ok, $res, $err) = run_list(
        fail => { 'pool.dataset.query' => "batch fetch blew up\n" },
    );
    ok($ok, 'D: a failed batch dataset fetch is NOT fatal -- it has a fallback')
        or diag("died with: $err");
    is(nvols($res), 2, 'D: ...and both volumes are still listed');
}

# -------------------------------------------------- E. genuinely empty is 0 --
# The whole point is telling "empty" from "could not ask". Empty must still
# be reportable, or the fix has just moved the lie.

{
    my ($ok, $res, $err) = run_list(
        ret => { 'nvmet.namespace.query' => [] },
    );
    ok($ok, 'E: a subsystem with no namespaces still lists cleanly')
        or diag("died with: $err");
    is(nvols($res), 0, 'E: ...as zero volumes, which is a real answer');
}

done_testing();
