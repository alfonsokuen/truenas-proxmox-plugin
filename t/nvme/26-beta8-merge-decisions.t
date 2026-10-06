#!/usr/bin/perl
# Decisions taken when upstream 2.1.23~beta8 was merged into the fork, pinned so
# a later merge cannot silently flip them.
#
#  1. Orphan recovery after an EEXIST rename (upstream code) must fail CLOSED:
#     if the linked-clone query errors, the recursive+force delete must not run.
#  2. A "does not exist" from a dataset delete is only success if the array
#     confirms the dataset is gone.
#  3. The CFS storage lock stays ON by default (upstream bypasses it).
#  4. tn_use_cluster_lock is declared with a title and default 1; the upstream
#     name for the allow_any_host policy is an alias of ours.
#
# Run with:  prove -v t/nvme/26-beta8-merge-decisions.t

use strict;
use warnings;
use Test::More;
use FindBin;

my $PLUGIN = "$FindBin::Bin/../../TrueNASPlugin.pm";
unless (eval { require $PLUGIN; 1 }) {
    plan skip_all => "cannot load TrueNASPlugin.pm (needs PVE perl modules): $@";
}
my $PKG = 'PVE::Storage::Custom::TrueNASPlugin';
my $scfg = { tn_dataset => 'tank/pve', tn_api_host => '198.51.100.7' };

my (@calls, %reply, %die_on);
{
    no strict 'refs';
    no warnings 'redefine';
    *{"${PKG}::_log"} = sub { 1 };
    *{"${PKG}::_api_call"} = sub {
        my ($s, $method, $params) = @_;
        my $key = $method;
        $key .= ':clones' if $method eq 'pool.dataset.query'
            && ref($params) && ref($params->[0]) && ref($params->[0][0])
            && $params->[0][0][0] eq 'origin.parsed';
        push @calls, $key;
        die $die_on{$key} if exists $die_on{$key};
        return $reply{$key};
    };
    *{"${PKG}::_api_call_mutate"} = sub { push @calls, $_[1]; return 1 };
}
my $orphan = $PKG->can('_dataset_orphan_check_and_delete');
ok($orphan, '_dataset_orphan_check_and_delete exists');

# --- 1. fail closed on a failing clone query (red before the merge fix) ----
@calls = (); %reply = ('pool.dataset.query' => [ { id => 'tank/pve/base-1-disk-0', children => [] } ]);
%die_on = ('pool.dataset.query:clones' => "[EFAULT] boom\n");
is($orphan->($scfg, 'tank/pve/base-1-disk-0'), 0, 'clone query error: orphan recovery refuses');
ok(!(grep { $_ eq 'pool.dataset.delete' } @calls), '  ...and pool.dataset.delete was never sent');

# the other direction: a clean empty answer still deletes
@calls = (); %die_on = (); $reply{'pool.dataset.query:clones'} = [];
is($orphan->($scfg, 'tank/pve/base-1-disk-0'), 1, 'no clones: orphan is deleted');
ok((grep { $_ eq 'pool.dataset.delete' } @calls), '  ...pool.dataset.delete was sent');
@calls = (); $reply{'pool.dataset.query:clones'} = [ { id => 'tank/pve/vm-9-disk-0' } ];
is($orphan->($scfg, 'tank/pve/base-1-disk-0'), 0, 'live clone: refuses');
ok(!(grep { $_ eq 'pool.dataset.delete' } @calls), '  ...no delete');

# --- 2. delete confirmation -------------------------------------------------
my $gone = $PKG->can('_confirm_dataset_gone');
ok($gone, '_confirm_dataset_gone exists');
{
    no strict 'refs'; no warnings 'redefine';
    my $probe;
    local *{"${PKG}::_tn_dataset_get"} = sub { die $probe->{die} if $probe->{die}; return $probe->{ret} };
    $probe = { ret => { id => 'x' } };
    like(do { eval { $gone->($scfg, 'x', 'Method does not exist'); 1 }; $@ },
        qr/Refusing to report success/, 'dataset still there: refuses');
    $probe = { die => "timeout talking to broker\n" };
    like(do { eval { $gone->($scfg, 'x', 'Method does not exist'); 1 }; $@ },
        qr/Cannot confirm/, 'cannot tell: refuses');
    $probe = { die => "[ENOENT] dataset does not exist\n" };
    ok(eval { $gone->($scfg, 'x', 'does not exist') }, 'confirmed absent: success');
}

# --- 3. CFS lock default ---------------------------------------------------
{
    no strict 'refs'; no warnings 'redefine';
    my $taken = 0;
    local *PVE::Storage::config = sub { {} };
    local *PVE::Storage::storage_config = sub { $_[2] ? $main::SC : $main::SC };
    local *PVE::Storage::Plugin::cluster_lock_storage = sub {
        my ($class, $storeid, $shared, $timeout, $func, @p) = @_;
        $taken++; return $func->(@p);
    };
    for my $case ([ {} , 1, 'default' ], [ { tn_use_cluster_lock => 1 }, 1, '=1' ],
                  [ { tn_use_cluster_lock => 0 }, 0, '=0 (explicit opt-out)' ]) {
        local $main::SC = { %$scfg, %{ $case->[0] } };
        $taken = 0;
        my $ran = 0;
        $PKG->cluster_lock_storage('s', 1, undef, sub { $ran++ });
        is($taken, $case->[1], "cluster lock taken=$case->[1] ($case->[2])");
        is($ran, 1, '  ...callback ran once');
    }
}

# --- 4. schema / alias -----------------------------------------------------
my $props = $PKG->properties;
is($props->{tn_use_cluster_lock}{default}, 1, 'tn_use_cluster_lock defaults to 1');
ok(length($props->{tn_use_cluster_lock}{title} // ''), 'tn_use_cluster_lock has a title');
is($props->{tn_broker_timeout}{default}, 30, "tn_broker_timeout keeps the fork's 30 s default");
ok($PKG->plugindata->{'advanced-properties'}{tn_use_cluster_lock}, 'tn_use_cluster_lock is advanced');
{
    no strict 'refs';
    my $flag = $PKG->can('_nvme_allow_any_host_flag');
    ok($flag->({}), 'allow_any_host flag defaults to true');
    ok(!$flag->({ tn_nvme_allow_any_host => 0 }), '  ...and honours 0');
}

# --- 5. NVMe orphan reaper never deletes on doubtful answers ---------------
{
    no strict 'refs'; no warnings 'redefine';
    my %q; my @deleted; my %get;
    local *{"${PKG}::_api_call"} = sub {
        my ($s, $m, $p) = @_;
        die $q{$m}{die} if $q{$m} && $q{$m}{die};
        push @deleted, $p->[0] if $m eq 'nvmet.namespace.delete';
        return $q{$m} ? $q{$m}{ret} : [];
    };
    local *{"${PKG}::_tn_dataset_get"} = sub { my ($s, $id) = @_; die $get{$id}{die} if $get{$id}{die}; return $get{$id}{ret} };
    my $reap = $PKG->can('_nvme_reap_orphan_namespaces');
    my $rs = { tn_dataset => 'tank/pve', tn_subsystem_nqn => 'nqn.x:y' };
    my @ns = ( { id => 1, device_path => 'zvol/tank/pve/vm-1-disk-0' },
               { id => 2, device_path => 'zvol/tank/pve/vm-2-disk-0' } );
    my $reset = sub {
        @deleted = (); %get = ();
        %q = ( 'nvmet.subsys.query' => { ret => [ { id => 7 } ] },
               'nvmet.namespace.query' => { ret => [@ns] },
               'pool.dataset.query' => { ret => [ { id => 'tank/pve/vm-1-disk-0' } ] } );
    };
    $reset->(); $q{'pool.dataset.query'} = { die => "boom\n" };
    $reap->($rs); is(scalar(@deleted), 0, 'reaper: dataset query error -> 0 deletes');
    $reset->(); $q{'pool.dataset.query'} = { ret => [] };
    $reap->($rs); is(scalar(@deleted), 0, 'reaper: empty dataset answer with namespaces present -> 0 deletes');
    $reset->(); $get{'tank/pve/vm-2-disk-0'} = { ret => { id => 'tank/pve/vm-2-disk-0' } };
    $reap->($rs); is(scalar(@deleted), 0, 'reaper: partial list but the dataset still exists -> 0 deletes');
    $reset->(); $get{'tank/pve/vm-2-disk-0'} = { die => "timeout\n" };
    $reap->($rs); is(scalar(@deleted), 0, 'reaper: probe fails for an unrelated reason -> 0 deletes');
    $reset->(); $get{'tank/pve/vm-2-disk-0'} = { die => "[ENOENT] does not exist\n" };
    $reap->($rs); is_deeply([@deleted], [2], 'reaper: a confirmed-gone dataset still gets its namespace reaped (and only it)');
}

# --- 6. snapshot clone: reuse on EITHER "already exists" spelling ----------
{
    no strict 'refs'; no warnings 'redefine';
    my $err;
    local *{"${PKG}::_tn_dataset_clone"} = sub { die $err };
    my $c = $PKG->can('_clone_snapshot_zvol');
    for my $e ("dataset already exists\n", "[EEXIST] ZFSPathAlreadyExistsException: Path tank/x\n") {
        $err = $e;
        ok(eval { $c->($scfg, 'tank/pve/vm-1-disk-0', 's1', 'tank/pve/clone'); 1 }, "clone: reuses on '" . ($e =~ s/\n//r) . "'")
            or diag($@);
    }
    $err = "[EFAULT] pool is offline\n";
    ok(!eval { $c->($scfg, 'a', 's', 'b'); 1 }, 'clone: other errors still die');
}

# --- 7. iSCSI extent sector size: new disks only ----------------------------
{
    no strict 'refs'; no warnings 'redefine';
    my @payloads;
    local *{"${PKG}::_api_call_mutate"} = sub { my ($s, $m, $p) = @_; push @payloads, $p->[0] if $m eq 'iscsi.extent.create'; return { id => 5 } };
    local *{"${PKG}::_api_call"} = sub { return [] };
    my $ec = $PKG->can('_tn_extent_create');
    eval { $ec->($scfg, 'vm-1-disk-0', 'tank/pve/vm-1-disk-0') };
    is(scalar(@payloads), 1, 'extent create for an existing zvol sent');
    ok(!exists $payloads[0]{blocksize} && !exists $payloads[0]{pblocksize},
        '  ...without blocksize/pblocksize (existing data keeps its sector size)');
}
open(my $src, '<', $PLUGIN) or die;
my $code = do { local $/; <$src> }; close $src;
my ($alloc) = $code =~ /(sub _alloc_image_iscsi .*?\n}\n)/s;
my ($clone) = $code =~ /(sub _clone_image_iscsi .*?\n}\n)/s;
like($alloc // '', qr/blocksize => 4096/, 'new iSCSI disks get blocksize 4096 (QEMU 10.1 alignment)');
unlike($clone // '', qr/blocksize => 4096/, 'iSCSI clones do not re-sector their source');

# --- 8. tn_api_host: upstream's format must accept everything ours did ------
SKIP: {
    skip 'PVE::JSONSchema not available', 3 unless eval { require PVE::JSONSchema; 1 };
    my $old = PVE::JSONSchema::get_format('pve-storage-server');
    my $new = PVE::JSONSchema::get_format('pve-storage-portal-dns');
    skip 'format validators not registered here', 3 unless $old && $new;
    is($props->{tn_api_host}{format}, 'pve-storage-portal-dns', 'tn_api_host uses the portal-dns format');
    my @hosts = ('192.0.2.10', 'truenas', 'truenas.example.com', 'TrueNAS.Lab', 'a-b.c', 'fd00:1::1');
    my @lost = grep { eval { $old->($_, undef); 1 } && !eval { $new->($_, undef); 1 } } @hosts;
    is_deeply(\@lost, [], 'nothing the old format accepted is rejected by the new one');
    ok(eval { $new->('[fd00:1::1]', undef); 1 }, '  ...and a bracketed IPv6 literal is now accepted');
}

# --- 9. second review round: fail-closed details ---------------------------
{
    no strict 'refs'; no warnings 'redefine';
    # (a) reaper: a transport "Method does not exist" is not a dataset absent
    my @deleted; my %get;
    local *{"${PKG}::_api_call"} = sub {
        my ($s, $m, $p) = @_;
        push @deleted, $p->[0] if $m eq 'nvmet.namespace.delete';
        return [ { id => 7 } ] if $m eq 'nvmet.subsys.query';
        return [ { id => 2, device_path => 'zvol/tank/pve/vm-2-disk-0' } ] if $m eq 'nvmet.namespace.query';
        return [ { id => 'tank/pve/vm-9-disk-0' } ] if $m eq 'pool.dataset.query';
        return [];
    };
    local *{"${PKG}::_tn_dataset_get"} = sub { die $get{err} };
    my $rs = { tn_dataset => 'tank/pve', tn_subsystem_nqn => 'nqn.x:y' };
    $get{err} = "[-32601] Method does not exist: pool.dataset.get_instance\n";
    $PKG->can('_nvme_reap_orphan_namespaces')->($rs);
    is(scalar(@deleted), 0, 'reaper: "Method does not exist" from the probe is NOT proof the dataset is gone');
    $get{err} = "[ENOENT] ... InstanceNotFound\n";
    $PKG->can('_nvme_reap_orphan_namespaces')->($rs);
    is_deeply([@deleted], [2], '  ...while a real InstanceNotFound still reaps');
}
{
    no strict 'refs'; no warnings 'redefine';
    # (b) orphan recovery needs a valid ARRAY from the clone query
    my ($clones, @calls);
    local *{"${PKG}::_api_call"} = sub {
        my ($s, $m, $p) = @_;
        if ($m eq 'pool.dataset.query' && $p->[0][0][0] eq 'origin.parsed') { return $clones }
        return [ { id => 'tank/pve/base-1-disk-0', children => [] } ];
    };
    local *{"${PKG}::_api_call_mutate"} = sub { push @calls, $_[1]; 1 };
    for my $bad (undef, { id => 'x' }, 'str') {
        @calls = (); $clones = $bad;
        my $r = $PKG->can('_dataset_orphan_check_and_delete')->($scfg, 'tank/pve/base-1-disk-0');
        is($r, 0, 'orphan recovery: clone query answering ' . (defined $bad ? ref($bad) || 'a string' : 'undef') . ' -> refuses');
        ok(!(grep { $_ eq 'pool.dataset.delete' } @calls), '  ...no delete');
    }
}
{
    no strict 'refs'; no warnings 'redefine';
    # (c) the retry loop must reach the confirmation before reporting success
    my ($del_err, $present);
    local *{"${PKG}::_api_call_mutate"} = sub { die $del_err };
    local *{"${PKG}::_tn_dataset_get"} = sub { $present ? { id => 'x' } : die "[ENOENT] does not exist\n" };
    my $d = $PKG->can('_delete_dataset_with_retry');
    $del_err = "[-32601] Method does not exist: pool.dataset.delete\n"; $present = 1;
    like(do { eval { $d->($scfg, 'tank/pve/vm-1-disk-0', 1); 1 }; $@ }, qr/Refusing to report success/,
        'delete retry: a transport "does not exist" with the dataset still there is NOT success');
    $del_err = "[ENOENT] dataset does not exist\n"; $present = 0;
    ok(eval { $d->($scfg, 'tank/pve/vm-1-disk-0', 1); 1 }, '  ...a real "does not exist" with the dataset gone is success');
}
is($PKG->can('DATASET_DELETE_TIMEOUT_S')->(), 30, 'DATASET_DELETE_TIMEOUT_S keeps the fork value (30)');

# --- 10. tn_broker_timeout: schema and check_config agree -------------------
SKIP: {
    skip 'cannot register the plugin with PVE::SectionConfig', 3 unless eval {
        require PVE::Storage::Plugin; $PKG->register(); PVE::Storage::Plugin->init(); 1 };
    my $max = $props->{tn_broker_timeout}{maximum};
    is($max, 600, 'tn_broker_timeout schema maximum is 600');
    ok(eval { $PKG->check_config('s', { type => 'truenasplugin', tn_broker_timeout => 500 }, 0, 1); 1 },
        'check_config accepts 500 (inside the schema range)') or diag($@);
    ok(!eval { $PKG->check_config('s', { type => 'truenasplugin', tn_broker_timeout => $max + 100 }, 0, 1); 1 },
        '  ...and rejects what the schema would reject');
}

done_testing;
