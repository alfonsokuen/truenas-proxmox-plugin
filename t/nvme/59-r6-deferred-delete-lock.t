#!/usr/bin/perl
# r6 B1: the deferred zvol delete of an NVMe free is serialized with the
# storage lock, so an overlapping worker of the same free can never delete
# a generation the allocator created under the same name (rev3-astra
# B08/B09). Plus coverage of the pinned identity in
# _delete_dataset_with_retry (B09) and of the owner moving to another node
# before the worker runs (B03-worker).
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
my $name = 'vm-101-disk-0';
my $vol = "vol-$name-ns$uuid";
my $ds = "tank/pve/$name";
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
guest_index();

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
local *{"${pkg}::_nvme_reap_orphan_namespaces"} = sub { 0 };
local *{"${pkg}::_nvme_find_pending_free_zvols"} = sub { [] };
local *{"${pkg}::_nvme_pending_free_mark"} = sub {};
local *{"${pkg}::_nvme_pending_free_clear_if_exported"} = sub {};
local *{"${pkg}::_handle_api_result_with_job_support"} = sub { { success => 1 } };
local *{"${pkg}::_nvme_find_device_by_subsystem"} = sub {
    return { selector_outcome => 'publication_mismatch', enumeration_complete => 1 };
};
local *{"${pkg}::_nvme_delete_namespace"} = sub {};
local *{"${pkg}::_api_call"} = sub { die "unexpected RPC $_[1]" };

# One zvol on the array, by name; every pool.dataset.delete is counted by the
# generation (guid) it actually destroyed.
my ($dataset, @deleted, $on_identity_read);
our $on_backoff;
my $zvol = sub { { id => $ds, children => [], guid => { rawvalue => $_[0] } } };
local *{"${pkg}::_tn_dataset_get"} = sub {
    my (undef, undef, $opts) = @_;
    my $answer = $dataset;
    # Fire a hook on an identity read (the only caller passing properties),
    # after the answer was taken: the caller has read the generation and is
    # about to act on it.
    if ($opts && $on_identity_read) {
        my $hook = $on_identity_read;
        undef $on_identity_read;
        $hook->();
    }
    die "[ENOENT] InstanceNotFound\n" unless $answer;
    return $answer;
};
local *{"${pkg}::_api_call_mutate"} = sub {
    die "unexpected mutation $_[1]" unless $_[1] eq 'pool.dataset.delete';
    die "[ENOENT] InstanceNotFound\n" unless $dataset;
    push @deleted, $dataset->{guid}{rawvalue};
    undef $dataset;
    return 1;
};
local *{"${pkg}::_backoff_sleep"} = sub { $on_backoff->() if $on_backoff };

# The cluster storage lock as real mutual exclusion inside one process. A
# second process that needs it while it is held waits and runs when it is
# released; a request that bypassed that queue while the lock is held means
# the model broke, and dies loudly.
our $lock_holder;
my (@lock_waiters, @lock_log);
local *{"${pkg}::cluster_lock_storage"} = sub {
    my (undef, $storeid, undef, undef, $func, @param) = @_;
    die "lock model: '$storeid' requested by a process that is not queued\n" if $lock_holder;
    my $result;
    {
        local $lock_holder = 1;
        local ${"${pkg}::_storage_lock_held"}{$storeid} = 1;
        push @lock_log, 'acquire';
        $result = $func->(@param);
        push @lock_log, 'release';
    }
    while (my $next = shift @lock_waiters) { $next->() }
    return $result;
};
# Start another process. It cannot act before getting the storage lock (its
# first mutating step is under it in r6), so while the lock is held it waits.
my $spawn = sub {
    my ($process) = @_;
    return push(@lock_waiters, $process) if $lock_holder;
    $process->();
};
# PVE allocates under the same storage lock.
my $allocate = sub {
    my ($guid) = @_;
    $pkg->cluster_lock_storage('store', 1, undef, sub { $dataset //= $zvol->($guid) });
};

subtest 'B08/B09: overlapping workers of one free delete only the pinned generation' => sub {
    @deleted = @lock_log = ();
    $dataset = $zvol->('101');
    my $worker_a = $pkg->free_image('store', $scfg, $vol, 0, 'raw');
    my $worker_b = $pkg->free_image('store', $scfg, $vol, 0, 'raw');
    is(ref($worker_a) . ref($worker_b), 'CODECODE', 'both frees pinned guid 101 and returned a worker');

    # B reads guid 101 and is about to delete by name when A starts: A deletes
    # 101, then the allocator reuses the name for guid 202.
    my $a_err;
    $on_identity_read = sub {
        $spawn->(sub {
            $a_err = $@ unless eval { $worker_a->('UPID:a'); 1 };
            $allocate->('202');
        });
    };
    my $b_ok = eval { $worker_b->('UPID:b'); 1 };
    my $b_err = $@;
    ok(!$on_identity_read, 'the overlap was really triggered from inside B');
    is_deeply(\@lock_waiters, [], 'every waiter ran');
    is_deeply(\@deleted, ['101'], 'deletes=[101]: no pool.dataset.delete reaches guid 202')
        or diag "deletes=[@deleted]";
    is($dataset && $dataset->{guid}{rawvalue}, '202', 'the zvol the allocator created survives');
    ok($b_ok, 'worker B completes') or diag $b_err;
    ok(!$a_err, 'worker A finds its generation gone and completes') or diag $a_err;
    cmp_ok(scalar(grep { $_ eq 'acquire' } @lock_log), '>=', 3,
        'each worker attempt and the allocation took the storage lock');
};

subtest 'B09: _delete_dataset_with_retry never adopts another generation' => sub {
    my $delete = $pkg->can('_delete_dataset_with_retry');
    for my $serialized (0, 1) {
        my $tag = $serialized ? 'under the storage lock' : 'without a serializer';
        my %opts = (verify_gone => 1, identity => [guid => '101']);
        $opts{serialize} = sub { $pkg->cluster_lock_storage('store', 1, undef, $_[0]) } if $serialized;

        # The name is reused just before the delete: guid 202 is not ours.
        @deleted = ();
        $dataset = $zvol->('101');
        eval { $delete->($scfg, $ds, undef, { %opts, before_delete => sub { $dataset = $zvol->('202') } }) };
        is($@, '', "pinned 101, name now 202: returns ($tag)");
        is_deeply(\@deleted, [], "deletes=[] and guid 202 survives ($tag)");

        # A masked success, then 101 vanishes and the name is reused (303)
        # while the retry backs off.
        @deleted = ();
        $dataset = $zvol->('101');
        my $masked = 0;
        local *{"${pkg}::_api_call_mutate"} = sub {
            push @deleted, $dataset->{guid}{rawvalue};
            $masked++;
            return 1;    # reported success, 101 still there
        };
        local $on_backoff = sub { $dataset = $zvol->('303') };
        eval { $delete->($scfg, $ds, undef, \%opts) };
        is($@, '', "masked success then reuse: returns ($tag)");
        is_deeply(\@deleted, ['101'], "deletes=[101], none of 303 ($tag)");
        is($dataset->{guid}{rawvalue}, '303', "guid 303 survives ($tag)");
    }
};

subtest 'B03-worker: an owner that moved to another node blocks the deferred delete' => sub {
    @deleted = ();
    $dataset = $zvol->('101');
    guest_index(101 => { node => 'local', type => 'qemu' });
    put('nodes/local/qemu-server/101.conf', "scsi0: store:$vol\n");
    my $worker = eval { $pkg->free_image('store', $scfg, $vol, 0, 'raw') };
    is(ref($worker), 'CODE', 'the local owner may free its own disk') or diag $@;

    # Before the worker runs the owner migrates (or another node takes the
    # disk back) and its config there still references the volume.
    unlink("$root/nodes/local/qemu-server/101.conf");
    guest_index(101 => { node => 'remote', type => 'qemu' });
    put('nodes/remote/qemu-server/101.conf', "scsi0: store:$vol,discard=on\n");
    ok(!eval { $worker->('UPID:w'); 1 }, 'the worker refuses');
    like($@, qr/101.*remote/s, 'naming the remote owner');
    is_deeply(\@deleted, [], 'deletes=[]: the dataset is intact');
    ok($dataset, 'guid 101 is still on the array');
    guest_index();
};

done_testing;
