#!/usr/bin/perl
# idk31 r5 (MATRIZ B14, B10):
#  B14  two namespaces for one zvol: the free deleted both, also the one whose
#       UUID another volume name still points at.
#  B10  the vzdump clone teardown read the ZFS identity only after it had
#       unpublished the clone; an unreadable identity left it unexported.
use strict;
use warnings;
use Test::More;
use FindBin;

require "$FindBin::Bin/../../TrueNASPlugin.pm";
my $pkg = 'PVE::Storage::Custom::TrueNASPlugin';
my $uuid = '11111111-2222-3333-4444-555555555555';
my $other = '99999999-8888-7777-6666-555555555555';
my $name = 'vm-101-disk-0';
my $vol = "vol-$name-ns$uuid";
my $ds = "tank/pve/$name";
my $scfg = { storeid => 'store', tn_dataset => 'tank/pve', tn_transport_mode => 'nvme-tcp',
    tn_subsystem_nqn => 'nqn.test' };

no strict 'refs';
no warnings 'redefine', 'once';
local *{"${pkg}::_log"} = sub {};
local *{"${pkg}::_invalidate_status_capacity_cache"} = sub {};
local *{"${pkg}::_udev_settle_bounded"} = sub {};
local *{"${pkg}::_backoff_sleep"} = sub {};
local *{"${pkg}::_handle_api_result_with_job_support"} = sub { { success => 1 } };

subtest 'B14: two namespaces for one zvol are never deleted' => sub {
    my ($rows, @deletes);
    local *{"${pkg}::_api_call"} = sub {
        my (undef, $method, $args) = @_;
        if ($method eq 'nvmet.namespace.delete') { push @deletes, $args->[0]; return 1 }
        die "unexpected RPC $method" if $method ne 'nvmet.namespace.query';
        return $rows;
    };
    my $delete = $pkg->can('_nvme_delete_namespace');
    my $row = sub { { id => $_[0], device_path => "zvol/$ds", device_uuid => $_[1] } };

    $rows = [$row->(10, $uuid), $row->(11, $other)];
    ok(!eval { $delete->($scfg, $name, $ds, $uuid); 1 }, 'rows 10/11 with distinct UUIDs stop the free');
    like($@, qr/2 namespaces/, 'and the error names the duplicate');
    is_deeply(\@deletes, [], 'zero namespace deletes');

    @deletes = ();
    ok(!eval { $delete->($scfg, $name, $ds, undef); 1 }, 'an unknown UUID with two rows also stops');
    is_deeply(\@deletes, [], 'zero namespace deletes without a UUID either');

    @deletes = ();
    $rows = [$row->(10, $uuid), $row->(11, $uuid)];
    ok(!eval { $delete->($scfg, $name, $ds, $uuid); 1 }, 'two rows with the same UUID stop the free');
    is_deeply(\@deletes, [], 'zero namespace deletes for a same-UUID duplicate');

    @deletes = ();
    $rows = [$row->(10, $uuid)];
    ok(eval { $delete->($scfg, $name, $ds, $uuid); 1 }, 'a single matching namespace is still freed') or diag $@;
    is_deeply(\@deletes, [10], 'exactly that namespace is deleted');
};

subtest 'B10: the clone teardown pins its identity before unpublishing' => sub {
    my ($dataset, @events);
    my $clone = 'tank/pve/' . $pkg->can('_snapshot_clone_zname')->($scfg, $name, 'vzdump');
    local *{"${pkg}::_tn_dataset_get"} = sub {
        my (undef, $id) = @_;
        die "unexpected dataset $id" if $id ne $clone;
        push @events, 'identity';
        die "[ENOENT] InstanceNotFound\n" unless $dataset;
        die $dataset if !ref($dataset);
        return $dataset;
    };
    local *{"${pkg}::_nvme_delete_namespace"} = sub { push @events, 'unpublish' };
    local *{"${pkg}::_api_call_mutate"} = sub {
        die "unexpected mutation $_[1]" unless $_[1] eq 'pool.dataset.delete';
        push @events, 'delete';
        undef $dataset;
        return 1;
    };
    my $teardown = sub { $pkg->_teardown_snapshot_device($scfg, $vol, 'vzdump') };

    $dataset = { id => $clone, guid => { rawvalue => '101' } };
    ok(eval { $teardown->(); 1 }, 'a readable clone is torn down') or diag $@;
    is($events[0], 'identity', 'the identity is read before anything else');
    is_deeply([grep { $_ ne 'identity' } @events], ['unpublish', 'delete'], 'then unpublish, then delete');

    @events = ();
    $dataset = { id => $clone };
    ok(!eval { $teardown->(); 1 }, 'an identity without guid or createtxg stops the teardown');
    like($@, qr/Cannot verify ZFS identity/, 'and says why');
    is_deeply(\@events, ['identity'], 'the export stays and nothing is deleted');

    @events = ();
    $dataset = "[EACCES] permission denied\n";
    ok(!eval { $teardown->(); 1 }, 'a failing identity read stops the teardown');
    is_deeply(\@events, ['identity'], 'still exported, zero deletes');

    @events = ();
    undef $dataset;
    ok(eval { $teardown->(); 1 }, 'an already-gone clone is still idempotent') or diag $@;
    ok(!grep({ $_ eq 'delete' } @events), 'and sends no delete');
};

done_testing;
