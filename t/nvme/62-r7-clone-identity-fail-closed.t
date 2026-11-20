#!/usr/bin/perl
# idk31 r7 (rev4-astra, regression of round 6): an ordinary iSCSI
# deactivate_volume of the vzdump clone pins generation 101, then re-reads it
# right before retiring the export. When that second read fails (transport),
# the iSCSI path used to swallow it as a warning and go on to the recursive
# delete: 0 mapping and 0 extent retirements but 1 pool.dataset.delete of a
# clone that was still exported. It must fail closed instead: no mapping, no
# extent and no dataset delete; the clone stays as it is.
use strict;
use warnings;
use Test::More;
use FindBin;

require "$FindBin::Bin/../../TrueNASPlugin.pm";
my $pkg = 'PVE::Storage::Custom::TrueNASPlugin';
my $vol = 'vol-vm-101-disk-0-lun3';
my $scfg = { storeid => 'store', tn_dataset => 'tank/pve', tn_transport_mode => 'iscsi',
    tn_target_iqn => 'iqn.test' };
my (undef, $clone) = $pkg->can('_snapshot_clone_paths')->($scfg, 'vm-101-disk-0', 'vzdump');

# The array: the clone generation, the scripted outcome of each identity read,
# and every destructive call.
my ($guid, @reads, @mapping_deletes, @extent_deletes, @ds_deletes, @errors);

no strict 'refs';
no warnings 'redefine', 'once';
local $SIG{__WARN__} = sub {};
local *{"${pkg}::_log"} = sub { push @errors, $_[3] if ($_[2] // '') eq 'err' };
local *{"${pkg}::_clear_cache"} = sub {};
local *{"${pkg}::_invalidate_status_capacity_cache"} = sub {};
local *{"${pkg}::_udev_settle_bounded"} = sub {};
local *{"${pkg}::_backoff_sleep"} = sub {};
local *{"${pkg}::_handle_api_result_with_job_support"} = sub { { success => 1 } };
local *{"${pkg}::_resolve_target_id"} = sub { 7 };
local *{"${pkg}::_resolve_extent_by_disk"} = sub { defined $guid ? { id => 5 } : undef };
local *{"${pkg}::_current_lun_for_zname"} = sub { undef };
local *{"${pkg}::_tn_targetextent_query_by_target_extent"} = sub { [{ id => 9 }] };
local *{"${pkg}::_tn_dataset_get"} = sub {
    my (undef, $id) = @_;
    die "unexpected dataset $id" if $id ne $clone;
    my $script = shift(@reads) // 'ok';
    die "[EFAULT] connection reset by peer while reading $id\n" if $script eq 'fail';
    die "[ENOENT] InstanceNotFound\n" if !defined $guid;
    return { id => $clone, guid => { rawvalue => $guid } };
};
local *{"${pkg}::_api_call"} = sub {
    my (undef, $method, $args) = @_;
    if ($method eq 'iscsi.targetextent.delete') { push @mapping_deletes, $args->[0]; return 1 }
    if ($method eq 'iscsi.extent.delete') { push @extent_deletes, $args->[0]; return 1 }
    die "unexpected RPC $method";
};
local *{"${pkg}::_api_call_mutate"} = sub {
    die "unexpected mutation $_[1]" unless $_[1] eq 'pool.dataset.delete';
    push @ds_deletes, $guid // 'absent';
    undef $guid;
    return 1;
};

sub reset_array {
    ($guid, @reads) = @_;
    @mapping_deletes = @extent_deletes = @ds_deletes = @errors = ();
}
my $deactivate = sub { $pkg->deactivate_volume('store', $scfg, $vol, 'vzdump') };

subtest 'the second identity read fails: nothing is retired, nothing deleted' => sub {
    # Read 1 pins 101, read 2 (right before the export goes) fails, any later
    # read would see 101 again and let a delete through.
    reset_array('101', 'ok', 'fail');
    ok($deactivate->(), 'deactivate_volume stays best-effort for PVE');
    is_deeply(\@mapping_deletes, [], 'zero mapping retirements');
    is_deeply(\@extent_deletes, [], 'zero extent retirements');
    is_deeply(\@ds_deletes, [], 'zero recursive deletes of the still-exported clone');
    is($guid, '101', 'clone 101 survives with its export');
    ok((grep { /teardown FAILED.*\Q$clone\E.*cannot re-read the generation/ } @errors),
        'the failure is logged at error level with the clone name');
};

subtest 'control: a stable generation is still torn down completely' => sub {
    reset_array('101');
    ok($deactivate->(), 'deactivate_volume returns');
    is_deeply(\@mapping_deletes, [9], 'its mapping is retired');
    is_deeply(\@extent_deletes, [5], 'its extent is retired');
    is_deeply(\@ds_deletes, ['101'], 'exactly generation 101 is deleted');
    is_deeply(\@errors, [], 'and nothing is logged as a failure');
};

subtest 'control: the first read failing still stops before any change' => sub {
    reset_array('101', 'fail');
    ok($deactivate->(), 'deactivate_volume returns');
    is_deeply([\@mapping_deletes, \@extent_deletes, \@ds_deletes], [[], [], []],
        'no retirement and no delete');
};

done_testing;
