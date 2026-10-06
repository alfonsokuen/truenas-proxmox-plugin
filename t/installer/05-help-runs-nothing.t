#!/usr/bin/perl
# The --help text of install.sh sits in an unquoted heredoc: a backtick in it
# RUNS the command (found with fake qm/pvesm on PATH: `qm destroy --purge` twice
# and `pvesm free` ran just from printing the help). Help must run nothing.
# Also the dispatch of the prune-orphan-cloudinit subcommand is executed here,
# not just grepped, and a dry run must never call `pvesm free`.
#
# Run with:  prove -v t/installer/05-help-runs-nothing.t
use strict;
use warnings;
use Test::More;
use FindBin;
use File::Spec;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

my $ROOT   = File::Spec->rel2abs("$FindBin::Bin/../..");
my $SCRIPT = "$ROOT/install.sh";
plan skip_all => "install.sh not found" unless -f $SCRIPT;
plan skip_all => "bash not available" if system("command -v bash >/dev/null 2>&1") != 0;

my $tmp  = tempdir(CLEANUP => 1);
my $bin  = "$tmp/bin";  make_path($bin);
my $log  = "$tmp/calls.log";
my @fake = qw(qm pvesm pct zfs nvme systemctl apt-get dpkg pvesh apt-cache udevadm curl wget ssh scp);
for my $name (@fake) {
    open(my $f, '>', "$bin/$name") or die;
    print $f "#!/bin/sh\necho \"$name \$*\" >> '$log'\n" . ($name eq 'pvesm' ? 'if [ "$1" = list ]; then echo "Volid Format Type Size VMID"; fi' . "\n" : '') . "exit 0\n";
    close $f; chmod 0755, "$bin/$name";
}
my $env = "PATH='$bin':\$PATH TRUENAS_TEST_STORAGE_CFG='$tmp/s.cfg' TRUENAS_TEST_PRIV_DIR='$tmp/p' "
        . "TRUENAS_TEST_BACKUP_DIR='$tmp/b' TRUENAS_TEST_LOG_FILE='$tmp/l'";

sub calls { return -e $log ? do { open(my $f, '<', $log) or die; local $/; <$f> } : '' }
sub run_sh { my ($args) = @_; unlink $log; my $out = `env $env bash '$SCRIPT' $args 2>&1 </dev/null`; return ($out, $? >> 8) }

# --- H1: help prints text and runs nothing -----------------------------------
{
    my ($out, $rc) = run_sh('--help');
    like($out, qr/prune-orphan-cloudinit/, '--help prints the usage (and lists prune-orphan-cloudinit)');
    like($out, qr/`qm destroy --purge`/, '  ...with its backticks printed literally, not executed');
    is(calls(), '', '--help ran NO external command (qm, pvesm, pvesh, ... all fake and logging)');
    ($out, $rc) = run_sh('--version');
    is(calls(), '', '--version ran no external command');
}

# --- every subcommand's --help, through the real dispatch --------------------
SKIP: {
    my $lib = "$tmp/lib/PVE/Storage/Custom";
    make_path($lib);
    system("cp '$ROOT/TrueNASPlugin.pm' '$lib/TrueNASPlugin.pm'");
    my $loads = system("PERL5LIB='$tmp/lib' perl -MPVE::Storage::Custom::TrueNASPlugin -e 1 >/dev/null 2>&1") == 0;
    skip 'plugin cannot be loaded here (needs the PVE perl modules)', 11 unless $loads;
    local $ENV{PERL5LIB} = "$tmp/lib";
    for my $sub ('import-snapshots', 'migrate-secrets', 'prune-orphan-cloudinit') {
        my ($out, $rc) = run_sh("$sub --help");
        is(calls(), '', "'$sub --help' ran no external command");
        like($out, qr/Usage/, "  ...and printed its usage");
    }

    # --- H6: the dispatch is EXECUTED, and a dry run never frees -------------
    my $pve = "$tmp/pve";
    make_path("$pve/nodes/pve1/qemu-server", "$pve/nodes/pve1/lxc");
    open(my $f, '>', "$pve/storage.cfg") or die;
    print $f "truenasplugin: tn-prod\n\ttn_api_host 198.51.100.7\n\ttn_dataset tank/pve\n";
    close $f;
    open($f, '>', "$pve/nodes/pve1/qemu-server/120.conf") or die; print $f "name: a\n"; close $f;
    open($f, '>', "$tmp/active") or die; close $f;
    # a pvesm that lists one orphan and one whose guest exists
    open($f, '>', "$bin/pvesm") or die;
    print $f "#!/bin/sh\necho \"pvesm \$*\" >> '$log'\nif [ \"\$1\" = list ]; then\n"
           . "echo 'Volid Format Type Size VMID'\n"
           . "echo 'tn-prod:vol-vm-120-cloudinit-lun1 raw images 4194304 120'\n"
           . "echo 'tn-prod:vol-vm-777-cloudinit-lun2 raw images 4194304 777'\nfi\nexit 0\n";
    close $f; chmod 0755, "$bin/pvesm";
    local $ENV{TRUENAS_TEST_PVE_ROOT}     = $pve;
    local $ENV{TRUENAS_TEST_TASKS_ACTIVE} = "$tmp/active";
    local $ENV{TRUENAS_TEST_LOCAL_NODE}   = 'pve1';
    my ($out, $rc) = run_sh('prune-orphan-cloudinit');
    like($out, qr/orphan\s+tn-prod:vol-vm-777-cloudinit-lun2/, 'dispatch executed: the dry run lists the orphan');
    unlike(calls(), qr/pvesm free/, '  ...and WITHOUT --yes `pvesm free` was never called');
    ($out, $rc) = run_sh('prune-orphan-cloudinit --yes');
    unlike(calls(), qr/pvesm free/, '--yes alone (no --confirm-sole-cluster): still no `pvesm free`');
    ($out, $rc) = run_sh('prune-orphan-cloudinit --yes --confirm-sole-cluster');
    like(calls(), qr/pvesm free tn-prod:vol-vm-777-cloudinit-lun2/, 'with both flags the orphan goes through `pvesm free`');
    unlike(calls(), qr/pvesm free tn-prod:vol-vm-120/, '  ...and the volume of an existing guest does not');
}

done_testing;
