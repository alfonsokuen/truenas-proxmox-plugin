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
    my $out = `bash -c "$env source '$SCRIPT' >/dev/null 2>/dev/null; $stub $call" 2>/dev/null`;
    return $out // '';
}

my $out = run_fn('1:2.1.23~beta8+idk22', 'if github_api_call /releases/latest; then echo RC=0; else echo RC=1; fi');
unlike($out, qr/NETWORK/, 'fork build: no request goes to upstream GitHub');
like($out, qr/RC=1/, '  ...and the lookup fails instead of pretending');

$out = run_fn('2.1.23~beta8', 'if github_api_call /releases/latest; then echo RC=0; else echo RC=1; fi');
like($out, qr/NETWORK/, 'upstream build: the lookup still happens (guard is fork-only)');

open(my $fh, '>', $idk_src) or die; close $fh;
$out = run_fn('1:2.1.23~beta8+idk22', 'get_install_source');
like($out, qr/^apt$/m, "the fork's -idk.sources counts as an APT install");
unlink $idk_src;
$out = run_fn('1:2.1.23~beta8+idk22', 'get_install_source');
like($out, qr/^dpkg$/m, 'without either sources file it is a bare dpkg install');

done_testing;
