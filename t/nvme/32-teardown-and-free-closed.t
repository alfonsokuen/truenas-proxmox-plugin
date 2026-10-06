#!/usr/bin/perl
# Found against a real TrueNAS:
#  B1  _teardown_snapshot_device deleted the vzdump clone once, with no retry:
#      right after the extent/namespace is gone TrueNAS still holds the zvol and
#      answers EBUSY, the clone stayed behind, the CT kept lock: snapshot-delete
#      and the next vzdump failed - while the job said "finished successfully".
#  B2  free_image swallowed a failing pool.dataset.get_instance and skipped the
#      children check before a recursive+force delete (a child dataset was
#      destroyed with its parent).
#
# Run with:  prove -v t/nvme/32-teardown-and-free-closed.t
use strict;
use warnings;
use Test::More;
use FindBin;

my $PLUGIN = "$FindBin::Bin/../../TrueNASPlugin.pm";
unless (eval { require $PLUGIN; 1 }) {
    plan skip_all => "cannot load TrueNASPlugin.pm (needs PVE perl modules): $@";
}
my $PKG = 'PVE::Storage::Custom::TrueNASPlugin';
my $scfg = { tn_dataset => 'tank/pve', tn_api_host => '198.51.100.7', tn_transport_mode => 'nvme-tcp',
             tn_subsystem_nqn => 'nqn.x:y' };

my (@calls, %get, $delete_script);
{
    no strict 'refs'; no warnings 'redefine';
    *{"${PKG}::_log"} = sub { 1 };
    *CORE::GLOBAL::sleep = sub { 1 } if 0;
    *{"${PKG}::_nvme_delete_namespace"} = sub { 1 };
    *{"${PKG}::_defer_after_lock"} = sub { 1 };
    *{"${PKG}::_nvme_disconnect"} = sub { 1 };
    *{"${PKG}::run_command"} = sub { 1 };
    *{"${PKG}::_tn_dataset_get"} = sub {
        my ($s, $id) = @_;
        push @calls, "get:$id";
        die $get{$id}{die} if $get{$id} && $get{$id}{die};
        return $get{$id} ? $get{$id}{ret} : { id => $id };
    };
    *{"${PKG}::_api_call"} = sub {
        my ($s, $m, $p) = @_; push @calls, $m;
        return [ { id => 42, device_path => 'zvol/tank/pve/vm-101-disk-0' } ] if $m eq 'nvmet.namespace.query';
        return [] if $m eq 'nvmet.subsys.query';
        return { id => 1 };
    };
    *{"${PKG}::_api_call_mutate"} = sub {
        my ($s, $m, $p) = @_; push @calls, $m;
        if ($m eq 'pool.dataset.delete') {
            my $step = shift @$delete_script;
            die $step if defined $step && $step ne 'ok';
            return { deleted => 1 };
        }
        return 1;
    };
}
sub deletes { scalar grep { $_ eq 'pool.dataset.delete' } @calls }

# --- B1 --------------------------------------------------------------------
{
    @calls = (); $delete_script = [ "[EBUSY] dataset is busy\n", "[EBUSY] dataset is busy\n", 'ok' ];
    my $ok = eval { $PKG->_teardown_snapshot_device($scfg, 'vol-vm-101-disk-0-ns11111111-2222-3333-4444-555555555555', 's1'); 1 };
    ok($ok, 'B1: EBUSY twice then OK -> the teardown completes') or diag($@);
    is(deletes(), 3, '  ...after exactly three delete attempts');
}
{
    @calls = (); $delete_script = [ ("[EBUSY] dataset is busy\n") x 10 ];
    my @warns; local $SIG{__WARN__} = sub { push @warns, @_ };
    my $ok = eval { $PKG->_teardown_snapshot_device($scfg, 'vol-vm-101-disk-0-ns11111111-2222-3333-4444-555555555555', 's1'); 1 };
    ok(!$ok, 'B1: permanent EBUSY -> the teardown FAILS, it does not report success');
    like($@ // '', qr/busy|EBUSY/i, '  ...with the cause visible');
}
{
    @calls = (); $delete_script = [ "[ENOENT] dataset does not exist\n" ]; %get = ();
    $get{'tank/pve/pve-snapclone-vm-101-disk-0-s1'} = { die => "[ENOENT] does not exist\n" } if 0;
    local $PKG::dummy = 1;
    no strict 'refs'; no warnings 'redefine';
    local *{"${PKG}::_tn_dataset_get"} = sub { die "[ENOENT] dataset does not exist\n" };
    ok(eval { $PKG->_teardown_snapshot_device($scfg, 'vol-vm-101-disk-0-ns11111111-2222-3333-4444-555555555555', 's1'); 1 },
        'B1: an already-gone clone is still fine (idempotent)') or diag($@);
}

# --- B2 --------------------------------------------------------------------
my $free = $PKG->can('_free_image_nvme');
sub run_free {
    @calls = (); $delete_script = [ 'ok' ];
    my $ok = eval {
        my $w = $free->($PKG, 'store', $scfg, 'vol-vm-101-disk-0-lun1', 'vm-101-disk-0', 'tank/pve/vm-101-disk-0', undef);
        $w->('UPID:t') if ref($w) eq 'CODE';
        1;
    };
    return ($ok, $@);
}
{
    %get = ('tank/pve/vm-101-disk-0' => { die => "broker: read timeout after 30s\n" });
    my ($ok, $err) = run_free();
    ok(!$ok, 'B2: get_instance failing -> the free fails closed');
    is(deletes(), 0, '  ...and pool.dataset.delete was NEVER sent');
    like($err, qr/Refusing|cannot (?:read|verify)|Cannot/i, '  ...with a clear message');
}
{
    %get = ('tank/pve/vm-101-disk-0' => { ret => { id => 'x', children => [ { name => 'precious', type => 'FILESYSTEM' } ] } });
    my ($ok, $err) = run_free();
    ok(!$ok && deletes() == 0, 'B2: a dataset with a child is refused, nothing deleted');
    like($err, qr/child datasets: precious/, '  ...naming the child');
}
{
    %get = ('tank/pve/vm-101-disk-0' => { die => "[ENOENT] InstanceNotFound: does not exist\n" });
    my ($ok, $err) = run_free();
    ok($ok, 'B2: a dataset that is really gone still counts as already deleted') or diag($err);
}
{
    %get = ('tank/pve/vm-101-disk-0' => { die => "[-32601] Method does not exist\n" });
    my ($ok) = run_free();
    ok(!$ok && deletes() == 0, 'B2: a transport "Method does not exist" is not "already gone"');
}
# --- B3: iSCSI list_images fails closed on a non-list answer ---------------
{
    no strict 'refs'; no warnings 'redefine';
    my %ans;
    local *{"${PKG}::_api_call"} = sub { my ($s, $m) = @_; return $ans{$m} };
    local *{"${PKG}::_resolve_target_id"} = sub { 4 };
    my $l = sub { $PKG->can('_list_images_iscsi')->($PKG, 's', { tn_dataset => 'tank/pve', tn_api_host => 'h' }, undef, undef, {}) };
    %ans = ('iscsi.extent.query' => [], 'iscsi.targetextent.query' => [], 'pool.dataset.query' => []);
    my $r = eval { $l->() };
    ok($r && ref($r) eq 'ARRAY' && !@$r, 'B3: a real empty list is a legitimately empty storage');
    for my $case (['undef', undef], ['a hash', { x => 1 }]) {
        %ans = ('iscsi.extent.query' => $case->[1], 'iscsi.targetextent.query' => [], 'pool.dataset.query' => []);
        ok(!eval { $l->(); 1 } && $@ =~ /Cannot list s/, "B3: extent query answering $case->[0] -> list_images dies, not empty");
    }
    %ans = ('iscsi.extent.query' => [], 'iscsi.targetextent.query' => undef, 'pool.dataset.query' => []);
    ok(!eval { $l->(); 1 }, 'B3: targetextent query answering nothing -> dies');
}

done_testing;
