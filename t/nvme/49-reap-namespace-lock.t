#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use FindBin;

require "$FindBin::Bin/../../TrueNASPlugin.pm";
my $pkg = 'PVE::Storage::Custom::TrueNASPlugin';
my $reap = $pkg->can('_nvme_reap_orphan_namespaces');
my $scfg = { storeid => 'store', tn_dataset => 'tank/pve', tn_subsystem_nqn => 'nqn.test' };
my $orphan = { id => 7, device_path => 'zvol/tank/pve/vm-101-disk-0', device_uuid => 'testuuid', nsid => 8 };
my ($locked, $lock_error, $fresh, @events);
{
    no strict 'refs'; no warnings 'redefine', 'once';
    *PVE::Storage::config = sub { {} };
    *PVE::Storage::storage_config = sub { $scfg };
    *PVE::Storage::Plugin::cluster_lock_storage = sub {
        my (undef, $id, $shared, undef, $cb) = @_;
        die 'recursive lock' if $locked;
        die 'wrong lock' unless $id eq 'store' && $shared;
        push @events, 'lock';
        die "no quorum\n" if $lock_error;
        $locked = 1;
        my ($result, $err);
        eval { $result = $cb->(); 1 } or $err = $@;
        $locked = 0;
        die $err if $err;
        return $result;
    };
    *{"${pkg}::_log"} = sub {};
    *{"${pkg}::_tn_dataset_get"} = sub { die "[ENOENT] InstanceNotFound\n" };
    *{"${pkg}::_api_call"} = sub {
        my (undef, $method, $args) = @_;
        return [{ id => 23 }] if $method eq 'nvmet.subsys.query';
        return [{ id => 'tank/pve/live' }] if $method eq 'pool.dataset.query';
        if ($method eq 'nvmet.namespace.query') {
            my @filters = @{$args->[0]};
            return [$orphan] unless grep { $_->[0] eq 'id' && $_->[2] == 7 } @filters;
            push @events, 'reread';
            return $fresh;
        }
        if ($method eq 'nvmet.namespace.delete') {
            push @events, $locked ? 'delete_locked' : 'delete_unlocked';
            return 1;
        }
        die "unexpected RPC $method";
    };
}

$fresh = [{ %$orphan, device_path => 'zvol/tank/pve/base-101-disk-0' }];
is($reap->($scfg), 0, '#9 keeps an orphan candidate whose path changed');
is_deeply(\@events, [qw(lock reread)], '#9 rereads the candidate under the storage lock');

$fresh = [$orphan];
@events = ();
is($reap->($scfg), 1, '#9 equivalent fresh record still gets reaped');
is_deeply(\@events, [qw(lock reread delete_locked)], '#9 performs deletion while holding the storage lock');

@events = ();
is($pkg->cluster_lock_storage('store', 1, undef, sub { $reap->($scfg) }), 1,
    '#9 can run from an existing storage lock without reacquiring it');
is_deeply(\@events, [qw(lock reread delete_locked)], '#9 uses the existing lock');

@events = ();
$lock_error = 1;
ok(!eval { $reap->($scfg); 1 }, '#9 cannot sweep when the lock fails');
is_deeply(\@events, ['lock'], '#9 no read-delete sequence when the lock fails');

done_testing;
