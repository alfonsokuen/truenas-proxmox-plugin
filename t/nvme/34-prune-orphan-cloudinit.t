#!/usr/bin/perl
# `qm destroy --purge` does not free the plugin's cloud-init disk: PVE's
# drive_is_cloudinit() matches /(?:vm-\d+-)?cloudinit(?:\.fmt)?$/ at the end of
# the volid, ours ends in -ns<uuid> / -lun<N>, so destroy_vm treats it as a
# plain CD-ROM and never calls free_image. truenas-proxmox-manage
# prune-orphan-cloudinit finds the ones whose guest is gone and, only with
# --yes, frees them through `pvesm free` (which goes through free_image's
# guards). Dry run by default, fail closed. /etc/pve is injectable.
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
    make_path("$root/nodes/pve1/qemu-server", "$root/nodes/pve2/lxc", "$root/nodes/pve2/qemu-server");
    open(my $f, '>', "$root/storage.cfg") or die;
    print $f "dir: local\n\tpath /var/lib/vz\n\ntruenasplugin: tn-prod\n\ttn_api_host x\n\ncifs: other\n\tserver y\n";
    close $f;
    open($f, '>', "$root/nodes/pve1/qemu-server/120.conf") or die;
    print $f "ide2: $VOL_A,media=cdrom\nscsi0: tn-prod:vol-vm-120-disk-0-ns$UUID,size=8G\n\n[snap1]\nide2: $VOL_C,media=cdrom\n";
    close $f;
    open($f, '>', "$root/nodes/pve2/lxc/121.conf") or die; print $f "rootfs: tn-prod:vol-vm-121-disk-0-lun2,size=4G\n"; close $f;
    return $root;
}

my (@listed, @freed, $free_rc);
my $list = sub { my ($store) = @_; push @listed, $store; return [ $VOL_A, $VOL_B, $VOL_C, $VOL_D, $VOL_E ] if $store eq 'tn-prod'; return [] };
my $free = sub { my ($volid) = @_; push @freed, $volid; return $free_rc // 0 };

# --- classification ----------------------------------------------------------
{
    my $root = pve_root();
    my $r = $prune->($PKG, pve_root => $root, list_volumes => $list, free_volume => $free);
    is_deeply([ sort map { $_->{volid} } @{ $r->{orphans} } ], [ sort $VOL_B, $VOL_D ],
        'orphans: guest gone and nothing references it (NVMe uuid form and the bare stem)');
    my %kept = map { $_->{volid} => $_->{reason} } @{ $r->{kept} };
    like($kept{$VOL_A} // '', qr/exists/, 'a volume whose guest exists is NOT an orphan');
    like($kept{$VOL_C} // '', qr/referenced/, 'guest gone but referenced from a snapshot of ANOTHER guest: NOT an orphan');
    ok(!exists $kept{$VOL_E} && !grep({ $_->{volid} eq $VOL_E } @{ $r->{orphans} }), 'a volume of a storage that is not truenasplugin is ignored');
    is_deeply(\@freed, [], 'dry run: pvesm free was never called');
}

# --- lxc guests count too ---------------------------------------------------
{
    my $root = pve_root();
    my $lxc = "tn-prod:vol-vm-121-cloudinit-ns$UUID";
    my $r = $prune->($PKG, pve_root => $root, list_volumes => sub { [ $lxc ] }, free_volume => $free);
    is(scalar @{ $r->{orphans} }, 0, 'a guest that exists as a container (lxc/121.conf) is not an orphan');
}

# --- fail closed ------------------------------------------------------------
{
    my @l; @freed = ();
    my $r = eval { $prune->($PKG, pve_root => '/nonexistent-pve-root', list_volumes => $list, free_volume => $free) };
    ok(!$r && $@, 'unreadable /etc/pve: an ERROR, not an empty answer');
    is_deeply(\@freed, [], '  ...and 0 candidates, 0 frees');
}
{
    my $root = pve_root();
    # a conf that cannot be read (a directory where 555.conf should be: open
    # succeeds, the read fails - works as root too)
    mkdir "$root/nodes/pve1/qemu-server/555.conf";
    @freed = ();
    my $r = eval { $prune->($PKG, pve_root => $root, list_volumes => $list, free_volume => $free, yes => 1) };
    ok(!$r && $@, 'a conf that cannot be read: an ERROR (it might be the reference)');
    is_deeply(\@freed, [], '  ...and nothing is freed');
}
{
    my $root = pve_root();
    my $r = eval { $prune->($PKG, pve_root => $root, list_volumes => sub { die "pvesm list failed\n" }, free_volume => $free) };
    ok(!$r && $@ =~ /pvesm list failed/, 'a failing volume listing: an ERROR, no candidates');
}
{
    my $root = pve_root();
    my $nodes = "$root/nodes"; rename $nodes, "$root/nodes.gone";
    ok(!eval { $prune->($PKG, pve_root => $root, list_volumes => $list, free_volume => $free) },
        'no nodes directory at all: an ERROR (an empty cluster would make everything look orphaned)');
}
{
    my $root = pve_root();
    ok(!eval { $prune->($PKG, pve_root => $root, storage => 'local', list_volumes => $list, free_volume => $free) },
        '--storage naming a non-truenasplugin storage is refused');
}

# --- the CLI: dry run by default, --yes frees one by one ---------------------
SKIP: {
    skip 'cli missing', 6 unless $cli;
    my $root = pve_root();
    no strict 'refs'; no warnings 'redefine';
    local ${"${PKG}::_PRUNE_PVE_ROOT"} = $root;
    local ${"${PKG}::_PRUNE_LIST"}     = $list;
    local ${"${PKG}::_PRUNE_FREE"}     = $free;
    @freed = ();
    my $out = '';
    {
        open(my $save, '>&', \*STDOUT); close STDOUT; open(STDOUT, '>', \$out) or die;
        my $rc = $cli->();
        close STDOUT; open(STDOUT, '>&', $save);
        is($rc, 0, 'cli: dry run exits 0');
    }
    like($out, qr/\Q$VOL_B\E/, '  ...lists the orphan');
    is_deeply(\@freed, [], '  ...and without --yes calls pvesm free ZERO times');

    @freed = (); $out = '';
    {
        open(my $save, '>&', \*STDOUT); close STDOUT; open(STDOUT, '>', \$out) or die;
        my $rc = $cli->('--yes');
        close STDOUT; open(STDOUT, '>&', $save);
        is($rc, 0, 'cli --yes: exits 0 when every free worked');
    }
    is_deeply([ sort @freed ], [ sort $VOL_B, $VOL_D ], '  ...frees exactly the orphans, one by one');
    $free_rc = 5; @freed = (); $out = '';
    {
        open(my $save, '>&', \*STDOUT); close STDOUT; open(STDOUT, '>', \$out) or die;
        my $rc = $cli->('--yes');
        close STDOUT; open(STDOUT, '>&', $save);
        isnt($rc, 0, 'cli --yes: a failing free makes the exit status non-zero');
    }
    like($out, qr/rc=5/, '  ...and the rc of each free is reported');
    $free_rc = undef;
}

# --- race guard: the guest appears between listing and freeing -------------
{
    my $root = pve_root();
    @freed = ();
    my $n = 0;
    my $r = $prune->($PKG, pve_root => $root, yes => 1,
        list_volumes => $list,
        free_volume => sub {
            my ($volid) = @_;
            # while the first free runs, a guest 777 is created
            open(my $f, '>', "$root/nodes/pve1/qemu-server/777.conf") or die; print $f "name: late\n"; close $f
                if !$n++;
            push @freed, $volid; return 0;
        });
    is(scalar(@freed), 1, 'race guard: a guest that appears after the listing stops the next free');
}

done_testing;
