#!/usr/bin/perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib";
use Test::More;
use File::Temp qw(tempdir);
use IDK::TestNVMeSysfs qw(nvme_fixture);

require "$FindBin::Bin/../../TrueNASPlugin.pm";
my $pkg = 'PVE::Storage::Custom::TrueNASPlugin';
my $selector = $pkg->can('_nvme_find_device_by_subsystem');
my $select = $pkg->can('_nvme_select_namespace_device');
my $nqn = 'nqn.2011-06.com.truenas:uuid:test:pve';
my $uuid = '11111111-2222-3333-4444-555555555555';
my $nguid = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';
my $cfg = { tn_subsystem_nqn => $nqn };
my $root = tempdir(CLEANUP => 1);

no strict 'refs';
no warnings 'redefine', 'once';
local ${"${pkg}::_NVME_SYSFS"} = $root;
local *{"${pkg}::_log"} = sub { 1 };
local *{"${pkg}::_nvme_get_namespace_selector_metadata"} = sub {
    return { namespace => { device_uuid => $uuid, device_nguid => $nguid, nsid => 9 },
        api_namespace_count => 1, metadata_state => 'ok' };
};

subtest '03: controller NQN lives directly under device' => sub {
    nvme_fixture($root, 'nvme0n1', $nqn, nsid => 9, uuid => $uuid, nguid => $nguid, dev => '259:0');
    nvme_fixture($root, 'nvme0c0n1', $nqn, nsid => 9, uuid => $uuid, nguid => $nguid);
    nvme_fixture($root, 'nvme0c1n1', $nqn, nsid => 9, uuid => $uuid, nguid => $nguid);
    ok(-f "$root/block/nvme0c0n1/device/subsysnqn", 'controller carries NQN');
    ok(!-e "$root/block/nvme0c0n1/device/../subsysnqn", 'controller parent has no NQN');
    my $result = $selector->($cfg, $uuid);
    is($result->{selector_outcome}, 'exact_match', 'real controller layout does not fail enumeration');
    is($result->{linux_device_count}, 3, 'the head and both paths are enumerated');
    my @paths = $pkg->can('_nvme_get_subsystem_device_paths')->($cfg, strict => 1);
    is_deeply([sort @paths], [qw(/dev/nvme0c0n1 /dev/nvme0c1n1 /dev/nvme0n1)],
        'the in-use device enumerator also identifies both paths');
};

subtest '04: exact identities select the usable multipath head' => sub {
    my @devices = (
        { name => 'nvme0c0n1', path => '/dev/nvme0c0n1', type => 'controller', uuid => $uuid, nguid => $nguid, nsid => 9 },
        { name => 'nvme0n1', path => '/dev/nvme0n1', type => 'standard', uuid => $uuid, nguid => $nguid, nsid => 9 },
    );
    for my $tier (qw(nguid uuid)) {
        my $ns = { nsid => 9, device_uuid => $uuid };
        $ns->{device_nguid} = $nguid if $tier eq 'nguid';
        my $result = $select->($cfg, $uuid, \@devices,
            { namespace => $ns, api_namespace_count => 1, metadata_state => 'ok' });
        is($result->{match_tier}, $tier, "matched by $tier");
        is($result->{selected_device_path}, '/dev/nvme0n1', 'returned the block device');
    }
    delete $devices[1]{nguid};
    my $result = $select->($cfg, $uuid, \@devices, {
        namespace => { device_uuid => $uuid, device_nguid => $nguid, nsid => 9 },
        api_namespace_count => 1, metadata_state => 'ok',
    });
    is($result->{selected_device_path}, '/dev/nvme0n1',
        'a controller matched by NGUID defers to its head with the same UUID');
    $devices[1]{nguid} = $nguid;
    delete $devices[1]{uuid};
    $result = $select->($cfg, $uuid, \@devices, {
        namespace => { device_uuid => $uuid, nsid => 9 },
        api_namespace_count => 1, metadata_state => 'ok',
    });
    is($result->{selected_device_path}, '/dev/nvme0n1',
        'a controller matched by UUID defers to its head with the same NGUID');
    is($selector->($cfg, $uuid)->{selected_device_path}, '/dev/nvme0n1',
        'full sysfs selector also returns the head');
};

done_testing;
