#!/usr/bin/perl
# On a node running the fork's build (+idkN) the packaged install.sh must not
# fetch upstream releases (it would copy upstream's TrueNASPlugin.pm over the
# fork's) and must recognise the fork's own APT source file.
#
# Run with:  prove -v t/installer/03-fork-guard.t
use strict;
use warnings;
use Test::More;
use FindBin;
use File::Spec;
use File::Temp qw(tempdir);

my $SCRIPT = File::Spec->rel2abs("$FindBin::Bin/../../install.sh");
plan skip_all => "install.sh not found" unless -f $SCRIPT;
plan skip_all => "bash not available" if system("command -v bash >/dev/null 2>&1") != 0;
my $tmp = tempdir(CLEANUP => 1);
my $idk_src = "$tmp/truenas-proxmox-plugin-idk.sources";

sub run_fn {
    my ($dpkg_version, $call) = @_;
    my $stub = defined $dpkg_version
        ? qq{dpkg-query() { printf '%s' '$dpkg_version'; }; dpkg() { return 0; }; download_stdout() { echo NETWORK; };}
        : qq{dpkg-query() { return 1; }; dpkg() { return 1; }; download_stdout() { echo NETWORK; };};
    my $env = "TRUENAS_TEST_STORAGE_CFG='$tmp/s.cfg' TRUENAS_TEST_PRIV_DIR='$tmp/p' "
            . "TRUENAS_TEST_BACKUP_DIR='$tmp/b' TRUENAS_TEST_LOG_FILE='$tmp/l' "
            . "TRUENAS_TEST_APT_SOURCES_IDK='$idk_src' TRUENAS_TEST_APT_SOURCES='$tmp/none.sources'";
    my $script = "$tmp/case.sh";
    open(my $o, '>', $script) or die;
    print $o "source '$SCRIPT' >/dev/null 2>/dev/null\nset +e +u\n$stub\n$call\n";
    close $o;
    my $out = `env $env bash $script 2>/dev/null`;
    return $out // '';
}

my $out = run_fn('1:2.1.23~beta8+idk22', 'if github_api_call /releases/latest; then echo RC=0; else echo RC=1; fi');
unlike($out, qr/NETWORK/, 'fork build: no request goes to upstream GitHub');
like($out, qr/RC=1/, '  ...and the lookup fails instead of pretending');

$out = run_fn('2.1.23~beta8', 'if github_api_call /releases/latest; then echo RC=0; else echo RC=1; fi');
like($out, qr/NETWORK/, 'upstream build: the lookup still happens (guard is fork-only)');

# idk23 onward: the fork version embeds upstream's own "+deb1" suffix
# (1:2.1.23+deb1+idk23). The guard keys on +idkN, so it must still fire on it,
# and upstream's stable 2.1.23+deb1 (which also contains a '+') must not be
# mistaken for a fork build.
$out = run_fn('1:2.1.23+deb1+idk23', 'if github_api_call /releases/latest; then echo RC=0; else echo RC=1; fi');
unlike($out, qr/NETWORK/, 'idk23 (1:2.1.23+deb1+idk23): no request goes to upstream GitHub');
like($out, qr/RC=1/, '  ...and the lookup fails instead of pretending');
$out = run_fn('2.1.23+deb1', 'if github_api_call /releases/latest; then echo RC=0; else echo RC=1; fi');
like($out, qr/NETWORK/, "upstream's stable 2.1.23+deb1 is not a fork build: the lookup still happens");

open(my $fh, '>', $idk_src) or die; close $fh;
$out = run_fn('1:2.1.23~beta8+idk22', 'get_install_source');
like($out, qr/^apt$/m, "the fork's -idk.sources counts as an APT install");
unlink $idk_src;
$out = run_fn('1:2.1.23~beta8+idk22', 'get_install_source');
like($out, qr/^dpkg$/m, 'without either sources file it is a bare dpkg install');

# --- apt bootstrap must not write upstream's repo/key on a fork node --------
{
    my $log = "$tmp/calls.log";
    my $stubs = qq{install() { echo "install \$*" >> '$log'; }; download_file() { echo "download \$*" >> '$log'; return 0; }; }
              . qq{detect_apt_suite() { echo trixie; }; apt-get() { echo "apt-get \$*" >> '$log'; }; };
    unlink $log;
    my $out = run_fn('1:2.1.23~beta8+idk22', "$stubs if apt_bootstrap_install; then echo RC=0; else echo RC=1; fi");
    like($out, qr/RC=1/, 'fork node: apt_bootstrap_install refuses');
    ok(!-e $log || -z $log, '  ...and wrote nothing (no key download, no keyring, no sources file)');

    unlink $log;
    $out = run_fn('2.1.23~beta8', "$stubs apt_bootstrap_install >/dev/null 2>&1; echo done");
    ok(-s $log, 'upstream node: the bootstrap still proceeds (guard is fork-only)');
}

# --- the remote (cluster) update recognises the fork's sources file ---------
{
    my $cap = "$tmp/ssh.txt";
    unlink $cap;
    run_fn('1:2.1.23~beta8+idk22', qq{ssh() { printf '%s' "\$*" > '$cap'; }; install_plugin_on_remote_node_via_apt 192.0.2.5 >/dev/null 2>&1; true});
    open(my $c, '<', $cap) or fail('ssh was not invoked');
    my $script = do { local $/; <$c> } // '';
    like($script, qr/truenas-proxmox-plugin-idk\.sources/, 'remote apt update knows the -idk.sources file');
    like($script, qr/!\s*-f "\$src"\s*&&\s*!\s*-f "\$src_idk"/, '  ...and only refuses when NEITHER source exists');
}

done_testing;
