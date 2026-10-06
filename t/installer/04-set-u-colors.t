#!/usr/bin/perl
# install.sh runs under `set -u`; detect_color_support read $TERM, $SSH_CLIENT,
# $SSH_TTY and $SSH_CONNECTION bare, so with none of them set (cron, a minimal
# ssh command, a container) it died with "SSH_CLIENT: unbound variable" before
# printing anything.
#
# Run with:  prove -v t/installer/04-set-u-colors.t
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
my $path = $ENV{PATH};

sub run_clean {
    my ($extra) = @_;
    my $script = "$tmp/c.sh";
    open(my $o, '>', $script) or die;
    print $o "source '$SCRIPT'\necho \"COLOR=\$(detect_color_support)\"\n";
    close $o;
    my $env = "TRUENAS_TEST_STORAGE_CFG='$tmp/s' TRUENAS_TEST_PRIV_DIR='$tmp/p' TRUENAS_TEST_BACKUP_DIR='$tmp/b' "
            . "TRUENAS_TEST_LOG_FILE='$tmp/l' $extra";
    # env -i: no TERM, no COLORTERM, no SSH_*; stdin/stdout are not terminals
    my $out = `env -i PATH='$path' $env bash $script 2>&1 </dev/null`;
    return $out;
}

my $out = run_clean('');
unlike($out, qr/unbound variable/, 'no TERM, no SSH_*: install.sh does not die on an unbound variable');
like($out, qr/COLOR=\w+/, '  ...and detect_color_support answers');

$out = run_clean("SSH_CLIENT='198.51.100.1 22 22'");
like($out, qr/COLOR=256/, 'an ssh session still gets 256 colours');
$out = run_clean("TERM=xterm");
like($out, qr/COLOR=\w+/, 'a plain TERM still works');
unlike($out, qr/unbound variable/, '  ...without unbound variables');

# (the prune-orphan-cloudinit dispatch is executed, not grepped, in 05-help-runs-nothing.t)

done_testing;
