#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use FindBin;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use JSON::PP qw(encode_json);

require "$FindBin::Bin/../../TrueNASPlugin.pm";
my $pkg = 'PVE::Storage::Custom::TrueNASPlugin';
my $uuid = '11111111-2222-3333-4444-555555555555';
my $other = '99999999-8888-7777-6666-555555555555';
my $nguid = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';
my $name = 'vm-101-disk-0';
my $vol = "vol-$name-ns$uuid";
my $ds = "tank/pve/$name";
my $scfg = { storeid => 'store', tn_dataset => 'tank/pve', tn_transport_mode => 'nvme-tcp',
    tn_subsystem_nqn => 'nqn.test' };
my $root = tempdir(CLEANUP => 1);
make_path("$root/nodes/local/qemu-server");
open(my $fh, '>', "$root/.vmlist") or die $!;
print {$fh} encode_json({ version => 1, ids => {} });
close($fh) or die $!;

no strict 'refs';
no warnings 'redefine', 'once';
${"${pkg}::_PRUNE_PVE_ROOT"} = $root;
$INC{'PVE/Cluster.pm'} = $INC{'PVE/INotify.pm'} = __FILE__;
*PVE::Cluster::check_cfs_quorum = sub { 1 };
*PVE::INotify::nodename = sub { 'local' };
local *{"${pkg}::_log"} = sub {};
local *{"${pkg}::_defer_after_lock"} = sub {};
# The delete worker takes the storage lock per attempt; no real cluster here.
local *{"${pkg}::cluster_lock_storage"} = sub { $_[4]->(@_[5 .. $#_]) };
local *{"${pkg}::_invalidate_status_capacity_cache"} = sub {};
local *{"${pkg}::_udev_settle_bounded"} = sub {};
local *{"${pkg}::_backoff_sleep"} = sub {};
local *{"${pkg}::_nvme_reap_orphan_namespaces"} = sub { 0 };
local *{"${pkg}::_nvme_find_pending_free_zvols"} = sub { [] };
local *{"${pkg}::_nvme_pending_free_mark"} = sub {};
local *{"${pkg}::_nvme_pending_free_clear_if_exported"} = sub {};
local *{"${pkg}::_handle_api_result_with_job_support"} = sub { { success => 1 } };

subtest 'C2: each free deletes only the generation it pinned before unpublishing' => sub {
    my ($dataset, @deleted, @unpublished);
    local *{"${pkg}::_tn_dataset_get"} = sub {
        die "[ENOENT] InstanceNotFound\n" unless $dataset;
        return $dataset;
    };
    local *{"${pkg}::_api_call_mutate"} = sub {
        die "unexpected mutation $_[1]" unless $_[1] eq 'pool.dataset.delete';
        push @deleted, $dataset->{guid}{rawvalue};
        undef $dataset;
        return 1;
    };
    local *{"${pkg}::_nvme_find_device_by_subsystem"} = sub {
        return { selector_outcome => 'publication_mismatch', enumeration_complete => 1 };
    };
    local *{"${pkg}::_nvme_delete_namespace"} = sub { push @unpublished, $_[1] };
    local *{"${pkg}::_api_call"} = sub { die "unexpected RPC $_[1]" };
    my $zvol = sub { { id => $ds, children => [], guid => { rawvalue => $_[0] } } };

    $dataset = $zvol->('101');
    my $worker_a = $pkg->free_image('store', $scfg, $vol, 0, 'raw');
    my $worker_b = $pkg->free_image('store', $scfg, $vol, 0, 'raw');
    $worker_a->('UPID:a');
    $dataset = $zvol->('202');    # the allocator reuses the name
    eval { $worker_b->('UPID:b') };
    is_deeply(\@deleted, ['101'], 'worker_A_deleted=101 and worker_B sends no delete for guid 202');
    ok($dataset, 'the replacement zvol survives');

    @deleted = @unpublished = ();
    $dataset = { id => $ds, children => [] };
    ok(!eval { $pkg->free_image('store', $scfg, $vol, 0, 'raw'); 1 },
        'an identity that cannot be read stops the free');
    like($@, qr/Cannot verify ZFS identity/, 'and says why');
    is_deeply(\@unpublished, [], 'the namespace is still exported (checked before unpublishing)');
};

subtest 'HIGH: a head whose UUID contradicts the request never wins by NGUID' => sub {
    my $select = $pkg->can('_nvme_select_namespace_device');
    my @devices = (
        { name => 'nvme0c0n1', path => '/dev/nvme0c0n1', type => 'controller', uuid => $uuid, nguid => $nguid, nsid => 9 },
        { name => 'nvme0c1n1', path => '/dev/nvme0c1n1', type => 'controller', uuid => $uuid, nguid => $nguid, nsid => 9 },
        { name => 'nvme0n1', path => '/dev/nvme0n1', type => 'standard', uuid => $other, nguid => $nguid, nsid => 9 },
    );
    my $result = $select->($scfg, $uuid, \@devices, { api_namespace_count => 1, metadata_state => 'ok',
        namespace => { device_uuid => $uuid, device_nguid => $nguid, nsid => 9 } });
    is($pkg->can('_nvme_selector_selected_device_path')->($result), undef, 'no device is selected');
    is($result->{mismatch_reason}, 'identity_contradiction', 'the contradiction is named');
    ok(!eval { $pkg->can('_nvme_free_local_device')->($vol, $result, ''); 1 },
        'a free consulting this answer fails closed');
};

subtest 'HIGH: an export the first lookups missed is checked for use before its delete' => sub {
    my ($queries, $busy_checks, @ns_deletes) = (0, 0);
    my $row = { id => 10, device_path => 'zvol/tank/pve/vm-101-cloudinit', device_uuid => $other };
    local *{"${pkg}::_get_cached"} = sub { undef };
    local *{"${pkg}::_set_cache"} = sub {};
    local *{"${pkg}::_assert_no_child_datasets"} = sub { undef };
    local *{"${pkg}::_api_call"} = sub {
        my (undef, $method, $args) = @_;
        if ($method eq 'nvmet.namespace.delete') { push @ns_deletes, $args->[0]; return 1 }
        die "unexpected RPC $method" unless $method eq 'nvmet.namespace.query';
        # The filtered query misses it and the full listing shows only another
        # zvol (two empty answers are no longer absence), then the delete sees it.
        ++$queries;
        return $queries == 1 ? [] : $queries == 2
            ? [{ id => 3, device_path => 'zvol/tank/pve/vm-200-disk-0', device_uuid => $uuid }] : [$row];
    };
    local *{"${pkg}::_nvme_find_device_by_subsystem"} = sub {
        return { selector_outcome => 'exact_match', selected_device_path => '/dev/nvme0n5' };
    };
    local *{"${pkg}::_nvme_check_devices_in_use"} = sub { ++$busy_checks; 1 };
    ok(!eval { $pkg->free_image('store', $scfg, 'vm-101-cloudinit', 0, 'raw'); 1 }, 'the free refuses');
    like($@, qr/still in use/, 'because the late export is in use');
    cmp_ok($busy_checks, '>=', 1, 'busy_checks >= 1');
    is_deeply(\@ns_deletes, [], 'namespace_deletes=0');
};

subtest 'M2: an empty full listing with a known UUID is not absence' => sub {
    my $path = "zvol/$ds";
    my $filtered = [];
    local *{"${pkg}::_api_call"} = sub {
        my (undef, $method, $args) = @_;
        die "unexpected RPC $method" unless $method eq 'nvmet.namespace.query';
        return $args && $args->[0] && @{ $args->[0] } ? $filtered : [];
    };
    my $confirm = $pkg->can('_nvme_confirm_namespaces_for_path');
    ok(!eval { $confirm->($scfg, $path, $uuid); 1 }, 'known UUID + empty full listing fails closed');
    like($@, qr/full listing is empty.*zvol in place/s, 'with a clear message');
    $filtered = [{ id => 7, device_path => $path }];
    ok(!eval { $confirm->($scfg, $path, undef); 1 }, 'a row from the path query + empty full listing fails closed');
    $filtered = [];
    # r6: two empty answers prove nothing either; absence needs a non-empty
    # listing without the path or the zvol answering ENOENT.
    ok(!eval { $confirm->($scfg, $path, undef); 1 }, 'nothing known and nothing listed fails closed');
    like($@, qr/both empty/, 'and says the two empty answers are not proof');
};

subtest 'HIGH: overlapping activations of one snapshot cannot tear down a live export' => sub {
    my (%cluster_lock, $inner_ok, @teardowns, $calls);
    local *{"${pkg}::cluster_lock_storage"} = sub {
        my (undef, $storeid, undef, undef, $func, @param) = @_;
        die "can't lock storage '$storeid': got timeout\n" if $cluster_lock{$storeid};
        local $cluster_lock{$storeid} = 1;
        local ${"${pkg}::_storage_lock_held"}{$storeid} = 1;
        return $func->(@param);
    };
    local *{"${pkg}::_clone_snapshot_zvol"} = sub { $calls++ == 0 ? 1 : 0 };
    local *{"${pkg}::_api_call"} = sub { [{ id => 1 }] };
    local *{"${pkg}::_nvme_create_namespace_idempotent"} = sub {
        my (undef, undef, $created) = @_;
        $$created = { id => 5, device_uuid => $uuid } if $calls == 1;
        return { id => 5, device_uuid => $uuid };
    };
    local *{"${pkg}::_nvme_resync_configfs"} = sub {};
    local *{"${pkg}::_nvme_connect"} = sub {};
    local *{"${pkg}::_nvme_rescan_subsystem_controllers"} = sub { 1 };
    local *{"${pkg}::run_command"} = sub {};
    local *{"${pkg}::_nvme_device_for_uuid"} = sub { '/dev/nvme0n9' };
    my $depth = 0;
    local *{"${pkg}::_nvme_require_request_size_cap"} = sub {
        return if $depth++;
        # Backup B starts in another process while A has not finished.
        local %{"${pkg}::_storage_lock_held"} = ();
        $inner_ok = eval { $pkg->activate_volume('store', $scfg, $vol, 'vzdump'); 1 };
        die "cap failed for A\n";
    };
    local *{"${pkg}::_teardown_snapshot_device"} = sub { push @teardowns, 'ns+clone' };
    ok(!eval { $pkg->activate_volume('store', $scfg, $vol, 'vzdump'); 1 }, 'activation A fails at its cap');
    ok(!($inner_ok && @teardowns), 'never: B reported success and A then removed the export B uses')
        or diag "inner_success=" . ($inner_ok // 0) . ' teardowns=' . scalar(@teardowns);
};

subtest 'MEDIUM: a resize that rescans no controller reports an error' => sub {
    local *{"${pkg}::cluster_lock_storage"} = sub { $_[4]->() };
    local *{"${pkg}::_tn_dataset_get"} = sub { { volsize => 1024, volblocksize => 512 } };
    local *{"${pkg}::_api_call"} = sub { {} };
    local *{"${pkg}::_api_call_mutate"} = sub { {} };
    local *{"${pkg}::_nvme_rescan_subsystem_controllers"} = sub { 0 };
    local *{"${pkg}::_nvme_rescan_controller_fallback"} = sub { 0 };
    local *{"${pkg}::run_command"} = sub {};
    ok(!eval { $pkg->volume_resize($scfg, 'store', $vol, 2048); 1 }, 'controllers=0 is not a successful resize');
    like($@, qr/no NVMe controller rescanned/, 'the error says the host may see the old size');
};

done_testing;
