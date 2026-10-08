#!/usr/bin/perl
# _free_image_nvme, opt-in tn_force_delete_on_inuse path: the subsystem-wide
# `nvme disconnect` takes down every disk of every guest on the node, so
#   - an UNKNOWN namespace count (exception, undef, non-list answer) must mean
#     "assume shared": no disconnect, the free dies;
#   - even with a known count of 1, a device in use (or unreadable) stops it.
# Before this, undef / a hash fell into the "last namespace" arm and
# disconnected without ever asking whether anything was using the devices.
#
# Run with:  prove -v t/nvme/35-free-nvme-disconnect-gate.t
use strict;
use warnings;
use Test::More;
use FindBin;

my $PLUGIN = "$FindBin::Bin/../../TrueNASPlugin.pm";
unless (eval { require $PLUGIN; 1 }) {
    plan skip_all => "cannot load TrueNASPlugin.pm (needs PVE perl modules): $@";
}
my $PKG = 'PVE::Storage::Custom::TrueNASPlugin';
my $scfg = { tn_dataset => 'tank/pve', tn_api_host => '198.51.100.7', tn_transport_mode => 'nvme-tcp',
             tn_subsystem_nqn => 'nqn.x:y', tn_force_delete_on_inuse => 1 };

my ($ns_answer, $subsys_answer, $busy, $disconnects, $deletes, $ns_calls, $retry_fails, $ds_deletes, @events, @log0, $connect_dies);
{
    no strict 'refs'; no warnings 'redefine';
    *{"${PKG}::_log"} = sub { push @log0, $_[3] if $_[1] == 0; 1 };
    *{"${PKG}::_defer_after_lock"} = sub { 1 };
    *{"${PKG}::run_command"} = sub { 1 };
    *{"${PKG}::_verify_devices_disconnected"} = sub { 1 };
    *{"${PKG}::_nvme_find_device_by_subsystem"} = sub { undef };
    *{"${PKG}::_assert_no_child_datasets"} = sub { 1 };
    *{"${PKG}::_nvme_connect"} = sub { push @events, 'connect'; die "nvme connect failed: Connection timed out\n" if $connect_dies; 1 };
    *{"${PKG}::usleep"} = sub ($) { 1 };
    *{"${PKG}::sleep"} = sub { 1 };
    *{"${PKG}::_nvme_disconnect"} = sub { $disconnects++; push @events, 'disconnect'; 1 };
    *{"${PKG}::_nvme_subsystem_busy"} = sub { return $busy ? (1, '/dev/nvme0n1') : (0, '/dev/nvme0n1') };
    *{"${PKG}::_nvme_delete_namespace"} = sub {
        $deletes++;
        die "[EBUSY] namespace is in use\n" if $deletes == 1 || $retry_fails;
        1;
    };
    *{"${PKG}::_api_call_mutate"} = sub { $ds_deletes++ if $_[1] eq 'pool.dataset.delete'; 1 };
    *{"${PKG}::_handle_api_result_with_job_support"} = sub { { success => 1, result => 1 } };
    *{"${PKG}::_invalidate_status_capacity_cache"} = sub { 1 };
    *{"${PKG}::_api_call"} = sub {
        my ($s, $m) = @_;
        return $subsys_answer if $m eq 'nvmet.subsys.query';
        if ($m eq 'nvmet.namespace.query') { $ns_calls++; return $ns_answer; }
        return [];
    };
}

sub run_free {
    my (%o) = @_;
    ($ns_answer, $busy) = ($o{ns}, $o{busy});
    $subsys_answer = exists $o{subsys} ? $o{subsys} : [ { id => 3 } ];
    $retry_fails = $o{retry_fails};
    $connect_dies = $o{connect_dies};
    (@events, @log0) = ();
    ($disconnects, $deletes, $ns_calls, $ds_deletes) = (0, 0, 0, 0);
    my $ok = eval {
        my $w = $PKG->can('_free_image_nvme')->($PKG, 'store', $scfg, 'vol-vm-101-disk-0-ns11111111-2222-3333-4444-555555555555',
            'vm-101-disk-0', 'tank/pve/vm-101-disk-0', '11111111-2222-3333-4444-555555555555');
        $w->('UPID:t') if ref($w) eq 'CODE';
        1;
    };
    return ($ok, $@);
}

{
    my ($ok, $err) = run_free(ns => undef);
    ok(!$ok, 'count query answers undef (no exception) -> the free dies');
    is($disconnects, 0, '  ...and NO nvme disconnect');
    like($err, qr/count could not be determined|refusing to destroy/, '  ...with a clear message');
}
{
    my ($ok) = run_free(ns => { id => 1 });
    ok(!$ok, 'count query answers a hash (not a list) -> the free dies');
    is($disconnects, 0, '  ...and NO nvme disconnect');
}
{
    my ($ok, $err) = run_free(ns => [ { id => 1 } ], busy => 1);
    ok(!$ok, 'one namespace but a device in use -> the free dies');
    is($disconnects, 0, '  ...and NO nvme disconnect with a device in use');
    like($err, qr/in use/, '  ...saying a device is in use');
}
{
    my ($ok, $err) = run_free(ns => [ { id => 1 } ], busy => 0);
    ok($ok, 'one namespace and nothing in use -> the disconnect-and-retry still works') or diag($err);
    is($disconnects, 1, '  ...with exactly one disconnect');
}
{
    my ($ok) = run_free(ns => [ { id => 1 }, { id => 2 } ], busy => 0);
    is($disconnects, 0, 'two namespaces -> shared subsystem, never disconnected');
}

# K3: the namespace is KNOWN to exist (its delete said "in use"). An empty list
# from either query is therefore not "zero": it is documented to come back empty
# transiently under load. Unknown => no disconnect, the free dies.
{
    my ($ok) = run_free(ns => [ { id => 1 } ], subsys => []);
    ok(!$ok, 'empty nvmet.subsys.query although the namespace exists -> the free dies');
    is($disconnects, 0, '  ...and NO nvme disconnect');
    ($ok) = run_free(ns => []);
    ok(!$ok, 'empty nvmet.namespace.query although the namespace exists -> the free dies');
    is($disconnects, 0, '  ...and NO nvme disconnect');
    is($ds_deletes, 0, '  ...and the dataset is not touched');
}
# K2: when the namespace could not be removed it is STILL EXPORTED: the dataset
# must not be handed to the delete worker.
{
    my ($ok, $err) = run_free(ns => [ { id => 1 }, { id => 2 } ], busy => 0);
    ok(!$ok, 'shared subsystem (2 namespaces), namespace delete failed -> the free dies');
    like($err, qr/namespace still exported/, '  ...saying the namespace is still exported');
    is($ds_deletes, 0, '  ...and NO dataset delete was issued');
    is($disconnects, 0, '  ...and no disconnect');

    ($ok, $err) = run_free(ns => [ { id => 1 } ], busy => 0, retry_fails => 1);
    ok(!$ok, 'last namespace, disconnect done, retry still fails -> the free dies');
    like($err, qr/namespace still exported/, '  ...saying the namespace is still exported');
    is($ds_deletes, 0, '  ...and NO dataset delete was issued');
    is($disconnects, 1, '  ...after exactly the one disconnect it had made');

    ($ok, $err) = run_free(ns => [ { id => 1 } ], busy => 0);
    ok($ok, 'retry succeeds -> the free continues as before') or diag($err);
    is($ds_deletes, 1, '  ...and the dataset delete is issued');
}

# L2: the compensating reconnect after a failed retry.
{
    my ($ok, $err) = run_free(ns => [ { id => 1 } ], busy => 0, retry_fails => 1);
    is_deeply(\@events, [ 'disconnect', 'connect' ], 'retry failed: exactly one connect, AFTER the disconnect');
    like($err, qr/namespace still exported/, '  ...the death keeps "namespace still exported"');
    like($err, qr/cause: \[EBUSY\] namespace is in use/, '  ...and the original cause');
    unlike($err, qr/reconnecting the subsystem also failed/, '  ...with no reconnect warning when the reconnect worked');
}
{
    my ($ok, $err) = run_free(ns => [ { id => 1 } ], busy => 0, retry_fails => 1, connect_dies => 1);
    ok(!$ok, 'the reconnect itself dies: the free still dies');
    like($err, qr/namespace still exported/, '  ...with the ORIGINAL message');
    like($err, qr/cause: \[EBUSY\] namespace is in use/, '  ...and the original cause, not the connect error');
    like($err, qr/may have no NVMe paths until status\(\) repairs/, '  ...and it says the node may have no paths');
    ok((grep { /reconnecting the NVMe subsystem failed.*Connection timed out/ } @log0),
       '  ...and the connect failure is logged at level 0');
}
{
    run_free(ns => [ { id => 1 }, { id => 2 } ], busy => 0);
    is_deeply(\@events, [], 'shared subsystem (no disconnect): _nvme_connect is NOT called');
    run_free(ns => [ { id => 1 } ], busy => 0);
    is_deeply(\@events, [ 'disconnect', 'connect' ], 'retry succeeds: the one reconnect after the disconnect (as before)');
    run_free(ns => [ { id => 1 } ], busy => 0, connect_dies => 1);
    ok((grep { /reconnection failed after namespace deletion/ } @log0), 'reconnect failure after a SUCCESSFUL delete is logged at level 0');
}

done_testing;
