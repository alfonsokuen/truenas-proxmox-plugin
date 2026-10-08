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
        my $g = $get{$id} // $get{'*'};    # '*' = answer for any other dataset
        die $g->{die} if $g && $g->{die};
        return $g ? $g->{ret} : { id => $id };
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
    # The clone teardown now reads the dataset back after an API "success"
    # (TN 26.0 BETA.36 can answer success with the zvol still live): the array
    # must answer ENOENT for the clone, or the delete is not believed.
    %get = ('*' => { die => "[ENOENT] InstanceNotFound: does not exist\n" });
    @calls = (); $delete_script = [ "[EBUSY] dataset is busy\n", "[EBUSY] dataset is busy\n", 'ok' ];
    my $ok = eval { $PKG->_teardown_snapshot_device($scfg, 'vol-vm-101-disk-0-ns11111111-2222-3333-4444-555555555555', 's1'); 1 };
    ok($ok, 'B1: EBUSY twice then OK -> the teardown completes') or diag($@);
    is(deletes(), 3, '  ...after exactly three delete attempts');
}
{
    # B1b: the array says "deleted" but the zvol is still live (masked EBUSY):
    # that is a failed teardown, not a success. Seen on TN 26.0 BETA.36.
    %get = ();    # default answer: the dataset exists
    @calls = (); $delete_script = [ ('ok') x 5 ];
    local $SIG{__WARN__} = sub { };
    my $ok = eval { $PKG->_teardown_snapshot_device($scfg, 'vol-vm-101-disk-0-ns11111111-2222-3333-4444-555555555555', 's1'); 1 };
    ok(!$ok, 'B1b: delete reported success but the clone is still there -> the teardown FAILS');
    like($@ // '', qr/masked EBUSY|still finds/, '  ...saying the delete was not real');
    %get = ('*' => { die => "[ENOENT] InstanceNotFound: does not exist\n" });
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

# --- G4: callers that swallow a teardown failure still say WHICH clone -------
{
    no strict 'refs'; no warnings 'redefine';
    my @logs;
    local *{"${PKG}::_log"} = sub { my ($sc, $lvl, $kind, $msg) = @_; push @logs, "$lvl/$kind $msg" };
    local *{"${PKG}::_teardown_snapshot_device"} = sub { die "dataset is busy\n" };
    local $SIG{__WARN__} = sub { };
    my $vol = 'vol-vm-101-disk-0-ns11111111-2222-3333-4444-555555555555';
    ok(eval { $PKG->deactivate_volume('s', $scfg, $vol, 'snap1', {}); 1 }, 'G4: deactivate_volume still does not die');
    my ($line) = grep { m{^0/err} } @logs;
    ok($line, '  ...and logs at ERROR level 0');
    like($line // '', qr/vmid=101/, '  ...with the guest');
    like($line // '', qr{tank/pve/vzdump-vm-101-disk-0-snap1}i, '  ...and the exact orphaned clone dataset');
    like($line // '', qr/\Q$vol\E/, '  ...and the volume');
}

done_testing;
