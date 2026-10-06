#!/usr/bin/perl
# _nvme_device_for_uuid may reconnect (nvme disconnect -d) only when no device
# of the subsystem is in use. `nvme disconnect` drops EVERY controller of the
# subsystem, so forcing it with a live VM on another namespace gives that VM
# EIO. Upstream's i==125 "last resort" and its emergency block forced it.
#
# Run with:  prove -v t/nvme/28-reconnect-use-gate.t
use strict;
use warnings;
use Test::More;
use FindBin;

my $PLUGIN = "$FindBin::Bin/../../TrueNASPlugin.pm";
unless (eval { require $PLUGIN; 1 }) {
    plan skip_all => "cannot load TrueNASPlugin.pm (needs PVE perl modules): $@";
}
my $PKG = 'PVE::Storage::Custom::TrueNASPlugin';
my $f = $PKG->can('_nvme_device_for_uuid') or BAIL_OUT('missing');

my ($in_use, $disconnects, $connects);
{
    no strict 'refs'; no warnings 'redefine';
    *{"${PKG}::_log"} = sub { 1 };
    *{"${PKG}::usleep"} = sub { 1 };
    *{"${PKG}::run_command"} = sub { 1 };
    *{"${PKG}::_nvme_find_device_by_subsystem"} = sub { return { linux_device_count => 1, selector_outcome => 'no_match' } };
    *{"${PKG}::_nvme_is_connected"} = sub { 1 };
    *{"${PKG}::_nvme_rescan_subsystem_controllers"} = sub { 1 };
    *{"${PKG}::_nvme_get_subsystem_device_paths"} = sub { ('/dev/nvme0n1') };
    *{"${PKG}::_nvme_check_devices_in_use"} = sub { $in_use };
    *{"${PKG}::_nvme_reap_orphan_namespaces"} = sub { 0 };
    *{"${PKG}::_nvme_disconnect"} = sub { $disconnects++ };
    *{"${PKG}::_nvme_connect"} = sub { $connects++ };
    *{"${PKG}::_api_call"} = sub { [ { id => 1 } ] };   # TN has the uuid
}
my $scfg = { tn_subsystem_nqn => 'nqn.x:y', tn_dataset => 'tank/pve' };

for my $case ([1, 'devices in use'], [0, 'no device in use']) {
    ($in_use, my $label) = @$case;
    $disconnects = $connects = 0;
    my $ok = eval { $f->($scfg, 'uuid-1', allow_reconnect => 1); 1 };
    ok(!$ok, "$label: the lookup of a missing device still fails");
    if ($in_use) {
        is($disconnects, 0, "$label: _nvme_disconnect is NEVER invoked (no i==125 force, no emergency)");
        like($@, qr/Could not locate NVMe device/, '  ...with the readable error');
    } else {
        ok($disconnects > 0, "$label: reconnect is allowed");
    }
}

# The i==25 "zero devices" gate must respect allow_reconnect and must not read a
# failed enumeration as zero devices.
{
    no strict 'refs'; no warnings 'redefine';
    local *{"${PKG}::_nvme_find_device_by_subsystem"} = sub { undef };   # never sees devices
    local *{"${PKG}::_nvme_check_devices_in_use"} = sub { 0 };
    $in_use = 0;
    $disconnects = 0;
    eval { $f->($scfg, 'uuid-1', allow_reconnect => 0) };
    is($disconnects, 0, 'i==25 gate: allow_reconnect=0 never disconnects');
    local *{"${PKG}::_nvme_get_subsystem_device_paths"} = sub { die "cannot enumerate
" };
    $disconnects = 0;
    eval { $f->($scfg, 'uuid-1', allow_reconnect => 1) };
    is($disconnects, 0, 'i==25 gate: an enumeration that FAILS is not "zero devices", no disconnect');
}
done_testing;
