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

my ($ns_answer, $busy, $disconnects, $deletes, $ns_calls);
{
    no strict 'refs'; no warnings 'redefine';
    *{"${PKG}::_log"} = sub { 1 };
    *{"${PKG}::_defer_after_lock"} = sub { 1 };
    *{"${PKG}::run_command"} = sub { 1 };
    *{"${PKG}::_verify_devices_disconnected"} = sub { 1 };
    *{"${PKG}::_nvme_find_device_by_subsystem"} = sub { undef };
    *{"${PKG}::_assert_no_child_datasets"} = sub { 1 };
    *{"${PKG}::_nvme_connect"} = sub { 1 };
    *{"${PKG}::usleep"} = sub ($) { 1 };
    *{"${PKG}::sleep"} = sub { 1 };
    *{"${PKG}::_nvme_disconnect"} = sub { $disconnects++; 1 };
    *{"${PKG}::_nvme_subsystem_busy"} = sub { return $busy ? (1, '/dev/nvme0n1') : (0, '/dev/nvme0n1') };
    *{"${PKG}::_nvme_delete_namespace"} = sub { $deletes++; die "[EBUSY] namespace is in use\n" if $deletes == 1; 1 };
    *{"${PKG}::_api_call"} = sub {
        my ($s, $m) = @_;
        return [ { id => 3 } ] if $m eq 'nvmet.subsys.query';
        if ($m eq 'nvmet.namespace.query') { $ns_calls++; return $ns_answer; }
        return [];
    };
}

sub run_free {
    my (%o) = @_;
    ($ns_answer, $busy) = ($o{ns}, $o{busy});
    ($disconnects, $deletes, $ns_calls) = (0, 0, 0);
    my $ok = eval {
        $PKG->can('_free_image_nvme')->($PKG, 'store', $scfg, 'vol-vm-101-disk-0-ns11111111-2222-3333-4444-555555555555',
            'vm-101-disk-0', 'tank/pve/vm-101-disk-0', '11111111-2222-3333-4444-555555555555');
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

done_testing;
