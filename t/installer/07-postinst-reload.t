#!/usr/bin/perl
# debian/postinst must not reload pvedaemon / pvestatd / pvescheduler itself.
# pve-manager's dpkg trigger (interest-noawait /usr/share/perl5/PVE) already
# reloads them once because the plugin installs under that tree; doing it here
# too sent pvestatd two HUPs ~2 s apart, the second landing in the first's
# "server shutdown (restart)", and the daemon exited and stayed down (3 of 9
# `dpkg -i` in the lab). The HA daemons are NOT covered by the trigger, and the
# broker is ours: both must still be handled.
#
# The two functions are cut out of the real postinst and run with spies for
# systemctl / deb-systemd-invoke / systemd-run on the PATH.
#
# Run with:  prove -v t/installer/07-postinst-reload.t
use strict;
use warnings;
use Test::More;
use FindBin;
use File::Spec;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

my $ROOT = File::Spec->rel2abs("$FindBin::Bin/../..");
my $POSTINST = "$ROOT/debian/postinst";
plan skip_all => "debian/postinst not found" unless -f $POSTINST;
plan skip_all => "bash not available" if system("command -v bash >/dev/null 2>&1") != 0;

my $tmp = tempdir(CLEANUP => 1);
my $bin = "$tmp/bin"; make_path($bin);
my $log = "$tmp/calls.log";
for my $name (qw(systemctl deb-systemd-invoke systemd-run)) {
    open(my $f, '>', "$bin/$name") or die;
    # is-active answers "not active" (rc 1) unless IS_ACTIVE_RC says otherwise;
    # everything else succeeds. Every call is logged as "<name> <args>".
    print $f "#!/bin/sh\necho \"$name \$*\" >> '$log'\n"
           . "case \"\$1\" in is-active) exit \"\${IS_ACTIVE_RC:-1}\";; esac\nexit 0\n";
    close $f; chmod 0755, "$bin/$name";
}

sub run_fn {
    my ($call, %env) = @_;
    unlink $log;
    my $script = "$tmp/case.sh";
    open(my $o, '>', $script) or die;
    print $o <<"SH";
eval "\$(sed -n '/^BROKER_UNIT=/p;/^enable_broker() {/,/^}/p;/^restart_proxmox_services() {/,/^}/p' '$POSTINST')"
have_systemd() { return 0; }
sleep() { :; }
$call
SH
    close $o;
    my $envs = join(' ', map { "$_='$env{$_}'" } sort keys %env);
    my $out = `env PATH='$bin':\$PATH $envs bash $script 2>&1`;
    my $calls = '';
    if (open(my $f, '<', $log)) { local $/; $calls = <$f>; close $f }
    return ($out, $calls);
}

# --- the immediate reload list ------------------------------------------------
{
    my ($out, $calls) = run_fn('restart_proxmox_services');
    unlike($calls, qr/\b(?:pvedaemon|pvestatd|pvescheduler)\b/,
        '(a) no reload of pvedaemon / pvestatd / pvescheduler by the postinst (the pve-manager trigger does it once)');
    like($calls, qr/^deb-systemd-invoke reload-or-try-restart pve-ha-crm\.service$/m,
        '(b) pve-ha-crm is still reloaded (the trigger does not cover it)');
    like($calls, qr/^deb-systemd-invoke reload-or-try-restart pve-ha-lrm\.service$/m,
        '    ...and pve-ha-lrm');
    like($calls, qr/systemd-run .*--unit=truenas-pveproxy-restart .*reload-or-try-restart pveproxy/,
        'pveproxy keeps its deferred reload');
}

# --- the broker is handled as before ---------------------------------------------
{
    my ($out, $calls) = run_fn('enable_broker');
    like($calls, qr/^systemctl start truenas-plugin-broker\.service$/m,
        '(c) broker not active: started');
    ($out, $calls) = run_fn('enable_broker', IS_ACTIVE_RC => 0);
    like($calls, qr/^systemctl try-restart truenas-plugin-broker\.service$/m,
        '    broker active: try-restart, picking up a new binary');
}

# --- TRUENAS_PLUGIN_NO_RESTART=1 ----------------------------------------------------
{
    my ($out, $calls) = run_fn('restart_proxmox_services', TRUENAS_PLUGIN_NO_RESTART => 1);
    is($calls, '', 'NO_RESTART=1: nothing is reloaded by the postinst');
    like($out, qr/pve-ha-crm pve-ha-lrm pveproxy/, '  ...and the manual command names the HA daemons and pveproxy');
    like($out, qr/trigger still reloads pvedaemon, pvestatd, pvescheduler/,
        '  ...and says the pve-manager trigger still reloads the other three');
}

done_testing;
