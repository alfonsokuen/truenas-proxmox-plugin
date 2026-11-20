#!/usr/bin/perl
# r6 guards of _free_image_nvme: a UUID found late is checked against the
# cluster, local use is probed right before each namespace delete, and two
# empty namespace answers are not proof that nothing is exported.
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
my $scfg = { storeid => 'store', tn_dataset => 'tank/pve', tn_transport_mode => 'nvme-tcp',
    tn_subsystem_nqn => 'nqn.test' };
my $root = tempdir(CLEANUP => 1);
make_path("$root/nodes/local/qemu-server", "$root/nodes/remote/qemu-server");

sub put {
    my ($path, $text) = @_;
    open(my $fh, '>', "$root/$path") or die $!;
    print {$fh} $text;
    close($fh) or die $!;
}
sub guest_index { put('.vmlist', encode_json({ version => 1, ids => {@_} })) }

no strict 'refs';
no warnings 'redefine', 'once';
${"${pkg}::_PRUNE_PVE_ROOT"} = $root;
$INC{'PVE/Cluster.pm'} = $INC{'PVE/INotify.pm'} = __FILE__;
*PVE::Cluster::check_cfs_quorum = sub { 1 };
*PVE::INotify::nodename = sub { 'local' };
local *{"${pkg}::_log"} = sub {};
local *{"${pkg}::_defer_after_lock"} = sub {};
local *{"${pkg}::_invalidate_status_capacity_cache"} = sub {};
local *{"${pkg}::_udev_settle_bounded"} = sub {};
local *{"${pkg}::_backoff_sleep"} = sub {};
local *{"${pkg}::_nvme_reap_orphan_namespaces"} = sub { 0 };
local *{"${pkg}::_nvme_find_pending_free_zvols"} = sub { [] };
local *{"${pkg}::_nvme_pending_free_mark"} = sub {};
local *{"${pkg}::_nvme_pending_free_clear_if_exported"} = sub {};
local *{"${pkg}::_handle_api_result_with_job_support"} = sub { { success => 1 } };
local *{"${pkg}::_get_cached"} = sub { undef };
local *{"${pkg}::_set_cache"} = sub {};

# One simulated array: a zvol (by GUID) and the namespace query answers in
# order (the last answer repeats). Counts every dangerous call.
my ($dataset, @answers, @ns_deletes, @ds_deletes, $probes);
local *{"${pkg}::_tn_dataset_get"} = sub {
    die "[ENOENT] InstanceNotFound\n" unless $dataset;
    return { %$dataset, id => $_[1] };
};
local *{"${pkg}::_api_call_mutate"} = sub {
    die "unexpected mutation $_[1]" unless $_[1] eq 'pool.dataset.delete';
    push @ds_deletes, $dataset->{guid}{rawvalue};
    undef $dataset;
    return 1;
};
local *{"${pkg}::_api_call"} = sub {
    my (undef, $method, $args) = @_;
    if ($method eq 'nvmet.namespace.delete') { push @ns_deletes, $args->[0]; return 1 }
    die "unexpected RPC $method" unless $method eq 'nvmet.namespace.query';
    return @answers > 1 ? shift(@answers) : $answers[0];
};
sub reset_array {
    my ($guid, @ans) = @_;
    $dataset = defined($guid) ? { id => 'x', children => [], guid => { rawvalue => $guid } } : undef;
    @answers = @ans;
    @ns_deletes = @ds_deletes = ();
    $probes = 0;
}
# Run the free and, if it hands back the deferred worker, that too.
sub free_all {
    my ($volname) = @_;
    my $worker = $pkg->free_image('store', $scfg, $volname, 0, 'raw');
    $worker->('UPID:test') if ref($worker) eq 'CODE';
    return 1;
}

my $ci = 'vm-100-cloudinit';
my $ci_path = 'zvol/tank/pve/vm-100-cloudinit';
my $unrelated = { id => 3, device_path => 'zvol/tank/pve/vm-200-disk-0', device_uuid => $other };

subtest 'point 3: a UUID found late is checked against a remote owner naming it by-id' => sub {
    local *{"${pkg}::_nvme_find_device_by_subsystem"} = sub {
        return { selector_outcome => 'publication_mismatch', enumeration_complete => 1 };
    };
    local *{"${pkg}::_nvme_check_devices_in_use"} = sub { ++$probes; 0 };
    guest_index(100 => { node => 'remote', type => 'qemu' });
    put('nodes/remote/qemu-server/100.conf', "name: owner\nide2: /dev/disk/by-id/nvme-uuid.$uuid,media=cdrom\n");
    # Filtered query empty, full listing non-empty without the path (proven
    # absence, so point 8 does not mask this), then the delete's own query sees it.
    reset_array('101', [], [$unrelated], [{ id => 10, device_path => $ci_path, device_uuid => $uuid }]);
    ok(!eval { free_all($ci); 1 }, 'the free refuses');
    like($@, qr/referenced by guest 100 on node 'remote'/, 'because the remote owner names the late UUID');
    is_deeply(\@ns_deletes, [], 'namespace_deletes=[]');
    is_deeply(\@ds_deletes, [], 'dataset_deletes=[]');
    guest_index();
};

subtest 'point 4: local use is probed again right before the namespace delete' => sub {
    my $vol = "vol-vm-101-disk-0-ns$uuid";
    my $lookups = 0;
    local *{"${pkg}::_nvme_find_device_by_subsystem"} = sub {
        # First enumeration: no device. Then the device shows up.
        return { selector_outcome => 'publication_mismatch', enumeration_complete => 1 } if !$lookups++;
        return { selector_outcome => 'exact_match', selected_device_path => '/dev/nvme0n5' };
    };
    local *{"${pkg}::_nvme_check_devices_in_use"} = sub { ++$probes; 1 };
    reset_array('101', [{ id => 10, device_path => 'zvol/tank/pve/vm-101-disk-0', device_uuid => $uuid }]);
    ok(!eval { free_all($vol); 1 }, 'the free refuses');
    like($@, qr/still in use/, 'because the device that appeared is busy');
    cmp_ok($probes, '>=', 1, 'busy probes >= 1');
    is_deeply(\@ns_deletes, [], 'namespace_deletes=[]');
    is_deeply(\@ds_deletes, [], 'dataset_deletes=[]');
};

subtest 'point 8: two empty namespace answers are not absence' => sub {
    local *{"${pkg}::_nvme_find_device_by_subsystem"} = sub {
        return { selector_outcome => 'publication_mismatch', enumeration_complete => 1 };
    };
    local *{"${pkg}::_nvme_check_devices_in_use"} = sub { ++$probes; 0 };
    reset_array('101', []);
    ok(!eval { free_all($ci); 1 }, 'unknown UUID with [] + [] refuses the free');
    like($@, qr/both empty/, 'and says the answers prove nothing');
    is_deeply(\@ns_deletes, [], 'namespace_deletes=[]');
    is_deeply(\@ds_deletes, [], 'dataset_deletes=[]');

    reset_array('101', [], [$unrelated]);
    ok(eval { free_all($ci); 1 }, 'control: a non-empty listing without the path frees the unexported cloud-init')
        or diag $@;
    is_deeply(\@ns_deletes, [], 'nothing was exported, nothing unpublished');
    is_deeply(\@ds_deletes, ['101'], 'and its zvol is deleted once');

    my $confirm = $pkg->can('_nvme_confirm_namespaces_for_path');
    reset_array(undef, []);
    is_deeply($confirm->($scfg, $ci_path, undef), [], '[] + [] with the zvol answering ENOENT is absence');
    reset_array('101', []);
    ok(!eval { $confirm->($scfg, $ci_path, undef); 1 }, '[] + [] with the zvol present fails closed');
};

done_testing;
