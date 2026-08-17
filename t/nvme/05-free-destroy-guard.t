#!/usr/bin/perl
# Freeing a volume must not destroy the zvol unless its export is gone.
#
# Deletion is a sequence: remove the NVMe namespace, then destroy the dataset -
# and the destroy is issued with force => true, which tells ZFS to go ahead even
# though the zvol is busy. The order is right; the error handling was not.
#
# _nvme_delete_namespace wrapped each nvmet.namespace.delete in an eval and
# turned every failure into a log line, returning normally either way. The
# caller's `my $ok = eval { _nvme_delete_namespace(...); 1 }` was therefore true
# whenever the *query* had succeeded, however many deletes had failed, and the
# branch meant to catch that could not fire. On the one path that did notice,
# the code warned and carried on. Either way the dataset was then destroyed with
# force => true while a namespace still pointed at it - and any initiator still
# attached kept writing to a device whose backing store had been removed.
#
# The log line that was the sole record of it was level 1, and tn_debug defaults
# to 0, which discards it. So the failure was silent as well as destructive.
#
# These tests drive the real free path with a stubbed API layer and assert on
# what it tried to send. The assertion that matters is a negative one: no
# pool.dataset.delete may appear after a namespace delete that failed.
#
# Run with:  prove -v t/nvme/05-free-destroy-guard.t

use strict;
use warnings;
use Test::More;
use FindBin;

my $PLUGIN = "$FindBin::Bin/../../TrueNASPlugin.pm";
unless (eval { require $PLUGIN; 1 }) {
    plan skip_all => "cannot load TrueNASPlugin.pm (needs PVE perl modules): $@";
}

my $PKG = 'PVE::Storage::Custom::TrueNASPlugin';
my $free = $PKG->can('_free_image_nvme');
plan skip_all => "_free_image_nvme not found" unless $free;

my @calls;      # every method the code tried to call, in order
my %fail;       # method => error string to throw

{
    no strict 'refs';
    no warnings 'redefine';
    *{"${PKG}::_log"} = sub { 1 };
    # Keep the destructive steps off any real machine while still recording
    # the intent. Deferred work would otherwise try to touch nvme-cli.
    *{"${PKG}::_defer_after_lock"}  = sub { 1 };
    *{"${PKG}::_nvme_disconnect"}   = sub { push @calls, 'nvme_disconnect'; 1 };
    *{"${PKG}::run_command"}        = sub { 1 };

    *{"${PKG}::_api_call"} = sub {
        my ($scfg, $method, $params) = @_;
        push @calls, $method;
        die $fail{$method} if exists $fail{$method};
        # One namespace, pointing at our zvol.
        return [ { id => 42, device_path => 'zvol/tank/pve/vm-101-disk-0' } ]
            if $method eq 'nvmet.namespace.query';
        return [] if $method eq 'nvmet.subsys.query';
        return { id => 1 };
    };
    *{"${PKG}::_api_call_mutate"} = sub { goto &{"${PKG}::_api_call"} };
}

my $scfg = {
    tn_dataset => 'tank/pve', tn_api_host => '198.51.100.7',
    tn_transport_mode => 'nvme', tn_subsystem_nqn => 'nqn.2011-06.com.example:test',
};

sub run_free {
    %fail = @_;
    @calls = ();
    # ($class, $storeid, $scfg, $volname, $zname, $full_ds, $metadata)
    my $ok = eval {
        $free->($PKG, 'store', $scfg, 'vol-vm-101-disk-0-lun1',
                'vm-101-disk-0', 'tank/pve/vm-101-disk-0', undef);
        1;
    };
    return ($ok, $@, [@calls]);
}

sub destroyed {
    my ($calls) = @_;
    return scalar grep { $_ eq 'pool.dataset.delete' } @$calls;
}

# ---------------------------------------------------------------------------
# The happy path still destroys, or the guard would be useless
# ---------------------------------------------------------------------------

{
    my ($ok, $err, $calls) = run_free();
    ok($ok, 'a clean free succeeds') or diag("died with: $err");
    ok(destroyed($calls), '...and does destroy the dataset');
}

# ---------------------------------------------------------------------------
# A namespace that will not delete must stop the destroy
# ---------------------------------------------------------------------------

# Permission denied is the realistic one: the pilot API key deliberately lacks
# the delete privileges, and a production key can be tightened at any time.
{
    my ($ok, $err, $calls) = run_free('nvmet.namespace.delete' => "EPERM: not authorized\n");
    ok(!$ok, 'a namespace that cannot be deleted makes the free fail');
    is(destroyed($calls), 0, '...and the dataset is NOT destroyed');
    like($err // '', qr/refusing to destroy/i, '...with an error that says why');
}

# A timeout tells us nothing about whether the namespace went away, which is
# exactly the state in which destroying the backing store is unsafe.
{
    my ($ok, $err, $calls) = run_free('nvmet.namespace.delete' => "broker: read timeout after 30s\n");
    ok(!$ok, 'a timed-out namespace delete makes the free fail');
    is(destroyed($calls), 0, '...and the dataset is NOT destroyed');
}

# Transport loss, same reasoning.
{
    my ($ok, $err, $calls) = run_free('nvmet.namespace.delete' => "Connection reset by peer\n");
    ok(!$ok, 'a lost connection during namespace delete makes the free fail');
    is(destroyed($calls), 0, '...and the dataset is NOT destroyed');
}

# ---------------------------------------------------------------------------
# But "already gone" is success, not failure
# ---------------------------------------------------------------------------

# free_image has to be idempotent: PVE retries it, and a namespace removed by an
# earlier attempt must not block the dataset from ever being cleaned up.
{
    my ($ok, $err, $calls) = run_free('nvmet.namespace.delete' => "InstanceNotFound: does not exist\n");
    ok($ok, 'a namespace that was already gone does not block the free')
        or diag("died with: $err");
    ok(destroyed($calls), '...and the dataset is still destroyed');
}

# ---------------------------------------------------------------------------
# The ordering itself
# ---------------------------------------------------------------------------

{
    my ($ok, $err, $calls) = run_free();
    my ($ns_at) = grep { $calls->[$_] eq 'nvmet.namespace.delete' } 0 .. $#$calls;
    my ($ds_at) = grep { $calls->[$_] eq 'pool.dataset.delete' }   0 .. $#$calls;
    ok(defined($ns_at) && defined($ds_at) && $ns_at < $ds_at,
        'the export is removed before the backing store, not after')
        or diag("order was: " . join(' -> ', @$calls));
}

done_testing();
