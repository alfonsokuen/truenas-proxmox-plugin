#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use FindBin;

require "$FindBin::Bin/../../TrueNASPlugin.pm";
my $pkg = 'PVE::Storage::Custom::TrueNASPlugin';
my $uuid = '11111111-2222-3333-4444-555555555555';
my $name = 'vm-101-disk-0';
my $vol = "vol-$name-ns$uuid";
my $ds = "tank/pve/$name";
my $cfg = { storeid => 'store', tn_dataset => 'tank/pve', tn_transport_mode => 'nvme-tcp',
    tn_subsystem_nqn => 'nqn.test' };

no strict 'refs';
no warnings 'redefine', 'once';
local *{"${pkg}::_log"} = sub {};
local *{"${pkg}::_invalidate_status_capacity_cache"} = sub {};

subtest '1 verified deletes are pinned to dataset identity' => sub {
    my ($dataset, $after_delete, @deletes);
    local *{"${pkg}::_tn_dataset_get"} = sub {
        die "[ENOENT] InstanceNotFound\n" unless $dataset;
        return $dataset;
    };
    local *{"${pkg}::_api_call_mutate"} = sub {
        die "unexpected mutation $_[1]" unless $_[1] eq 'pool.dataset.delete';
        push @deletes, $dataset;
        $dataset = $after_delete->();
        return 1;
    };
    local *{"${pkg}::_handle_api_result_with_job_support"} = sub { { success => 1 } };
    local *{"${pkg}::_backoff_sleep"} = sub {};
    my $delete = sub { eval { $pkg->can('_delete_dataset_with_retry')->($cfg, $ds, 3, { verify_gone => 1 }); 1 } };
    for my $property (qw(guid createtxg)) {
        @deletes = ();
        my $old = { id => $ds, $property => { rawvalue => '54321' } };
        $dataset = $old;
        $after_delete = sub { @deletes == 1 ? { id => $ds, $property => { rawvalue => '54322' } } : undef };
        ok($delete->(), "$property identifies the old zvol as gone");
        is_deeply(\@deletes, [$old], "$property: never delete the replacement");
        @deletes = ();
        $dataset = $old;
        $after_delete = sub { @deletes == 1 ? $old : undef };
        ok($delete->(), "$property: masked success may be retried on the same zvol") or diag $@;
        is_deeply(\@deletes, [$old, $old], "$property: exactly two deletes of the original");
    }
    @deletes = ();
    $dataset = { id => $ds };
    $after_delete = sub { undef };
    ok(!$delete->(), 'unavailable identity fails closed');
    is(scalar(@deletes), 0, 'unavailable identity sends no force delete');
};

subtest '6 path query gaps cannot hide a live namespace' => sub {
    my $path = "zvol/$ds";
    my $row = { id => 42, device_path => $path, device_uuid => $uuid };
    my ($full_list, @deletes);
    local *{"${pkg}::_api_call"} = sub {
        my (undef, $method, $args) = @_;
        if ($method eq 'nvmet.namespace.delete') { push @deletes, $args->[0]; return 1 }
        die "unexpected RPC $method" if $method ne 'nvmet.namespace.query';
        return [] if $args && $args->[0] && @{$args->[0]};
        return $full_list;
    };
    local *{"${pkg}::_get_cached"} = sub { undef };
    local *{"${pkg}::_set_cache"} = sub {};
    my $delete = $pkg->can('_nvme_delete_namespace');
    my $resolve = $pkg->can('_resolve_nvme_uuid');
    $full_list = [$row];
    $delete->($cfg, $name, $ds, $uuid);
    is_deeply(\@deletes, [42], 'independent listing locates and removes the export');
    is(eval { $resolve->($cfg, $name, undef) }, $uuid, 'independent listing resolves UUID on the cloud-init path');

    $full_list = undef;
    @deletes = ();
    ok(!eval { $delete->($cfg, $name, $ds, $uuid); 1 }, 'missing confirmation blocks the free before zvol deletion');
    is_deeply(\@deletes, [], 'missing confirmation sends zero namespace deletes');
    ok(!eval { $resolve->($cfg, $name, undef); 1 }, 'UUID resolution also refuses an inconclusive read');
    unlike($@, qr/^Could not locate NVMe namespace/, 'inconclusive UUID resolution is not a proven absence');

    {
        my $dataset_deletes = 0;
        local *{"${pkg}::_assert_nvme_cluster_unreferenced"} = sub {};
        local *{"${pkg}::_assert_no_child_datasets"} = sub { { id => $ds, guid => 12 } };
        local *{"${pkg}::_read_dataset_delete_identity"} = sub { return (guid => '12') };
        local *{"${pkg}::_nvme_pending_free_mark"} = sub {};
        local *{"${pkg}::_nvme_find_device_by_subsystem"} = sub {
            return { selector_outcome => 'publication_mismatch', enumeration_complete => 1 };
        };
        local *{"${pkg}::_delete_dataset_with_retry"} = sub { ++$dataset_deletes };
        my $worker = eval { $pkg->free_image('store', $cfg, $vol, 0, 'raw') };
        like($@, qr/refusing to destroy.*namespace/s, 'free reports inconclusive unpublication');
        $worker->('UPID:test') if ref($worker) eq 'CODE';
        is($dataset_deletes, 0, 'inconclusive namespace listing sends zero dataset deletes');
    }

    $full_list = [{ %$row, device_path => "zvol/$ds-renamed" }];
    ok(!eval { $delete->($cfg, $name, $ds, $uuid); 1 }, 'same UUID at another path invalidates the requested free');
    is_deeply(\@deletes, [], 'renamed export gets no namespace delete');
};

subtest '8 failed snapshot exposure preserves an earlier backup' => sub {
    my ($exists, $fail_cap, @deletes);
    local *{"${pkg}::_api_call_mutate"} = sub {
        die "unexpected mutation $_[1]" unless $_[1] eq 'pool.snapshot.clone';
        die "dataset already exists\n" if $exists;
        $exists = 1;
        return { id => $_[2][0]{dataset_dst} };
    };
    local *{"${pkg}::cluster_lock_storage"} = sub { $_[4]->(@_[5 .. $#_]) };
    local *{"${pkg}::_api_call"} = sub { [{ id => 1 }] };
    local *{"${pkg}::_nvme_create_namespace_idempotent"} = sub { { id => 42, device_uuid => $uuid } };
    local *{"${pkg}::_nvme_resync_configfs"} = sub {};
    local *{"${pkg}::_nvme_connect"} = sub {};
    local *{"${pkg}::_nvme_rescan_subsystem_controllers"} = sub {};
    local *{"${pkg}::_nvme_device_for_uuid"} = sub { '/dev/nvme0n1' };
    local *{"${pkg}::_nvme_require_request_size_cap"} = sub { die "MDTS failure\n" if $fail_cap };
    local *{"${pkg}::_nvme_delete_namespace"} = sub { push @deletes, 'namespace' };
    local *{"${pkg}::_delete_dataset_with_retry"} = sub { push @deletes, 'dataset' };
    local *{"${pkg}::run_command"} = sub {};

    is($pkg->activate_volume('store', $cfg, $vol, 'snap', {}), 1, 'first backup gets its device');
    $fail_cap = 1;
    ok(!eval { $pkg->activate_volume('store', $cfg, $vol, 'snap', {}); 1 }, 'second backup fails closed on the cap');
    like($@, qr/MDTS failure/, 'original failure is retained');
    is_deeply(\@deletes, [], 'zero deletes of the earlier backup clone or namespace');
};

subtest '13 free returns before reaper and pending-free reads' => sub {
    my (@after_lock, @calls);
    local *{"${pkg}::_defer_after_lock"} = sub { push @after_lock, $_[0] };
    local *{"${pkg}::_assert_nvme_cluster_unreferenced"} = sub {};
    local *{"${pkg}::_assert_no_child_datasets"} = sub { { id => $ds, guid => 12 } };
    local *{"${pkg}::_nvme_pending_free_mark"} = sub {};
    local *{"${pkg}::_nvme_find_device_by_subsystem"} = sub {
        return { selector_outcome => 'publication_mismatch', enumeration_complete => 1 };
    };
    local *{"${pkg}::_nvme_delete_namespace"} = sub {};
    local *{"${pkg}::_read_dataset_delete_identity"} = sub { return (guid => '12') };
    local *{"${pkg}::_nvme_reap_orphan_namespaces"} = sub { push @calls, 'reaper'; return 0 };
    local *{"${pkg}::_delete_dataset_with_retry"} = sub {};
    local *{"${pkg}::run_command"} = sub {};
    local *{"${pkg}::_api_call"} = sub {
        my (undef, $method, $params) = @_;
        die "unexpected RPC $method" unless $method eq 'pool.dataset.query';
        push @calls, $params->[1]{select} // 'unprojected query';
        return [];
    };

    my $worker = $pkg->free_image('store', $cfg, $vol, 0, 'raw');
    $_->() for @after_lock;
    is_deeply(\@calls, [], 'post-lock work on the caller does not reap or query pending-free datasets');
    @calls = ();
    $worker->('UPID:test');
    is_deeply(\@calls, ['reaper', ['id', 'user_properties']], 'only the worker runs maintenance with a projected dataset query');
};

subtest '16 release notes describe the implemented behavior and version' => sub {
    my $read = sub {
        open(my $fh, '<', "$FindBin::Bin/../../$_[0]") or die $!;
        return do { local $/; <$fh> };
    };
    my ($release) = split(/\n -- /, $read->('debian/changelog'), 2);
    like($release, qr/mountinfo[^.]+fuser/s, 'idk31 entry names the mount and open-device probes');
    unlike($release, qr/sin depender de fuser/, 'changelog reflects the actual fuser dependency');
    like($read->('README.md'), qr/(?:10.second|10 seconds).{0,330}(?:fallback|falls back)/s,
        '#144 describes the upstream timer and immediate fallback');
    like($read->('DIVERGENCE-IDK.md'), qr/Version del arbol: `1:2\.1\.25~beta2\+idk31`/,
        'divergence document names the checked-out release');
};

done_testing;
