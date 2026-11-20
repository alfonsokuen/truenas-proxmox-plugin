#!/usr/bin/perl
# idk31 r6 (rev3-astra B10, C12/C13, C14):
#  5   the vzdump clone teardown re-reads the clone generation right before it
#      retires the export and before the delete: a clone that appeared after
#      an initial ENOENT, or whose generation changed, keeps its export and
#      dataset.
#  6   a failed snapshot activation rolls back only what it created, and only
#      when it created the clone: an export it only reused is left alone, and
#      on a pre-existing clone nothing is retired, not even a namespace this
#      activation added (r7, rev4-astra C14: an idk26 node, which takes no
#      lock, may already read through it). A pre-existing clone is never
#      deleted.
use strict;
use warnings;
use Test::More;
use FindBin;

require "$FindBin::Bin/../../TrueNASPlugin.pm";
my $pkg = 'PVE::Storage::Custom::TrueNASPlugin';
my $uuid = '11111111-2222-3333-4444-555555555555';
my $name = 'vm-101-disk-0';
my $vol = "vol-$name-ns$uuid";
my $scfg = { storeid => 'store', tn_dataset => 'tank/pve', tn_transport_mode => 'nvme-tcp',
    tn_subsystem_nqn => 'nqn.test' };
my (undef, $clone) = $pkg->can('_snapshot_clone_paths')->($scfg, $name, 'vzdump');

# The array: the clone dataset (its guid, or undef when absent), its
# namespaces, and every destructive call made against them.
my ($guid, @ns, @ns_deletes, @ds_deletes, $after_identity_read, $cap_fails_for);

no strict 'refs';
no warnings 'redefine', 'once';
local $SIG{__WARN__} = sub {};
local *{"${pkg}::_log"} = sub {};
local *{"${pkg}::_invalidate_status_capacity_cache"} = sub {};
local *{"${pkg}::_udev_settle_bounded"} = sub {};
local *{"${pkg}::_backoff_sleep"} = sub {};
local *{"${pkg}::_handle_api_result_with_job_support"} = sub { { success => 1 } };
local *{"${pkg}::_tn_dataset_get"} = sub {
    my (undef, $id) = @_;
    die "unexpected dataset $id" if $id ne $clone;
    my $answer = defined($guid) ? { id => $clone, guid => { rawvalue => $guid } } : undef;
    # Another activation lands between this read and what follows it.
    if (my $hook = $after_identity_read) { undef $after_identity_read; $hook->() }
    die "[ENOENT] InstanceNotFound\n" if !$answer;
    return $answer;
};
local *{"${pkg}::_nvme_confirm_namespaces_for_path"} = sub { [map { +{ %$_ } } @ns] };
local *{"${pkg}::_api_call"} = sub {
    my (undef, $method, $args) = @_;
    return [{ id => 1 }] if $method eq 'nvmet.subsys.query';
    if ($method eq 'nvmet.namespace.delete') {
        push @ns_deletes, $args->[0];
        @ns = grep { $_->{id} != $args->[0] } @ns;
        return 1;
    }
    die "unexpected RPC $method";
};
local *{"${pkg}::_api_call_mutate"} = sub {
    die "unexpected mutation $_[1]" unless $_[1] eq 'pool.dataset.delete';
    push @ds_deletes, $guid // 'absent';
    undef $guid;
    return 1;
};

sub reset_array { ($guid, @ns) = @_; @ns_deletes = @ds_deletes = (); undef $after_identity_read }
sub ns_row { { id => $_[0], device_path => "zvol/$clone", device_uuid => $_[1] // $uuid } }
my $deactivate = sub { $pkg->deactivate_volume('store', $scfg, $vol, 'vzdump') };

subtest 'point 5: an initial ENOENT never adopts a clone that appears later' => sub {
    reset_array(undef);
    $after_identity_read = sub { $guid = '202'; @ns = (ns_row(22)) };
    $deactivate->();
    is_deeply(\@ns_deletes, [], 'namespace 22 of clone 202 is not retired');
    is_deeply(\@ds_deletes, [], 'and clone 202 is not deleted');
    is($guid, '202', 'clone 202 survives');
};

subtest 'point 5: a pinned 101 that became 202 keeps its export' => sub {
    reset_array('101', ns_row(21));
    $after_identity_read = sub { $guid = '202'; @ns = (ns_row(22)) };
    $deactivate->();
    is_deeply(\@ns_deletes, [], 'namespace 22 of clone 202 is not retired');
    is_deeply(\@ds_deletes, [], 'and nothing is deleted');
};

subtest 'point 5 controls: same generation torn down, absent clone idempotent' => sub {
    reset_array('101', ns_row(21));
    $deactivate->();
    is_deeply(\@ns_deletes, [21], 'the pinned clone loses its namespace');
    is_deeply(\@ds_deletes, ['101'], 'and exactly its dataset is deleted');

    reset_array(undef);
    ok(eval { $pkg->_teardown_snapshot_device($scfg, $vol, 'vzdump'); 1 },
        'an absent clone from start to end is still a successful no-op') or diag $@;
    is_deeply([\@ns_deletes, \@ds_deletes], [[], []], 'with no retirement and no delete');
};

# Two participants, each holding the storage lock for its whole activation
# (as activate_volume does): B has exported the clone and is reading it.
my %lock;
local *{"${pkg}::cluster_lock_storage"} = sub {
    my (undef, $storeid, undef, undef, $func, @param) = @_;
    die "lock '$storeid' re-entered by a second participant\n" if $lock{$storeid};
    local $lock{$storeid} = 1;
    local ${"${pkg}::_storage_lock_held"}{$storeid} = 1;
    return $func->(@param);
};
local *{"${pkg}::_clone_snapshot_zvol"} = sub {
    return 0 if defined $guid;
    $guid = '101';
    return 1;
};
my $next_ns = 30;
local *{"${pkg}::_nvme_create_namespace_idempotent"} = sub {
    my (undef, undef, $created) = @_;
    return { %{ $ns[0] } } if @ns;
    push @ns, ns_row($next_ns++);
    $$created = { %{ $ns[-1] } } if $created;
    return { %{ $ns[-1] } };
};
local *{"${pkg}::_nvme_resync_configfs"} = sub {};
local *{"${pkg}::_nvme_connect"} = sub {};
local *{"${pkg}::_nvme_rescan_subsystem_controllers"} = sub { 1 };
local *{"${pkg}::run_command"} = sub {};
local *{"${pkg}::_nvme_device_for_uuid"} = sub { '/dev/nvme0n9' };
local *{"${pkg}::_nvme_require_request_size_cap"} = sub {
    die "cap failed for $cap_fails_for\n" if $cap_fails_for;
};
my $activate = sub { $pkg->activate_volume('store', $scfg, $vol, 'vzdump') };

subtest 'point 6: a participant that reused the export rolls back nothing' => sub {
    reset_array(undef);
    undef $cap_fails_for;
    ok(eval { $activate->(); 1 }, 'B creates the clone and its namespace') or diag $@;
    is_deeply([$guid, scalar(@ns)], ['101', 1], 'B is using clone 101 through one namespace');
    @ns_deletes = @ds_deletes = ();
    $cap_fails_for = 'A';
    ok(!eval { $activate->(); 1 }, 'A reuses both and fails at its cap');
    is_deeply(\@ns_deletes, [], 'zero namespace retirements');
    is_deeply(\@ds_deletes, [], 'zero clone deletes: B keeps reading');
};

subtest 'point 6 / C14 (r7): on a pre-existing clone the rollback retires nothing' => sub {
    reset_array('101');
    $cap_fails_for = 'A';
    my $first = $next_ns;
    # A adds a namespace to the clone that was already there; an idk26 node
    # (no lock) finds that namespace and starts reading; then A's cap fails.
    ok(!eval { $activate->(); 1 }, 'A creates a namespace on the existing clone and fails');
    is_deeply(\@ns_deletes, [], 'zero namespace retirements, even of the one A created');
    is_deeply(\@ds_deletes, [], 'the pre-existing clone is not deleted');
    is_deeply([$guid, map { $_->{id} } @ns], ['101', $first],
        'clone 101 and the namespace the other reader uses survive (a safe leak)');
    @ns_deletes = @ds_deletes = ();
    $deactivate->();
    is_deeply([\@ns_deletes, \@ds_deletes], [[$first], ['101']],
        'the next ordinary teardown still retires that namespace and deletes the clone');
};

subtest 'point 6 control: a clone the failed activation created is still rolled back' => sub {
    reset_array(undef);
    $cap_fails_for = 'A';
    my $first = $next_ns;
    ok(!eval { $activate->(); 1 }, 'A creates clone and namespace and fails');
    is_deeply(\@ns_deletes, [$first], 'its namespace is retired');
    is_deeply(\@ds_deletes, ['101'], 'and the clone it created is deleted');
};

done_testing;
