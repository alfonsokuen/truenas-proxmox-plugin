#!/usr/bin/perl
# create_base must leave the volume either fully converted or fully restored.
#
# Turning a disk into a template is four mutations against two TrueNAS
# subsystems that share no transaction: disable the namespace, rename the
# dataset, re-point the share at the new zvol, re-enable it, then snapshot.
# Any one of them can fail, and the only thing standing between a failure and
# an offline disk is the rollback.
#
# Two ways it did not stand.
#
# The first is a rollback that undoes less than it did. Step 3 issued the
# re-point and the re-enable inside one eval, so a failure of the second was
# treated as a failure of the first: the handler renamed the dataset back and
# never restored device_path. TrueNAS validates device_path on every
# namespace.update - including an enable-only one, where the value it checks
# is the one already stored - so the re-enable that followed was judged
# against a path that had just stopped existing, and failed too. What was left
# was a dataset at its original name, a namespace disabled and pointing at a
# zvol that is not there, and a PVE config that never changed. Nothing in the
# plugin looks at that state again. The step 4 rollback in the same function
# did the full disable/rename/re-point/enable dance and was correct; the two
# disagreed and only one of them was right.
#
# The second is a retry that cannot be retried. _api_call_mutate is _api_call,
# so it inherits _retry_with_backoff and its three attempts, and it retries
# anything _is_connection_error matches - a broker read timeout does.
# pool.dataset.rename is not idempotent. When the rename commits and the
# response is lost, the retry asks to rename a dataset that is no longer
# there, gets "does not exist", and _is_retryable_error classifies that as
# fatal. The failure handler then tries to re-enable a namespace whose stored
# device_path is the old name the rename just removed, so that fails as well.
# Same offline disk, reached from the other direction, and the operator is
# handed "dataset does not exist" - which is true of the retry and false of
# anything they can act on.
#
# These tests drive the real create_base against a simulated TrueNAS that
# enforces the two rules the defects turn on: the device_path validator, and a
# rename that only works once. Unlike the other tests in this directory the
# stub goes in at _ws_rpc rather than at _api_call, because _api_call is where
# _retry_with_backoff runs and the second defect IS the retry loop. Stubbing
# above it would test a version of the plugin that has no retries, and would
# report every lost-response case as a clean pass.
#
# Assertions tagged [EXPECT-FAIL-BEFORE-FIX] are the ones that must fail
# against the current unfixed code. If any of them passes before the patch is
# applied, the harness is not reproducing the defect and none of it should be
# believed. Everything else is a control: it passes before and after, and it
# is here so that a fix which trades one broken path for another shows up.
#
# Run with:  prove -v t/nvme/06-create-base-rollback.t

use strict;
use warnings;
use Test::More;
use FindBin;

# Resolve the plugin whether this file sits in t/nvme/ or is being run from a
# proposals directory beside a checkout.
my ($PLUGIN) = grep { defined($_) && -f $_ } (
    $ENV{TRUENAS_PLUGIN_PM},
    "$FindBin::Bin/../../TrueNASPlugin.pm",
    "$FindBin::Bin/../TrueNASPlugin.pm",
    "$FindBin::Bin/TrueNASPlugin.pm",
    "$FindBin::Bin/../tnplugin/TrueNASPlugin.pm",
);
plan skip_all => "cannot locate TrueNASPlugin.pm" unless $PLUGIN;
unless (eval { require $PLUGIN; 1 }) {
    plan skip_all => "cannot load TrueNASPlugin.pm (needs PVE perl modules): $@";
}

my $PKG = 'PVE::Storage::Custom::TrueNASPlugin';
my $create_base = $PKG->can('create_base');
plan skip_all => "create_base not found" unless $create_base;

use constant XFB => ' [EXPECT-FAIL-BEFORE-FIX]';

my $OLD_DS   = 'tank/pve/vm-101-disk-0';
my $NEW_DS   = 'tank/pve/base-101-disk-0';
my $OLD_PATH = "zvol/$OLD_DS";
my $NEW_PATH = "zvol/$NEW_DS";
my $NS_ID    = 42;
my $EXT_ID   = 7;
my $NS_UUID  = '3f2a1b00-0000-0000-0000-000000000001';

my %tn;         # the simulated TrueNAS
my %fail;       # step key => { err => ..., after => 0|1, n => times }
my @calls;      # every step key the code reached, in order
my @errlog;     # level 0 log lines - what an operator would actually see

# ---------------------------------------------------------------------------
# The simulated TrueNAS
# ---------------------------------------------------------------------------

sub reset_tn {
    my ($mode) = @_;
    %tn = (
        mode        => $mode,
        dataset     => $OLD_DS,
        device_path => $OLD_PATH,   # namespace device_path, or extent disk
        enabled     => 1,           # nvme only; nothing toggles it under iscsi
        snapshot    => undef,
    );
    # _tn_extents caches, and a cached extent list would outlive the run that
    # built it and answer the next one with the previous run's disk path.
    $PKG->can('_clear_cache')->();
}

sub short      { my $d = shift // ''; return $d eq $OLD_DS   ? 'old' : $d eq $NEW_DS   ? 'new' : $d }
sub short_path { my $p = shift // ''; return $p eq $OLD_PATH ? 'old' : $p eq $NEW_PATH ? 'new' : $p }

# A stable name for each mutation, so a test can fail exactly one of them and
# leave its counterpart in the rollback alone.
sub step_key {
    my ($method, $params) = @_;

    if ($method eq 'pool.dataset.rename') {
        my ($from, $opt) = @$params;
        return 'rename:' . short($from) . '->' . short($opt->{new_name});
    }
    if ($method eq 'nvmet.namespace.update') {
        my (undef, $p) = @$params;
        return 'ns:path=' . short_path($p->{device_path}) if exists $p->{device_path};
        return ($p->{enabled} ? 'ns:enable' : 'ns:disable') if exists $p->{enabled};
        return 'ns:update';
    }
    if ($method eq 'iscsi.extent.update') {
        my (undef, $p) = @$params;
        return 'extent:disk=' . short_path($p->{disk}) if exists $p->{disk};
        return 'extent:update';
    }
    return 'snap:create' if $method eq 'pool.snapshot.create';
    return "q:$method";
}

# Minimal TrueNAS query filter support: [["field","=",value]] and "^" prefix.
sub filter_rows {
    my ($rows, $params) = @_;
    my $filters = $params->[0];
    return [ @$rows ] if !$filters || !ref($filters) || !@$filters;
    my @out = @$rows;
    for my $f (@$filters) {
        my ($field, $op, $want) = @$f;
        if ($op eq '=') {
            @out = grep { defined($_->{$field}) && $_->{$field} eq $want } @out;
        } elsif ($op eq '^') {
            @out = grep { defined($_->{$field}) && index($_->{$field}, $want) == 0 } @out;
        } else {
            die "test harness: unstubbed filter op '$op'\n";
        }
    }
    return [ @out ];
}

sub ns_row {
    return {
        id          => $NS_ID,
        device_path => $tn{device_path},
        enabled     => ($tn{enabled} ? JSON::PP::true() : JSON::PP::false()),
        device_uuid => $NS_UUID,
        subsys      => { id => 1 },
    };
}

sub ext_row {
    return { id => $EXT_ID, disk => $tn{device_path}, naa => '0x6589cfc000000001' };
}

sub tn_apply {
    my ($method, $params) = @_;

    if ($method eq 'pool.dataset.rename') {
        my ($from, $opt) = @$params;
        # Not idempotent, and this is the whole of the second defect: replaying
        # a rename that already committed is indistinguishable, from the
        # client's side, from renaming something that was never there.
        die "[ENOENT] Dataset '$from' does not exist\n" if $tn{dataset} ne $from;
        my $to = $opt->{new_name};
        if (defined $tn{snapshot}) {
            my ($sds, $sname) = split /\@/, $tn{snapshot}, 2;
            $tn{snapshot} = "$to\@$sname" if $sds eq $from;   # snapshots follow the dataset
        }
        $tn{dataset} = $to;
        return {};
    }

    if ($method eq 'nvmet.namespace.update') {
        my ($id, $p) = @$params;
        die "[ENOENT] nvmet.namespace $id does not exist\n" if $id != $NS_ID;
        # The validator both defects run into. An update that supplies a
        # device_path is judged on the value being supplied; one that does not
        # - enable-only, disable-only - is judged on the value already stored.
        # That is the rule create_base's own step 1 comment describes, and the
        # only rule under which its step 4 rollback makes sense.
        my $checked = exists $p->{device_path} ? $p->{device_path} : $tn{device_path};
        die "[EINVAL] nvmet_namespace_update.device_path: ZVOL device_path must be "
          . "a block device: $checked\n"
            if $checked ne "zvol/$tn{dataset}";
        $tn{device_path} = $p->{device_path}       if exists $p->{device_path};
        $tn{enabled}     = ($p->{enabled} ? 1 : 0) if exists $p->{enabled};
        return ns_row();
    }

    if ($method eq 'iscsi.extent.update') {
        my ($id, $p) = @$params;
        die "[ENOENT] iscsi.extent $id does not exist\n" if $id != $EXT_ID;
        $tn{device_path} = $p->{disk} if exists $p->{disk};
        return ext_row();
    }

    if ($method eq 'pool.snapshot.create') {
        my ($p) = @$params;
        my $id = "$p->{dataset}\@$p->{name}";
        die "[ENOENT] Dataset '$p->{dataset}' does not exist\n" if $tn{dataset} ne $p->{dataset};
        die "[EEXIST] Snapshot '$id' already exists\n"
            if defined($tn{snapshot}) && $tn{snapshot} eq $id;
        $tn{snapshot} = $id;
        return {};
    }

    return filter_rows([ { id => $tn{dataset} } ], $params) if $method eq 'pool.dataset.query';
    return filter_rows([ ns_row() ],  $params) if $method eq 'nvmet.namespace.query';
    return filter_rows([ ext_row() ], $params) if $method eq 'iscsi.extent.query';
    if ($method eq 'pool.snapshot.query') {
        return filter_rows(defined($tn{snapshot}) ? [ { id => $tn{snapshot} } ] : [], $params);
    }
    if ($method eq 'pool.dataset.get_instance') {
        my ($full) = @$params;
        die "[ENOENT] Dataset '$full' does not exist\n" if $tn{dataset} ne $full;
        return { id => $full };
    }

    die "test harness: unstubbed method '$method'\n";
}

sub tn_dispatch {
    my ($method, $params) = @_;
    my $key = step_key($method, $params);
    push @calls, $key;

    if (my $f = $fail{$key}) {
        if (($f->{n} // 1) > 0) {
            $f->{n} = ($f->{n} // 1) - 1;
            # after => 1 is the lost response: TrueNAS did the work and the
            # answer never made it back. Measured against the broker as a read
            # timeout at 30s on a mutation that had already committed.
            eval { tn_apply($method, $params) } if $f->{after};
            die $f->{err};
        }
    }
    return tn_apply($method, $params);
}

{
    no strict 'refs';
    no warnings 'redefine';
    # Record what an operator would see. Level 0 survives tn_debug's default
    # of 0; anything above it is discarded, so anything above it is not a
    # report.
    *{"${PKG}::_log"} = sub {
        my ($scfg, $level, $priority, $message) = @_;
        push @errlog, $message if defined($level) && $level == 0;
        return 1;
    };
    # Stub below _api_call, not at it: _api_call is where _retry_with_backoff
    # runs, and the retry loop is the subject of half of these tests.
    *{"${PKG}::_ws_get_persistent"} = sub { return { next_id => 1 } };
    *{"${PKG}::_ws_rpc"} = sub {
        my ($conn, $obj) = @_;
        return tn_dispatch($obj->{method}, $obj->{params} // []);
    };
    *{"${PKG}::_defer_after_lock"} = sub { 1 };
    *{"${PKG}::run_command"}       = sub { 1 };
}

sub scfg_for {
    my ($mode) = @_;
    return {
        tn_dataset        => 'tank/pve',
        tn_api_host       => '198.51.100.7',
        tn_api_key        => 'test-key',
        tn_transport_mode => $mode,
        tn_subsystem_nqn  => 'nqn.2011-06.com.example:test',
        # tn_api_retry_max stays at its default of 3, because the retry count
        # is part of what is under test. Only the delay is zeroed, so the suite
        # does not spend seven seconds per exhausted call asleep.
        tn_api_retry_delay => 0,
    };
}

sub run_create_base {
    my (%args) = @_;
    my $mode = $args{mode} // 'nvme-tcp';
    my $spec = $args{fail} // {};

    %fail = ();
    $fail{$_} = { %{ $spec->{$_} } } for keys %$spec;   # per-run copy: n is decremented
    reset_tn($mode) unless $args{no_reset};
    @calls  = ();
    @errlog = ();

    my $volname = $mode eq 'nvme-tcp'
        ? "vol-vm-101-disk-0-ns$NS_UUID"
        : 'vol-vm-101-disk-0-lun3';

    my $out = eval { $create_base->($PKG, 'store', scfg_for($mode), $volname) };
    my $err = $@;
    return { ok => ($err ? 0 : 1), err => ($err // ''), out => $out,
             calls => [ @calls ], errlog => [ @errlog ] };
}

# ---------------------------------------------------------------------------
# What counts as a resolved outcome
# ---------------------------------------------------------------------------

# Fully converted: dataset renamed, share following it, export live, anchor cut.
sub state_is_forward {
    return $tn{dataset} eq $NEW_DS
        && $tn{device_path} eq $NEW_PATH
        && $tn{enabled}
        && defined($tn{snapshot}) && $tn{snapshot} eq "$NEW_DS\@__base__";
}

# Fully restored: exactly as it was, which includes not leaving a __base__
# behind. A stray anchor is not cosmetic - pool.snapshot.create is name-unique,
# so it makes every later attempt at this template fail the same way forever.
sub state_is_back {
    return $tn{dataset} eq $OLD_DS
        && $tn{device_path} eq $OLD_PATH
        && $tn{enabled}
        && !defined($tn{snapshot});
}

# The shape both defects produce: an export switched off, or aimed at a zvol
# that is not there. No code path in the plugin revisits it.
sub state_is_stranded {
    return 1 if !$tn{enabled};
    return 1 if $tn{device_path} ne "zvol/$tn{dataset}";
    return 0;
}

sub state_dump {
    my ($r) = @_;
    return "state: dataset=" . short($tn{dataset})
         . " path=" . short_path($tn{device_path})
         . " enabled=" . ($tn{enabled} ? 1 : 0)
         . " snapshot=" . (defined $tn{snapshot} ? $tn{snapshot} : '-')
         . " stranded=" . (state_is_stranded() ? 'YES' : 'no')
         . "\ncalls: " . join(' -> ', @{ $r->{calls} })
         . "\nlevel-0 log: "
         . (@{ $r->{errlog} } ? join("\n             ", @{ $r->{errlog} }) : '(nothing)')
         . "\ndied with: " . ($r->{err} || '(did not die)');
}

# The whole contract in one assertion. Three outcomes are acceptable and no
# others: converted, restored, or quarantined - and quarantined only counts if
# it was said out loud at level 0 and carried the commands that undo it.
# Anything else is a disk that is offline and unattended.
sub assert_resolved {
    my ($what, $r, %opt) = @_;
    my $tag = $opt{xfb} ? XFB : '';

    if (state_is_forward()) {
        pass("$what: fully converted$tag");
        return 'forward';
    }
    if (state_is_back()) {
        pass("$what: fully restored$tag");
        return 'back';
    }
    # Deliberately not matching on any particular wording. What has to be true
    # is that a level 0 line exists and that it carries something the operator
    # can actually run - a midclt call - rather than an invitation to go and
    # look. A quarantine nobody can act on is the same as no quarantine.
    my $loud = grep { /midclt/ } @{ $r->{errlog} };
    ok($loud, "$what: neither converted nor restored, but quarantined loudly "
            . "with recovery commands$tag")
        or diag(state_dump($r));
    # 'quarantine' is only returned when the quarantine was actually reported.
    # Returning it either way would make every caller that accepts a
    # quarantine as an outcome accept silence as one too, and those callers
    # would then pass against the very code they exist to catch.
    return $loud ? 'quarantine' : 'stranded';
}

# ===========================================================================
# Controls - paths that already work. These must pass before and after.
# ===========================================================================

subtest 'the happy path still converts' => sub {
    my $r = run_create_base();
    ok($r->{ok}, 'create_base succeeds') or diag(state_dump($r));
    is($r->{out}, "vol-base-101-disk-0-ns$NS_UUID", 'returns the base volname');
    assert_resolved('happy path', $r);
    is_deeply($r->{calls}, [
        'q:nvmet.namespace.query',
        'ns:disable',
        'rename:old->new',
        'ns:path=new',
        'ns:enable',
        'snap:create',
    ], 'disable, rename, re-point, enable, snapshot - in that order')
        or diag(state_dump($r));
};

subtest 'step 1: the namespace will not disable' => sub {
    # Nothing has been mutated yet, so there is nothing to undo.
    my $r = run_create_base(fail => {
        'ns:disable' => { err => "[EPERM] not authorized\n", n => 9 } });
    ok(!$r->{ok}, 'create_base fails');
    assert_resolved('step 1 hard failure', $r);
};

subtest 'step 2: the rename is refused outright' => sub {
    # A refusal that never touched the pool. The dataset is still at its old
    # name, so re-enabling the namespace validates against a path that exists.
    my $r = run_create_base(fail => {
        'rename:old->new' => { err => "[EPERM] not authorized\n", n => 9 } });
    ok(!$r->{ok}, 'create_base fails');
    assert_resolved('step 2 hard failure', $r);
};

subtest 'step 3a: the re-point fails' => sub {
    # device_path was never changed, so renaming back is enough to make the
    # stored path valid again and the re-enable succeeds. This is the rollback
    # that was already correct, and it is here to show the two did not agree.
    my $r = run_create_base(fail => {
        'ns:path=new' => { err => "[EPERM] not authorized\n", n => 9 } });
    ok(!$r->{ok}, 'create_base fails');
    assert_resolved('step 3a hard failure', $r);
};

subtest 'step 4: the snapshot is denied' => sub {
    # The four-step rollback lower in the function, which was right.
    my $r = run_create_base(fail => {
        'snap:create' => { err => "[EPERM] not authorized\n", n => 9 } });
    ok(!$r->{ok}, 'create_base fails');
    like($r->{err}, qr/snapshot/i, 'and says the snapshot was the problem');
    assert_resolved('step 4 hard failure', $r);
};

subtest 'iscsi: the extent re-point fails' => sub {
    my $r = run_create_base(mode => 'iscsi', fail => {
        'extent:disk=new' => { err => "[EPERM] not authorized\n", n => 9 } });
    ok(!$r->{ok}, 'create_base fails');
    assert_resolved('iscsi step 3 hard failure', $r);
};

# ===========================================================================
# Defect 1 - the rollback that undoes less than it did
# ===========================================================================

subtest 'step 3b: the re-enable fails after the re-point committed' => sub {
    # The exact hole. One eval covered both the re-point and the re-enable, so
    # a failure of the second was rolled back as though it were a failure of
    # the first: rename back, and nothing said about device_path. n => 1, so
    # only the forward enable fails and the rollback's own enable is free to
    # succeed - the point is that it is issued against a path that no longer
    # exists, not that it was sabotaged.
    my $r = run_create_base(fail => {
        'ns:enable' => { err => "[EPERM] not authorized\n", n => 1 } });
    ok(!$r->{ok}, 'create_base fails');

    my $outcome = assert_resolved('step 3b re-enable failure', $r, xfb => 1);

    # Spell out the bad end state, so a regression names itself instead of
    # only flipping the assertion above.
    ok(!($tn{dataset} eq $OLD_DS && $tn{device_path} eq $NEW_PATH),
        'the dataset is not left at its old name while the share points at the new one' . XFB)
        or diag(state_dump($r));
    ok($tn{enabled} || $outcome eq 'quarantine',
        'the namespace is not left silently disabled' . XFB)
        or diag(state_dump($r));
};

subtest 'step 3b: the rollback restores device_path before re-enabling' => sub {
    my $r = run_create_base(fail => {
        'ns:enable' => { err => "[EPERM] not authorized\n", n => 1 } });
    my @c = @{ $r->{calls} };
    my ($back)    = grep { $c[$_] eq 'rename:new->old' } 0 .. $#c;
    my ($repoint) = grep { $c[$_] eq 'ns:path=old' }     0 .. $#c;
    # The last enable, not the first: the first one is the forward enable in
    # step 3, the one whose failure put us on this path at all.
    my ($enable)  = reverse grep { $c[$_] eq 'ns:enable' } 0 .. $#c;

    ok(defined $back, 'the rollback renames the dataset back');
    ok(defined $repoint, 'the rollback re-points device_path at the old zvol' . XFB)
        or diag(state_dump($r));
    ok(defined($back) && defined($repoint) && $back < $repoint,
        'and does it after the rename, when the old path resolves again' . XFB)
        or diag(state_dump($r));
    ok(defined($repoint) && defined($enable) && $repoint < $enable,
        'and re-enables only after that' . XFB)
        or diag(state_dump($r));
};

# ===========================================================================
# Defect 2 - the retried rename
# ===========================================================================

subtest 'step 2: the rename commits and the response is lost' => sub {
    # The mutation lands, the answer does not. _is_connection_error matches a
    # read timeout, so the retry fires, and the retry asks to rename something
    # that has already been renamed.
    my $r = run_create_base(fail => {
        'rename:old->new' => { err => "broker: read timeout after 30s\n", after => 1, n => 1 },
    });

    assert_resolved('step 2 lost response', $r, xfb => 1);

    # The rename did land, so the only correct outcome is to carry on. Rolling
    # back would be defensible in principle, but there is nothing here to roll
    # back from: the unfixed code cannot tell that it happened.
    ok($r->{ok}, 'create_base succeeds on the strength of the rename that did land' . XFB)
        or diag(state_dump($r));

    # What the operator was shown. "does not exist" describes the retry, and
    # sends whoever reads it looking for a deleted dataset.
    unlike($r->{err} // '', qr/does not exist/i,
        'and does not report a missing dataset that is in fact present' . XFB);
};

subtest 'step 2: a lost response is reconciled by asking where the dataset is' => sub {
    my $r = run_create_base(fail => {
        'rename:old->new' => { err => "broker: read timeout after 30s\n", after => 1, n => 1 },
    });
    my @c = @{ $r->{calls} };
    my $renames = grep { $_ eq 'rename:old->new' } @c;
    # Either read is fine - a filtered query or a get_instance wrapped in an
    # eval. What matters is that the pool is asked, not which call asks it.
    my $probes  = grep { $_ eq 'q:pool.dataset.query'
                      || $_ eq 'q:pool.dataset.get_instance' } @c;

    is($renames, 1, 'the rename is attempted exactly once, with retries off' . XFB)
        or diag(state_dump($r));
    ok($probes >= 1, 'and its outcome is read back from the pool' . XFB)
        or diag(state_dump($r));
};

subtest 'iscsi: the rename commits and the response is lost' => sub {
    # Same defect, other transport. Here the step 2 handler has no namespace to
    # re-enable, so the failure is quieter and the extent is simply left aimed
    # at a name the dataset no longer answers to.
    my $r = run_create_base(mode => 'iscsi', fail => {
        'rename:old->new' => { err => "broker: read timeout after 30s\n", after => 1, n => 1 },
    });
    assert_resolved('iscsi step 2 lost response', $r, xfb => 1);
};

subtest 'step 2: the rename genuinely fails, repeatedly' => sub {
    # The other half of the reconcile: a rename that really did not happen must
    # still be treated as a failure, not waved through.
    my $r = run_create_base(fail => {
        'rename:old->new' => { err => "broker: read timeout after 30s\n", n => 9 },
    });
    ok(!$r->{ok}, 'create_base fails');
    assert_resolved('step 2 genuine failure', $r);
    is($tn{dataset}, $OLD_DS, 'and the dataset is where it started');
};

subtest 'step 1: the disable commits and the response is lost, retries exhausted' => sub {
    # namespace.update is idempotent, so a single lost response heals on the
    # retry. Exhaust the retries and it does not: the namespace is off, and
    # create_base walks away from it.
    my $r = run_create_base(fail => {
        'ns:disable' => { err => "broker: read timeout after 30s\n", after => 1, n => 9 },
    });
    ok(!$r->{ok}, 'create_base fails');
    assert_resolved('step 1 lost response, retries exhausted', $r, xfb => 1);
};

subtest 'step 3a: the re-point commits and the response is lost, retries exhausted' => sub {
    # device_path is now the new path, but the code has no record of it. A
    # rollback driven by what it believes it did will skip the re-point and
    # re-enable against a dangling path. One that reads the namespace back
    # before acting will not.
    my $r = run_create_base(fail => {
        'ns:path=new' => { err => "broker: read timeout after 30s\n", after => 1, n => 9 },
    });
    ok(!$r->{ok}, 'create_base fails');
    assert_resolved('step 3a lost response, retries exhausted', $r, xfb => 1);
};

# ===========================================================================
# Adjacent, same family: the snapshot is not idempotent either
# ===========================================================================
# These two cover the OPTIONAL hunk in the patch. If that hunk is not applied
# they fail after the fix as well as before it, which is the honest reading -
# the defect is real either way.

subtest 'step 4: the snapshot commits and the response is lost' => sub {
    my $r = run_create_base(fail => {
        'snap:create' => { err => "broker: read timeout after 30s\n", after => 1, n => 1 },
    });
    assert_resolved('step 4 lost response', $r, xfb => 1);
    ok($r->{ok}, 'create_base succeeds on the strength of the snapshot that did land' . XFB)
        or diag(state_dump($r));
};

subtest 'step 4: a stray __base__ does not brick the template forever' => sub {
    # The consequence of rolling back on a snapshot that had in fact been
    # taken. The anchor follows the dataset back to vm-*, and
    # pool.snapshot.create is name-unique, so every later attempt hits the same
    # wall and the template can never be made at all.
    #
    # Two shapes are acceptable. Reconcile the lost response and the first
    # attempt just succeeds, leaving no stray anchor for anything to trip over.
    # Roll back instead and the anchor is left behind, in which case the second
    # attempt has to cope with it. What is not acceptable is rolling back and
    # then failing forever on the litter.
    my $first = run_create_base(fail => {
        'snap:create' => { err => "broker: read timeout after 30s\n", after => 1, n => 1 },
    });
    if ($first->{ok}) {
        assert_resolved('step 4 lost response, reconciled on the first attempt',
                        $first, xfb => 1);
        return;
    }
    my $second = run_create_base(no_reset => 1);
    ok($second->{ok}, 'a second attempt after a lost snapshot response can still succeed' . XFB)
        or diag(state_dump($second));
    assert_resolved('step 4 lost response, second attempt', $second, xfb => 1);
};

done_testing();
