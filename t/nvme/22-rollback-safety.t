#!/usr/bin/perl
# volume_snapshot_rollback() must never destroy a snapshot nobody asked it to.
#
# What it used to do: PVE calls volume_rollback_is_possible() first - which
# refuses anything that is not the newest snapshot - and then, some time
# later (after stopping the guest), volume_snapshot_rollback(), which fired
# `pool.snapshot.rollback` with recursive=1 AND force=1. Recursive rollback
# on TrueNAS destroys every snapshot newer than the target. So in the window
# between the two calls - a window that contains a guest shutdown, and into
# which any periodic task, replication job or other node can drop a snapshot
# - the plugin silently deleted data the operator had never been shown.
#
# This file pins the three things that closed it:
#
#   1. the "is it still the newest?" question is asked AGAIN inside
#      volume_snapshot_rollback, against the array, and a newer snapshot
#      there makes it die WITHOUT issuing any rollback at all;
#   2. the rollback that is issued is not recursive and not forced;
#   3. the post-rollback device refresh runs iscsiadm only on an iSCSI
#      storage - on NVMe/TCP it printed "No session found" every time;
#   4. PVE rolls a guest back one volume at a time and NOT under the guest
#      config lock, so the refusal can land on the second disk with the
#      first one already rolled back. That is still the right answer, but
#      the operator has to be told: the guest is left locked and half
#      rolled back.
#
# Run with:  prove -v t/nvme/22-rollback-safety.t

use strict;
use warnings;
use Test::More;
use FindBin;
use File::Spec;

my $PLUGIN = File::Spec->rel2abs("$FindBin::Bin/../../TrueNASPlugin.pm");
plan skip_all => "TrueNASPlugin.pm not found at $PLUGIN" unless -f $PLUGIN;

eval { require PVE::Storage; 1 };

unless (eval { require $PLUGIN; 1 }) {
    my $err = $@ || 'unknown error';
    plan skip_all => "no PVE perl modules here (needs libpve-storage-perl)"
        if $err =~ m{Can't locate PVE/(?:Tools|JSONSchema|Storage/Plugin)\.pm};
    plan tests => 1;
    fail("the plugin did not load, and not for lack of PVE");
    diag($err);
    exit 1;
}

my $PKG = 'PVE::Storage::Custom::TrueNASPlugin';

# The text rewriter of /etc/pve/qemu-server/<vmid>.conf is gone: a storage
# plugin has no business editing a guest configuration, and that one did it
# without lock_config and only for VMs.
#
# Asserted on the SOURCE, not with ->can(): on a node where the plugin is
# installed, PVE::Storage has already pulled the installed copy into this
# same package, so a sub that the file under test no longer defines is still
# there from the older one. The source is the only honest answer.
{
    open(my $src, '<', $PLUGIN) or die "cannot read $PLUGIN: $!";
    my $code = do { local $/; <$src> };
    close($src);
    ok($code !~ /sub _cleanup_vm_snapshot_config/,
        'el reescritor de texto de la config de la VM ya no existe');
    ok($code !~ m{open\s+\$fh,\s*'>',\s*\$config_file},
        '  ...y nada en el plugin abre para escribir un fichero de /etc/pve');
}

my $VOLNAME  = 'vol-vm-9992-disk-0-lun0';
my $FULL     = 'pool/pve/vm-9992-disk-0';
my $VOLNAME2 = 'vol-vm-9992-disk-1-lun1';
my $FULL2    = 'pool/pve/vm-9992-disk-1';

our @ROLLBACKS;   # every pool.snapshot.rollback payload, in order
our @COMMANDS;    # every run_command argv, in order
our @LOGS;        # every _log line, with its level
our %SNAPS;       # dataset => [ records ], what the array answers

sub snap_record {
    my ($name, $ts, $ds) = @_;
    $ds //= $FULL;
    return { name => "$ds\@$name",
             createtxg => $ts,
             properties => { creation => { rawvalue => "$ts" } } };
}

{
    no strict 'refs';
    no warnings 'redefine';
    *{"${PKG}::_log"} = sub {
        my ($scfg, $level, $prio, $msg) = @_;
        push @LOGS, { level => $level, prio => $prio, msg => $msg };
        return 1;
    };
    # The lock is not what is under test here; run the body.
    *{"${PKG}::cluster_lock_storage"} = sub {
        my ($class, $storeid, $shared, $timeout, $func, @param) = @_;
        return $func->(@param);
    };
    # Answers per dataset, the way the filtered query now asks.
    *{"${PKG}::_api_call"} = sub {
        my ($scfg, $method, $params) = @_;
        if ($method eq 'pool.snapshot.query') {
            my $ds = eval { $params->[0][0][2] };
            return [ map { @$_ } values %SNAPS ] if !defined($ds) || ref($ds);
            return [ @{ $SNAPS{$ds} // [] } ];
        }
        die "unexpected API call $method\n";
    };
    # Capture the JSON-RPC payload itself, so "not recursive" is asserted on
    # what goes to the array and not on an argument of a helper.
    *{"${PKG}::_ws_get_persistent"} = sub { return { next_id => 1 } };
    *{"${PKG}::_ws_rpc"} = sub {
        my ($conn, $req) = @_;
        push @ROLLBACKS, $req if ($req->{method} // '') eq 'pool.snapshot.rollback';
        return { result => 1 };
    };
    *{"PVE::Tools::run_command"} = sub {
        my ($cmd, %opts) = @_;
        push @COMMANDS, join(' ', @$cmd);
        return 0;
    };
}

sub scfg_for {
    my ($mode) = @_;
    return {
        tn_dataset        => 'pool/pve',
        tn_transport_mode => $mode,
        tn_target_iqn     => 'iqn.2005-10.org.freenas.ctl:pve',
    };
}

sub rollback {
    my ($scfg, $snapname, $volname) = @_;
    $volname //= $VOLNAME;
    my $ok = eval {
        $PKG->volume_snapshot_rollback($scfg, 'tnnvme', $volname, $snapname);
        1;
    };
    return ($ok, $ok ? '' : ($@ // 'died'));
}

sub reset_world {
    @ROLLBACKS = ();
    @COMMANDS  = ();
    @LOGS      = ();
    %SNAPS     = ();
}

# ------------- 2-5. the target is still the newest: it rolls back, once ---
{
    reset_world();
    $SNAPS{$FULL} = [ snap_record('older', 1789600000), snap_record('target', 1789700000) ];
    my ($ok, $err) = rollback(scfg_for('iscsi'), 'target');
    ok($ok, 'el snapshot mas reciente: el rollback se ejecuta') or diag($err);
    is(scalar(@ROLLBACKS), 1, '  ...con una sola llamada a pool.snapshot.rollback');
    my $params = $ROLLBACKS[0]{params};
    is($params->[0], "$FULL\@target", '  ...sobre el snapshot pedido');
    ok(!$params->[1]{recursive} && !$params->[1]{force},
        '  ...NO recursivo y NO forzado: no destruye nada por su cuenta')
        or diag(explain($params->[1]));
}

# ------- 6-8. a newer snapshot appeared after the check: die, destroy 0 ---
# This is the race the recursive rollback used to swallow: PVE approved the
# rollback when 'target' was the newest, and by the time the guest was down
# a periodic task had taken 'auto-2026-09-19_03-00'.
{
    reset_world();
    $SNAPS{$FULL} = [ snap_record('older',  1789600000),
                      snap_record('target', 1789700000),
                      snap_record('auto-2026-09-19_03-00', 1789800000) ];
    my ($ok, $err) = rollback(scfg_for('iscsi'), 'target');
    ok(!$ok, 'aparece un snapshot mas nuevo entre la comprobacion y el rollback: muere');
    like($err, qr/auto-2026-09-19_03-00/,
        '  ...nombrando el snapshot que lo bloquea');
    is(scalar(@ROLLBACKS), 0,
        '  ...y NO se llama a pool.snapshot.rollback: no se destruye nada');
}

# --------------------- 9. a snapshot that is not there at all also dies ---
{
    reset_world();
    $SNAPS{$FULL} = [ snap_record('older', 1789600000) ];
    my ($ok, $err) = rollback(scfg_for('iscsi'), 'target');
    ok(!$ok && !@ROLLBACKS,
        'el snapshot ya no existe en la cabina: muere sin llamar al rollback');
}

# ------------------------------------- 10-13. the refresh by transport ---
{
    reset_world();
    $SNAPS{$FULL} = [ snap_record('target', 1789700000) ];
    my ($ok) = rollback(scfg_for('nvme-tcp'), 'target');
    ok($ok, 'NVMe/TCP: el rollback se ejecuta');
    is(scalar(grep { /^iscsiadm/ } @COMMANDS), 0,
        '  ...sin invocar iscsiadm (no hay sesion iSCSI que refrescar)');
}
{
    reset_world();
    $SNAPS{$FULL} = [ snap_record('target', 1789700000) ];
    my ($ok) = rollback(scfg_for('iscsi'), 'target');
    ok($ok, 'iSCSI: el rollback se ejecuta');
    is(scalar(grep { /^iscsiadm/ } @COMMANDS), 1,
        '  ...y refresca la sesion iSCSI del target');
}

# ----------- 14-18. two disks, blocker on the second one only ------------
# PVE calls volume_snapshot_rollback once per volume, outside the guest
# config lock. Disk 0 has nothing newer and rolls back; disk 1 has gained a
# snapshot and must refuse - one rollback call in total, and a level 0 log
# line telling the operator the guest is now locked and half rolled back,
# which the error PVE shows does not say on its own.
{
    reset_world();
    $SNAPS{$FULL}  = [ snap_record('target', 1789700000, $FULL) ];
    $SNAPS{$FULL2} = [ snap_record('target', 1789700000, $FULL2),
                       snap_record('auto-2026-09-19_03-00', 1789800000, $FULL2) ];

    my ($ok1) = rollback(scfg_for('nvme-tcp'), 'target', $VOLNAME);
    ok($ok1, 'disco 0: sin bloqueador, se revierte');

    my ($ok2, $err2) = rollback(scfg_for('nvme-tcp'), 'target', $VOLNAME2);
    ok(!$ok2, 'disco 1: con bloqueador, se rehusa');
    is(scalar(@ROLLBACKS), 1,
        'exactamente UNA llamada de rollback en total: el disco 1 no se toca');
    like($err2, qr/auto-2026-09-19_03-00/, '  ...nombrando el bloqueador');
    ok((grep { $_->{level} == 0 && $_->{msg} =~ /unlock/ } @LOGS),
        'y un aviso de nivel 0 dice que el invitado queda bloqueado y a medias');
}

# 19-20. createtxg decides what "most recent" means when two snapshots share
#        a second. A periodic task takes them all in one transaction, so
#        sharing a second is the normal case; by name alone 'auto-later'
#        sorts before 'target' and the blocker disappeared.
{
    reset_world();
    $SNAPS{$FULL} = [
        { name => "$FULL\@target",
          createtxg => 800,
          properties => { creation => { rawvalue => '1789700000' } } },
        { name => "$FULL\@auto-later",
          createtxg => 900,
          properties => { creation => { rawvalue => '1789700000' } } },
    ];
    my ($ok, $err) = rollback(scfg_for('nvme-tcp'), 'target');
    ok(!$ok, 'mismo segundo, createtxg mayor: sigue siendo un bloqueador');
    like($err, qr/auto-later/, '  ...y se nombra');
}

done_testing();
