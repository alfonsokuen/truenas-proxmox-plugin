#!/usr/bin/perl
# `qm destroy --purge` does not free the plugin's cloud-init disk: PVE's
# drive_is_cloudinit() matches /(?:vm-\d+-)?cloudinit(?:\.fmt)?$/ at the end of
# the volid, ours ends in -ns<uuid> / -lun<N>, so destroy_vm treats it as a
# plain CD-ROM and never calls free_image. truenas-proxmox-manage
# prune-orphan-cloudinit finds the ones whose guest is gone and, only with
# --yes --confirm-sole-cluster, frees them through `pvesm free` (which goes
# through free_image's guards). Dry run by default, fail closed everywhere.
# /etc/pve, the active-task list and the local node name are injectable.
#
# Run with:  prove -v t/nvme/34-prune-orphan-cloudinit.t
use strict;
use warnings;
use Test::More;
use FindBin;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

my $PLUGIN = "$FindBin::Bin/../../TrueNASPlugin.pm";
unless (eval { require $PLUGIN; 1 }) {
    plan skip_all => "cannot load TrueNASPlugin.pm (needs PVE perl modules): $@";
}
my $PKG = 'PVE::Storage::Custom::TrueNASPlugin';
my $prune = $PKG->can('prune_orphan_cloudinit') or BAIL_OUT('prune_orphan_cloudinit missing');
my $cli   = $PKG->can('prune_orphan_cloudinit_cli');

my $UUID = '11111111-2222-3333-4444-555555555555';
my $VOL_A = "tn-prod:vol-vm-120-cloudinit-ns$UUID";      # guest 120 exists
my $VOL_B = "tn-prod:vol-vm-777-cloudinit-ns$UUID";      # guest 777 gone, unreferenced
my $VOL_C = "tn-prod:vol-vm-888-cloudinit-lun4";         # guest 888 gone, referenced by a snapshot of 120
my $VOL_D = "tn-prod:vm-999-cloudinit";                  # bare stem, guest gone
my $VOL_E = "other:vol-vm-555-cloudinit-lun1";           # a storage that is not ours

sub pve_root {
    my (%o) = @_;
    my $root = tempdir(CLEANUP => 1);
    make_path("$root/nodes/pve1/qemu-server", "$root/nodes/pve1/lxc",
              "$root/nodes/pve2/lxc", "$root/nodes/pve2/qemu-server");
    my $storage_cfg = $o{storage_cfg}
        // "dir: local\n\tpath /var/lib/vz\n\ntruenasplugin: tn-prod\n\ttn_api_host 198.51.100.7\n\ttn_dataset tank/pve\n\ncifs: other\n\tserver y\n";
    open(my $f, '>', "$root/storage.cfg") or die; print $f $storage_cfg; close $f;
    open($f, '>', "$root/nodes/pve1/qemu-server/120.conf") or die;
    print $f "ide2: $VOL_A,media=cdrom\nscsi0: tn-prod:vol-vm-120-disk-0-ns$UUID,size=8G\n\n[snap1]\nide2: $VOL_C,media=cdrom\n";
    close $f;
    open($f, '>', "$root/nodes/pve2/lxc/121.conf") or die; print $f "rootfs: tn-prod:vol-vm-121-disk-0-lun2,size=4G\n"; close $f;
    return $root;
}
sub put_conf {   # a conf of another guest that mentions some text
    my ($root, $kind, $vmid, $text, $node) = @_;
    $node //= 'pve2';
    make_path("$root/nodes/$node/$kind");
    open(my $f, '>', "$root/nodes/$node/$kind/$vmid.conf") or die; print $f $text; close $f;
}

my (@freed, $free_rc);
my $list = sub { my ($store) = @_; return [ $VOL_A, $VOL_B, $VOL_C, $VOL_D, $VOL_E ] if $store eq 'tn-prod'; return [] };
my $free = sub { my ($volid) = @_; push @freed, $volid; return $free_rc // 0 };
my %base = (list_volumes => $list, free_volume => $free, local_node => 'pve1', tasks_active => undef, quorum_check => undef);
sub run { my ($root, %o) = @_; return $prune->($PKG, pve_root => $root, %base, %o) }
sub orphans_of { my ($r) = @_; return [ sort map { $_->{volid} } @{ $r->{orphans} } ] }

# --- classification ----------------------------------------------------------
{
    my $r = run(pve_root());
    is_deeply(orphans_of($r), [ sort $VOL_B, $VOL_D ],
        'orphans: guest gone and nothing references it (NVMe uuid form and the bare stem)');
    my %kept = map { $_->{volid} => $_->{reason} } @{ $r->{kept} };
    like($kept{$VOL_A} // '', qr/exists/, 'a volume whose guest exists is NOT an orphan');
    like($kept{$VOL_C} // '', qr/referenced/, 'guest gone but referenced from a snapshot of ANOTHER guest: NOT an orphan');
    ok(!exists $kept{$VOL_E} && !grep({ $_->{volid} eq $VOL_E } @{ $r->{orphans} }), 'a volume of a storage that is not truenasplugin is ignored');
    is_deeply(\@freed, [], 'dry run: pvesm free was never called');
}
{
    my $root = pve_root();
    my $lxc = "tn-prod:vol-vm-121-cloudinit-ns$UUID";
    my $r = run($root, list_volumes => sub { [ $lxc ] });
    is(scalar @{ $r->{orphans} }, 0, 'a guest that exists as a container (lxc/121.conf) is not an orphan');
}

# --- H2: references by CANONICAL identity, whatever the spelling -------------
for my $case (
    ['bare form from another guest',        'qemu-server', "ide2: tn-prod:vm-777-cloudinit,media=cdrom\n"],
    ['uuid form from another guest',        'qemu-server', "ide2: $VOL_B,media=cdrom\n"],
    ['a different alias (lun) of the same', 'qemu-server', "ide2: tn-prod:vol-vm-777-cloudinit-lun3,media=cdrom\n"],
    ['extension form',                      'qemu-server', "ide2: tn-prod:vm-777-cloudinit.raw,media=cdrom\n"],
    ['snapshot section',                    'qemu-server', "name: x\n\n[before-upgrade]\nide2: tn-prod:vm-777-cloudinit,media=cdrom\n"],
    ['[PENDING] section',                   'qemu-server', "name: x\n\n[PENDING]\nide2: tn-prod:vm-777-cloudinit,media=cdrom\n"],
    ['unused0',                             'qemu-server', "name: x\nunused0: $VOL_B\n"],
    ['a container',                         'lxc',         "rootfs: tn-prod:vol-vm-5-disk-0-lun1\nmp0: $VOL_B,mp=/data\n"],
) {
    my ($label, $kind, $text) = @$case;
    my $root = pve_root();
    put_conf($root, $kind, 4242, $text);
    my $r = run($root);
    ok(!grep({ $_->{volid} eq $VOL_B } @{ $r->{orphans} }), "H2: $label -> NOT an orphan");
}
{
    my $root = pve_root();
    put_conf($root, 'qemu-server', 4242, "ide2: tn-other:vm-777-cloudinit,media=cdrom\n");   # a different storage id
    my $r = run($root);
    ok(scalar(grep { $_->{volid} eq $VOL_B } @{ $r->{orphans} }), '  ...but the same vmid on ANOTHER storage id does not protect this one');
}

# --- fail closed: reading --------------------------------------------------
{
    @freed = ();
    my $r = eval { run('/nonexistent-pve-root') };
    ok(!$r && $@, 'unreadable /etc/pve: an ERROR, not an empty answer');
    is_deeply(\@freed, [], '  ...and 0 candidates, 0 frees');
}
{
    my $root = pve_root();
    mkdir "$root/nodes/pve1/qemu-server/555.conf";      # a directory where a conf should be
    @freed = ();
    my $r = eval { run($root, yes => 1, confirm_sole_cluster => 1) };
    ok(!$r && $@, 'a conf that cannot be read (or is not a file): an ERROR');
    is_deeply(\@freed, [], '  ...and nothing is freed');
}
{
    my $root = pve_root();
    my $r = eval { run($root, list_volumes => sub { die "pvesm list failed\n" }) };
    ok(!$r && $@ =~ /pvesm list failed/, 'a failing volume listing: an ERROR, no candidates');
}
{
    my $root = pve_root();
    rename "$root/nodes", "$root/nodes.gone";
    ok(!eval { run($root) }, 'no nodes directory at all: an ERROR');
}
{
    ok(!eval { run(pve_root(), storage => 'local') }, '--storage naming a non-truenasplugin storage is refused');
}

# --- H3a: a missing or unreadable guest directory ABORTS --------------------
{
    my $root = pve_root();
    unlink "$root/nodes/pve2/lxc/121.conf"; rmdir "$root/nodes/pve2/lxc" or die "rmdir: $!";
    my $r = eval { run($root) };
    ok(!$r && $@ =~ /pve2\/lxc/, 'H3a: a node without its lxc directory aborts (it is not silently skipped)');
    $root = pve_root();
    rmdir "$root/nodes/pve2/qemu-server";
    ok(!eval { run($root) }, '  ...nor without qemu-server');
}

# --- H3b: an empty index, or no local node dir -------------------------------
{
    my $root = pve_root();
    unlink "$root/nodes/pve1/qemu-server/120.conf", "$root/nodes/pve2/lxc/121.conf";
    my $r = eval { run($root) };
    ok(!$r && $@ =~ /no guest configuration/, 'H3b: no guest conf at all aborts (every volume would look orphaned)');
    $root = pve_root();
    ok(!eval { run($root, local_node => 'pve9') } && $@ =~ /pve9/, '  ...and a local node without qemu-server aborts');
}

# --- H3c: operations in progress --------------------------------------------
for my $odd ('300.conf.tmp.1234', '300.conf.tmp', '300.lock', '300.conf.lock', 'notes.txt') {
    my $root = pve_root();
    open(my $f, '>', "$root/nodes/pve1/qemu-server/$odd") or die; close $f;
    my $r = eval { run($root) };
    ok(!$r && $@ =~ /operations in progress/, "H3c: a '$odd' next to the confs aborts: operations in progress");
}
{
    my $root = pve_root();
    my $dir = tempdir(CLEANUP => 1);
    my $act = "$dir/active";
    # a task whose process is REALLY alive: this test process, with its real start time
    my $stat = do { open(my $s, '<', "/proc/$$/stat") or die; local $/; <$s> };
    my ($rest) = $stat =~ /^\d+ \(.*\) (.*)$/s;
    my $pstart = sprintf('%08X', (split ' ', $rest)[19]);
    my $alive = sprintf('UPID:pve1:%08X:%s', $$, $pstart);
    my $dead  = 'UPID:pve1:3B9AC9FF:0003C4D5';          # no such pid
    my $recycled = sprintf('UPID:pve1:%08X:00000001', $$);   # pid exists, but it is not the process that started the task
    my $line = sub { my ($u, $type) = @_; return "$u:67890ABC:$type:120:root\@pam: 1\n" };
    my $w = sub { open(my $f, '>', $act) or die; print $f @_; close $f };

    $w->($line->($alive, 'vzdump'));
    my $r = eval { run($root, tasks_active => $act, local_node => 'pve1') };
    ok(!$r && $@ =~ /operations in progress.*vzdump/, 'H3c: an active (live) vzdump task aborts');
    $w->($line->($alive, 'qmrestore'));
    ok(!eval { run($root, tasks_active => $act, local_node => 'pve1') }, '  ...and a live qmrestore');
    $w->($line->($alive, 'vncproxy'));
    ok(eval { run($root, tasks_active => $act, local_node => 'pve1') }, '  ...but an unrelated task (vncproxy) does not');
    $w->($line->($dead, 'vzdump'));
    ok(eval { run($root, tasks_active => $act, local_node => 'pve1') },
        '  ...and a STALE entry (process gone) does not block forever: production nodes carry such leftovers') or diag($@);
    $w->($line->($recycled, 'vzdump'));
    ok(eval { run($root, tasks_active => $act, local_node => 'pve1') }, '  ...nor an entry whose pid was recycled by another process');
    $w->($line->('UPID:pve2:3B9AC9FF:0003C4D5', 'vzdump'));
    ok(!eval { run($root, tasks_active => $act, local_node => 'pve1') }, '  ...but a task of ANOTHER node cannot be checked, so it blocks');
    open(my $f, '>', $act) or die; close $f;
    ok(eval { run($root, tasks_active => $act) }, '  ...and an empty list is fine');
    ok(!eval { run($root, tasks_active => "$dir/does-not-exist") }, '  ...an unreadable task list aborts');
}

# --- H4: storages on the same dataset; --confirm-sole-cluster --------------
{
    my $cfg = "truenasplugin: tn-prod\n\ttn_api_host 198.51.100.7\n\ttn_dataset tank/pve\n\n"
            . "truenasplugin: tn-prod-b\n\ttn_api_host 198.51.100.7\n\ttn_dataset tank/pve\n";
    my $r = eval { run(pve_root(storage_cfg => $cfg)) };
    ok(!$r && $@ =~ /same dataset/, 'H4: two storage ids on the same dataset abort');
    $cfg = "truenasplugin: tn-prod\n\ttn_api_host 198.51.100.7\n\ttn_dataset tank/pve\n\n"
         . "truenasplugin: tn-lab\n\ttn_api_host 198.51.100.9\n\ttn_dataset tank/pve\n";
    ok(eval { run(pve_root(storage_cfg => $cfg)) }, '  ...same dataset NAME on a different array is fine');
}
{
    @freed = ();
    my $r = eval { run(pve_root(), yes => 1) };
    ok(!$r && $@ =~ /confirm-sole-cluster/, 'H4: --yes without --confirm-sole-cluster aborts with the reason');
    is_deeply(\@freed, [], '  ...and frees nothing');
}

# --- the CLI: dry run by default, --yes frees one by one ---------------------
SKIP: {
    skip 'cli missing', 9 unless $cli;
    my $root = pve_root();
    no strict 'refs'; no warnings 'redefine';
    local ${"${PKG}::_PRUNE_PVE_ROOT"}     = $root;
    local ${"${PKG}::_PRUNE_LIST"}         = $list;
    local ${"${PKG}::_PRUNE_FREE"}         = $free;
    local ${"${PKG}::_PRUNE_LOCAL_NODE"}   = 'pve1';
    local ${"${PKG}::_PRUNE_TASKS_ACTIVE"} = undef;
    sub capture { my ($code) = @_; my $out = ''; open(my $save, '>&', \*STDOUT); close STDOUT; open(STDOUT, '>', \$out) or die;
                  my $rc = $code->(); close STDOUT; open(STDOUT, '>&', $save); return ($rc, $out) }
    @freed = ();
    my ($rc, $out) = capture(sub { $cli->() });
    is($rc, 0, 'cli: dry run exits 0');
    like($out, qr/\Q$VOL_B\E/, '  ...lists the orphan');
    is_deeply(\@freed, [], '  ...and without --yes calls pvesm free ZERO times');

    @freed = ();
    ($rc, $out) = capture(sub { $cli->('--yes') });
    isnt($rc, 0, 'cli --yes alone refuses (needs --confirm-sole-cluster)');
    is_deeply(\@freed, [], '  ...freeing nothing');

    @freed = ();
    ($rc, $out) = capture(sub { $cli->('--yes', '--confirm-sole-cluster') });
    is($rc, 0, 'cli --yes --confirm-sole-cluster: exits 0 when every free worked');
    is_deeply([ sort @freed ], [ sort $VOL_B, $VOL_D ], '  ...frees exactly the orphans, one by one');
    $free_rc = 5; @freed = ();
    ($rc, $out) = capture(sub { $cli->('--yes', '--confirm-sole-cluster') });
    isnt($rc, 0, 'cli --yes: a failing free makes the exit status non-zero');
    like($out, qr/rc=5/, '  ...and the rc of each free is reported');
    $free_rc = undef;
}

# --- race guard: the guest appears between listing and freeing -------------
{
    my $root = pve_root();
    @freed = ();
    my $n = 0;
    my $r = run($root, yes => 1, confirm_sole_cluster => 1,
        free_volume => sub {
            my ($volid) = @_;
            open(my $f, '>', "$root/nodes/pve1/qemu-server/777.conf") or die; print $f "name: late\n"; close $f
                if !$n++;
            push @freed, $volid; return 0;
        });
    is(scalar(@freed), 1, 'race guard: a guest that appears after the listing stops the next free');
}

# --- (b) quorum: a node that is not quorate aborts ---------------------------
{
    my $root = pve_root();
    my $r = eval { run($root, quorum_check => sub { die "this node is not quorate\n" }) };
    ok(!$r && $@ =~ /not quorate/, 'a non-quorate node aborts, even for a dry run');

    # the default check, against a fake pvecm and a clustered root
    my $dir = tempdir(CLEANUP => 1);
    open(my $c, '>', "$root/corosync.conf") or die; close $c;
    my $fake = sub { my ($body) = @_; open(my $f, '>', "$dir/pvecm") or die; print $f "#!/bin/sh\n$body\n"; close $f; chmod 0755, "$dir/pvecm"; };
    no strict 'refs'; no warnings 'redefine';
    local ${"${PKG}::_PRUNE_PVECM"} = "$dir/pvecm";
    $fake->('echo "Quorate:          No"');
    ok(!eval { $prune->($PKG, pve_root => $root, %base, quorum_check => \&{"${PKG}::_prune_check_quorate"}) },
        'pvecm status saying Quorate: No aborts');
    $fake->('echo boom >&2; exit 2');
    ok(!eval { $prune->($PKG, pve_root => $root, %base, quorum_check => \&{"${PKG}::_prune_check_quorate"}) },
        '  ...and a failing pvecm aborts too (cannot confirm)');
    $fake->('echo "Quorate:          Yes"');
    ok(eval { $prune->($PKG, pve_root => $root, %base, quorum_check => \&{"${PKG}::_prune_check_quorate"}) },
        '  ...and Quorate: Yes proceeds') or diag($@);
    unlink "$root/corosync.conf";
    $fake->('echo "Quorate:          No"');
    ok(eval { $prune->($PKG, pve_root => $root, %base, quorum_check => \&{"${PKG}::_prune_check_quorate"}) },
        '  ...a standalone node (no corosync.conf) has no quorum to lose');
}

# --- (d) a re-read that fails mid --yes reports EVERY volume left unfreed -----
{
    my $root = pve_root();
    @freed = ();
    my $n = 0;
    my $r = run($root, yes => 1, confirm_sole_cluster => 1,
        list_volumes => sub { [ $VOL_B, $VOL_D, 'tn-prod:vol-vm-778-cloudinit-lun1' ] },
        free_volume => sub {
            my ($volid) = @_;
            # after the first free the guest directories become unreadable
            rename "$root/nodes/pve1/qemu-server", "$root/nodes/pve1/qemu-server.gone" if !$n++;
            push @freed, $volid; return 0;
        });
    is(scalar(@freed), 1, 'a failing re-check stops after the first free');
    my @skipped = grep { !defined $_->{rc} } @{ $r->{freed} };
    is(scalar(@skipped), 2, '  ...and EVERY volume left over is listed as skipped, not silently dropped');
    like($skipped[0]{note} // '', qr/re-check failed/, '  ...with the reason');
}

done_testing;
