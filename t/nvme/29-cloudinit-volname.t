#!/usr/bin/perl
# Cloud-init volnames on NVMe. Upstream beta8 names a new cloud-init disk the
# bare "vm-<vmid>-cloudinit"; this fork's path() resolves a volume from the
# UUID embedded in its volname (pure name resolution), idk21 nodes cannot parse
# the bare form (mixed cluster), and `qm rescan` would list the zvol idk21
# published as vol-vm-N-cloudinit-ns<uuid> a second time. So new cloud-init
# disks keep idk21's embedded-uuid form, and existing ones keep resolving.
#
# Run with:  prove -v t/nvme/29-cloudinit-volname.t
use strict;
use warnings;
use Test::More;
use FindBin;

my $PLUGIN = "$FindBin::Bin/../../TrueNASPlugin.pm";
unless (eval { require $PLUGIN; 1 }) {
    plan skip_all => "cannot load TrueNASPlugin.pm (needs PVE perl modules): $@";
}
my $PKG = 'PVE::Storage::Custom::TrueNASPlugin';
my $UUID = '11111111-2222-3333-4444-555555555555';
my $scfg = { tn_dataset => 'tank/pve', tn_transport_mode => 'nvme-tcp',
             tn_subsystem_nqn => 'nqn.x:y', tn_api_host => '198.51.100.7' };

{
    no strict 'refs'; no warnings 'redefine';
    *{"${PKG}::_log"} = sub { 1 };
}

# --- an existing idk21 volume parses and resolves ---------------------------
for my $vol ("vol-vm-9-cloudinit-ns$UUID") {
    my @p = $PKG->parse_volname($vol);
    is($p[1], 'vm-9-cloudinit', 'existing cloud-init volname: zname');
    is($p[2], 9, '  ...vmid');
    is($p[7], $UUID, '  ...embedded uuid');
    my ($dev) = $PKG->path($scfg, $vol, 's');
    is($dev, "/dev/disk/by-id/nvme-uuid.$UUID", '  ...path() resolves it by name alone');
}
{
    my @p = $PKG->parse_volname('vol-vm-9-cloudinit-lun4');
    is($p[7], 4, 'existing iSCSI cloud-init volname keeps its lun');
}

# --- a NEW one is created in the same form ---------------------------------
{
    no strict 'refs'; no warnings 'redefine';
    local *{"${PKG}::_nvme_ensure_subsystem"} = sub { 3 };
    local *{"${PKG}::_nvme_create_namespace_idempotent"} = sub { { device_uuid => $UUID, nsid => 1 } };
    local *{"${PKG}::_defer_after_lock"} = sub { 1 };
    my $vol = PVE::Storage::Custom::TrueNASPlugin::_alloc_image_nvme($PKG, $scfg, 'vm-9-cloudinit', 'tank/pve/vm-9-cloudinit', 'zvol/tank/pve/vm-9-cloudinit');
    is($vol, "vol-vm-9-cloudinit-ns$UUID", 'a new NVMe cloud-init disk keeps the embedded-uuid volname');
}

# --- listing shows the same volid (no duplicate unused after rescan) -------
{
    no strict 'refs'; no warnings 'redefine';
    local *{"${PKG}::_api_call"} = sub {
        my ($s, $m) = @_;
        return [ { id => 3, subnqn => 'nqn.x:y' } ] if $m eq 'nvmet.subsys.query';
        return [ { subsys => { id => 3 }, device_path => 'zvol/tank/pve/vm-9-cloudinit', device_uuid => $UUID } ]
            if $m eq 'nvmet.namespace.query';
        return [ { id => 'tank/pve/vm-9-cloudinit', volsize => { parsed => 4194304 } } ];
    };
    my $res = eval { PVE::Storage::Custom::TrueNASPlugin::_list_images_nvme($PKG, 's', $scfg, undef, undef, undef) };
    is($res && $res->[0]{volid}, "s:vol-vm-9-cloudinit-ns$UUID", 'list_images reports the idk21 volid') or diag($@);
}

done_testing;
