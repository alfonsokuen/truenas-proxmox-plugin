#!/usr/bin/perl
# Offline tests for the NVMe-oF host whitelist.
#
# Needs no TrueNAS: the API layer is stubbed and every call is recorded, so the
# tests assert on the sequence of calls rather than on their effect. That is the
# point - what makes this feature safe or unsafe is the ORDER in which the
# subsystem is closed and the host authorized.
#
# The target holds allow_any_host and an explicit host list as mutually
# exclusive. Measured against a live nvmet target (kernel 6.8):
#
#   * linking a host while allow_any_host=1  -> EINVAL
#   * setting allow_any_host=1 with hosts    -> EINVAL
#   * tightening does NOT tear down controllers that are already established
#
# So the only order the target accepts is close-then-authorize, and the window
# in between - closed, nobody authorized yet - cannot be designed away.
#
# Run with:  prove -v t/nvme/02-host-whitelist.t

use strict;
use warnings;
use Test::More;
use FindBin;
use JSON::PP ();

my $PLUGIN = "$FindBin::Bin/../../TrueNASPlugin.pm";

unless (eval { require $PLUGIN; 1 }) {
    plan skip_all => "cannot load TrueNASPlugin.pm (needs PVE perl modules): $@";
}

my $PKG     = 'PVE::Storage::Custom::TrueNASPlugin';
my $HOSTNQN = 'nqn.2014-08.org.nvmexpress:uuid:aaaa-bbbb';

my @CALLS;          # every API call, in order
my %REPLIES;        # method => coderef returning the reply (or dying)
my %FAIL;           # method => error string to die with

{
    no strict 'refs';
    no warnings 'redefine';
    my $record = sub {
        my ($scfg, $method, $params) = @_;
        push @CALLS, { method => $method, params => $params };
        die $FAIL{$method} if exists $FAIL{$method};
        return $REPLIES{$method} ? $REPLIES{$method}->($params) : [];
    };
    *{"${PKG}::_api_call"}        = $record;
    *{"${PKG}::_api_call_mutate"} = $record;
    *{"${PKG}::_log"}             = sub { 1 };
}

my $reconcile = $PKG->can('_nvme_reconcile_host_whitelist');
my $resync    = $PKG->can('_nvme_resync_configfs');
my $is_dup    = $PKG->can('_nvme_err_is_duplicate');

sub scfg {
    my (%over) = @_;
    return {
        tn_api_host            => 'nas.example.com',
        tn_subsystem_nqn       => 'nqn.2011-06.com.truenas:uuid:1111-2222:pve',
        tn_hostnqn             => $HOSTNQN,
        tn_nvme_allow_any_host => 0,
        %over,
    };
}

# The reconcile caches success for $CACHE_TTL and that cache is a lexical of the
# module - there is no reaching in to clear it. So each scenario gets its own
# subsystem id instead, which is both the only reliable isolation and the thing
# under test: the cache key has to carry the subsystem, or one storage's
# reconcile seals another subsystem that was never touched.
my $NEXT_SUBSYS = 100;
sub fresh {
    @CALLS = ();
    %FAIL  = ();
    return $NEXT_SUBSYS++;
}

sub methods { return map { $_->{method} } @CALLS }

$REPLIES{'nvmet.host.create'}        = sub { { id => 7 } };
$REPLIES{'nvmet.host_subsys.create'} = sub { { id => 9 } };

# ---------------------------------------------------------------------------
# Open mode is untouched
# ---------------------------------------------------------------------------

$reconcile->(scfg(tn_nvme_allow_any_host => 1), fresh(), 1);
is_deeply([methods()], [], 'open mode issues no calls at all');

$reconcile->(scfg(tn_nvme_allow_any_host => undef), fresh(), 1);
is_deeply([methods()], [], 'an unset option means open mode, which is also a no-op');

# ---------------------------------------------------------------------------
# The order the target accepts
# ---------------------------------------------------------------------------

# The one transition that matters: a subsystem that is still open. Registering
# a host here before closing asks for allow_any_host=1 WITH a host attached,
# which is the state the kernel refuses to render - and an aborted render is
# what makes namespace changes silently not reach the running target.
$reconcile->(scfg(), fresh(), 1);   # 1 = currently open
my @m = methods();
my ($close_at) = grep { $m[$_] eq 'nvmet.subsys.update' } 0 .. $#m;
my ($auth_at)  = grep { $m[$_] eq 'nvmet.host_subsys.create' } 0 .. $#m;
ok(defined $close_at, 'an open subsystem is closed');
ok(defined $auth_at,  'and the host is authorized');
ok(defined $close_at && defined $auth_at && $close_at < $auth_at,
    'the subsystem is closed BEFORE the host is authorized, never after');

ok(defined $close_at && !$CALLS[$close_at]{params}[1]{allow_any_host},
    'and it is closed, not reopened');

# Already closed: no redundant write, but the host still gets registered - this
# is how a node that was not around for the transition catches up.
$reconcile->(scfg(), fresh(), 0);   # 0 = already closed
ok(scalar(@CALLS), 'an already-closed subsystem is still reconciled, not skipped');
ok(!grep({ $_ eq 'nvmet.subsys.update' } methods()),
    '...without a redundant write to close what is already closed');
ok(scalar(grep { $_ eq 'nvmet.host_subsys.create' } methods()),
    '...and this node still authorizes itself, which is how a node that missed '
    . 'the transition catches up');

# State unknown: assume it needs closing rather than assume it does not.
$reconcile->(scfg(), fresh(), undef);
ok(scalar(grep { $_ eq 'nvmet.subsys.update' } methods()),
    'an unknown current state is closed rather than trusted');

# ---------------------------------------------------------------------------
# A half-done reconcile must not be remembered as done
# ---------------------------------------------------------------------------

{
    my $sub = fresh();
    $FAIL{'nvmet.subsys.update'} = "boom\n";
    eval { $reconcile->(scfg(), $sub, 1) };
    ok(!grep({ $_ eq 'nvmet.host.create' } methods()),
        'if closing fails, nothing is authorized against a subsystem still open');

    # Same subsystem again: a sealed cache here would mean a subsystem left
    # open is never reconciled again for the whole TTL.
    my $n = scalar(@CALLS);
    %FAIL = ();
    $reconcile->(scfg(), $sub, 1);
    ok(scalar(@CALLS) > $n,
        '...and the failure is not cached, so the next ensure retries');
}

{
    my $sub = fresh();
    $FAIL{'nvmet.host_subsys.create'} = "boom\n";
    eval { $reconcile->(scfg(), $sub, 1) };
    ok($@, 'a failure to authorize after closing is fatal, not swallowed');

    my $n = scalar(@CALLS);
    %FAIL = ();
    eval { $reconcile->(scfg(), $sub, 0) };
    ok(scalar(@CALLS) > $n,
        '...and is not cached either: the retry finds the subsystem already closed');
}

# ---------------------------------------------------------------------------
# The cache must not span subsystems
# ---------------------------------------------------------------------------

# Two storages against one TrueNAS share a _cache_host_key. Keyed on that alone,
# reconciling one sealed the cache for a subsystem nobody had touched - while
# _nvme_resync_configfs closed that subsystem by a path the cache never sees.
{
    my $a = fresh();
    my $b = $NEXT_SUBSYS++;      # same tn_api_host, different subsystem
    $reconcile->(scfg(), $a, 1);
    my $after_first = scalar(@CALLS);
    ok($after_first, 'the first reconcile does work');
    $reconcile->(scfg(), $a, 1);
    is(scalar(@CALLS), $after_first,
        'the same subsystem is not reconciled twice inside the TTL');
    $reconcile->(scfg(), $b, 1);
    ok(scalar(@CALLS) > $after_first,
        'a DIFFERENT subsystem on the same server is still reconciled');
}

# ---------------------------------------------------------------------------
# The configfs poke must not decide access control
# ---------------------------------------------------------------------------

# It exists to make middleware re-render after a namespace change, and it is
# called from four sites that know nothing about the access model. Writing the
# CONFIGURED value there closed subsystems nobody had been authorized on.
for my $case ([1, 'open'], [0, 'closed']) {
    my ($cur, $label) = @$case;
    my $sub = fresh();
    $REPLIES{'nvmet.subsys.query'} = sub { [ { id => $sub, allow_any_host => $cur } ] };
    $resync->(scfg(), $sub, 'test');
    my ($upd) = grep { $_->{method} eq 'nvmet.subsys.update' } @CALLS;
    ok($upd, "resync still pokes the subsystem when it is $label");
    is($upd ? ($upd->{params}[1]{allow_any_host} ? 1 : 0) : undef, $cur,
        "...writing back the value the subsystem already has, not the configured one");
}

# Configured open, subsystem closed: the old code wrote true over an explicit
# host list, which the kernel refuses - aborting the render it meant to force.
{
    my $sub = fresh();
    $REPLIES{'nvmet.subsys.query'} = sub { [ { id => $sub, allow_any_host => 0 } ] };
    $resync->(scfg(tn_nvme_allow_any_host => 1), $sub, 'test');
}
{
    my ($upd) = grep { $_->{method} eq 'nvmet.subsys.update' } @CALLS;
    ok($upd && !$upd->{params}[1]{allow_any_host},
        'a subsystem hardened by hand is not reopened by a plugin configured for open access');
}

# ---------------------------------------------------------------------------
# What "already there" actually looks like
# ---------------------------------------------------------------------------

# _api_call_mutate retries a mutation whose reply was lost, so a create that
# already succeeded is re-sent as a matter of course - the duplicate branch is
# reached in normal operation, not just under a race.
ok($is_dup->('[EINVAL] nvmet_host_create.hostnqn: Extent name must be unique'),
    'the uniqueness error TrueNAS actually returns counts as a duplicate');
ok($is_dup->('IntegrityError: UNIQUE constraint failed: nvmet_host.hostnqn'),
    '...as does the database-level one');
ok($is_dup->('record already exists'), '...and the plain wording');
ok(!$is_dup->('connection refused'), 'an unrelated error is not mistaken for one');
ok(!$is_dup->(undef), 'and undef is not either');

done_testing();
