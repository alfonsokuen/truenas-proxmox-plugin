#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use FindBin;

require "$FindBin::Bin/../../TrueNASPlugin.pm";
my $pkg = 'PVE::Storage::Custom::TrueNASPlugin';
my $uuid = '11111111-2222-3333-4444-555555555555';
my $vol = "vol-vm-101-disk-0-ns$uuid";
my $ds = 'tank/pve/vm-101-disk-0';
my $scfg = { tn_dataset => 'tank/pve', tn_transport_mode => 'nvme-tcp', tn_subsystem_nqn => 'nqn.test' };
my ($child_error, $marker_error, $namespace_error, $namespace_answer, $worker_error, $datasets, @events);
my $property = 'org.truenas-pve:pending-free';
my $marker;

{
    no strict 'refs'; no warnings 'redefine';
    *{"${pkg}::_log"} = sub {};
    *{"${pkg}::_defer_after_lock"} = sub {};
    *{"${pkg}::_assert_nvme_cluster_unreferenced"} = sub {};
    *{"${pkg}::_nvme_find_device_by_subsystem"} = sub {
        return { selector_outcome => 'publication_mismatch', enumeration_complete => 1 };
    };
    *{"${pkg}::_assert_no_child_datasets"} = sub {
        push @events, 'check_children';
        die $child_error if $child_error;
        return 1;
    };
    *{"${pkg}::_nvme_delete_namespace"} = sub {
        push @events, 'delete_namespace';
        die $namespace_error if $namespace_error;
    };
    *{"${pkg}::_api_call_mutate"} = sub {
        my (undef, $method, $args) = @_;
        die "unexpected mutation $method" unless $method eq 'pool.dataset.update' && $args->[0] eq $ds;
        my $change = $args->[1]{user_properties_update}[0];
        die 'unexpected property' if ($change->{key} // '') ne $property;
        push @events, $change->{remove} ? 'clear_pending' : 'mark_pending';
        die $marker_error if $marker_error;
        $marker = $change->{remove} ? undef : $change->{value};
        return { id => $ds };
    };
    *{"${pkg}::_api_call"} = sub {
        return $datasets if $_[1] eq 'pool.dataset.query';
        die "unexpected read $_[1]" if $_[1] ne 'nvmet.namespace.query';
        return $namespace_answer;
    };
    *{"${pkg}::_delete_dataset_with_retry"} = sub {
        push @events, $_[3] && $_[3]{verify_gone} ? 'verified_delete' : 'unverified_delete';
        die $worker_error if $worker_error;
    };
}

sub free_volume {
    @events = ();
    $marker = undef;
    return $pkg->free_image('store', $scfg, $vol, 0, 'raw');
}

$child_error = "has child datasets\n";
ok(!eval { free_volume(); 1 }, '#3 child check aborts the free');
is_deeply(\@events, ['check_children'], '#3 child failure leaves the namespace intact');
$child_error = undef;

$marker_error = "broker: read timeout\n";
ok(!eval { free_volume(); 1 }, '#3 unknown marker update aborts the free');
is_deeply(\@events, [qw(check_children mark_pending)], '#3 timeout leaves namespace intact');
$marker_error = undef;

my $worker = free_volume();
is_deeply(\@events, [qw(check_children mark_pending delete_namespace)], '#3 validate and mark before unpublishing');
like($marker // '', qr/^\d+:store:\Q$vol\E$/, '#3 persistent marker identifies the original volume');
$worker_error = "EBUSY\n";
ok(!eval { $worker->('UPID:test'); 1 }, '#3 dataset worker reports failure');
like($@, qr/\Q$property\E.*\Q$ds\E|\Q$ds\E.*\Q$property\E/s, '#3 recovery message identifies zvol and marker');
is($events[-1], 'verified_delete', '#3 worker requests explicit verification');
ok(defined $marker, '#3 failure preserves marker for manual recovery');

$namespace_error = "Permission denied\n";
$namespace_answer = [{ id => 22, device_path => "zvol/$ds" }];
ok(!eval { free_volume(); 1 }, '#3 denied namespace delete aborts');
is($events[-1], 'clear_pending', '#3 confirmed export clears a stale marker');
$namespace_answer = undef;
ok(!eval { free_volume(); 1 }, '#3 uncertain export state also aborts');
ok(defined $marker, '#3 uncertain export state keeps the marker');

my $old = int(time()) - 901;
my $recent = int(time()) - 10;
$datasets = [
    { id => $ds, user_properties => { $property => { value => "$old:store:$vol", source => 'LOCAL' } } },
    { id => 'tank/pve/still-exported', user_properties => { $property => { value => "$old:store:$vol", source => 'LOCAL' } } },
    { id => 'tank/pve/recent', user_properties => { $property => { value => "$recent:store:$vol", source => 'LOCAL' } } },
    { id => 'tank/pve/unmarked' },
];
my $find = sub { $pkg->can('_nvme_find_pending_free_zvols')->($scfg, 'store') };
$namespace_answer = [{ device_path => 'zvol/tank/pve/still-exported' }];
my $found = eval { $find->() };
is_deeply($found, [$ds], '#3 discovery reports only old markers without an export');
$namespace_answer = undef;
$found = eval { $find->() };
is_deeply($found, [], '#3 discovery reports nothing from an uncertain namespace query');

done_testing;
