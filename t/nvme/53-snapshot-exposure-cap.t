#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use FindBin;

require "$FindBin::Bin/../../TrueNASPlugin.pm";
my $pkg = 'PVE::Storage::Custom::TrueNASPlugin';
my $uuid = '11111111-2222-3333-4444-555555555555';
my $vol = "vol-vm-100-disk-0-ns$uuid";
my $cfg = { tn_dataset => 'tank/pve', tn_transport_mode => 'nvme-tcp', tn_subsystem_nqn => 'nqn.2024-01.test:pve' };
my @calls;
my (@cap_result, $cap_error);
my $real_cap = $pkg->can('_nvme_cap_max_io');

no strict 'refs';
no warnings 'redefine';
local *{"${pkg}::_log"} = sub {};
local *{"${pkg}::_clone_snapshot_zvol"} = sub { push @calls, 'clone' };
local *{"${pkg}::_api_call"} = sub { [ { id => 1 } ] };
local *{"${pkg}::_nvme_create_namespace_idempotent"} = sub { { device_uuid => $uuid } };
local *{"${pkg}::_nvme_resync_configfs"} = sub {};
local *{"${pkg}::_nvme_connect"} = sub {};
local *{"${pkg}::_nvme_rescan_subsystem_controllers"} = sub {};
local *{"${pkg}::run_command"} = sub {};
local *{"${pkg}::_nvme_device_for_uuid"} = sub { push @calls, 'locate'; '/dev/nvme0n1' };
local *{"${pkg}::_teardown_snapshot_device"} = sub { push @calls, 'cleanup' };
local *{"${pkg}::_nvme_cap_max_io"} = sub {
    my ($scfg, $where, $dev) = @_;
    push @calls, "cap $where $dev";
    die $cap_error if $cap_error;
    return $real_cap->(@_) if exists($scfg->{tn_nvme_max_io_kb}) && !$scfg->{tn_nvme_max_io_kb};
    return @cap_result;
};

sub activate {
    my ($scfg, @queues) = @_;
    @calls = ();
    @cap_result = @queues;
    return eval { $pkg->activate_volume('store', $scfg, $vol, 'snap', {}); };
}

ok(!activate($cfg, 1, 1, 2), 'snapshot activation refuses an uncapped NVMe path');
like($@, qr/snap.*1 of 2.*MDTS/, 'snapshot cap failure identifies the snapshot and queue');
is_deeply(\@calls, ['clone', 'locate', 'cap activate /dev/nvme0n1', 'cleanup'],
    'failed cap triggers the existing snapshot clone cleanup');

ok(!activate($cfg, 0, 0, 0), 'default cap requires a visible queue for the snapshot');
like($@, qr{no queue/max_sectors_kb}, 'missing queue is reported');

$cap_error = "sysfs cap exploded\n";
ok(!activate($cfg), 'cap exception aborts snapshot activation');
like($@, qr/sysfs cap exploded/, 'cap exception reaches caller');
$cap_error = undef;

ok(activate($cfg, 0, 0, 2), 'an already capped snapshot is exposed');
is_deeply(\@calls, ['clone', 'locate', 'cap activate /dev/nvme0n1'], 'exposure checks the located snapshot device');
ok(activate({ %$cfg, tn_nvme_max_io_kb => 0 }), 'explicitly disabled cap permits snapshot exposure');
done_testing;
