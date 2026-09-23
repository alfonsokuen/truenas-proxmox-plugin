#!/usr/bin/perl
# install.sh edits storage.cfg directly instead of going through the PVE
# storage API, so TrueNASPlugin.pm's own on_add_hook()/on_update_hook_full()
# (which write secrets to /etc/pve/priv/storage) never run for a storage
# created or edited by this installer. Kimi found (critical): the
# "automated provisioning" creation flow inside menu_configure_storage()
# did a raw `echo "$config" >> "$STORAGE_CFG"`, bypassing BOTH
# add_storage_config() and write_priv_secret() entirely - since
# generate_storage_config() no longer puts tn_api_key inline at all, that
# flow created a storage with its key in NEITHER storage.cfg NOR
# /etc/pve/priv/storage. The other two creation/edit flows (guided
# wizard, reconfigure) had already been fixed to call write_priv_secret()
# - just in the wrong order (after publishing, not before) until a
# separate fix.
#
# This file pins two things a full interactive-wizard simulation would be
# expensive and flaky to cover, at much lower cost:
#
#   - STATIC: every place install.sh writes storage.cfg's bytes
#     (`>> "$STORAGE_CFG"`) has a write_priv_secret() call textually
#     before it, close enough to be the same code path - a regression
#     guard against the exact bug class Kimi found (a new ad-hoc publish
#     site that forgets to write the secret first);
#   - BEHAVIORAL: write_priv_secret() (real function, sourced from
#     install.sh) actually writes atomically, and
#     get_storage_config_value()/get_all_storage_config_values() actually
#     read priv before inline, and remove_storage_config() actually
#     deletes all four possible secret files - the primitives every
#     creation/edit flow is built on, exercised directly rather than
#     through three different interactive prompts.
#
# TRUENAS_TEST_STORAGE_CFG / TRUENAS_TEST_PRIV_DIR (install.sh) point
# STORAGE_CFG/TRUENAS_PRIV_DIR at a scratch directory - production runs
# leave both unset and get the real /etc/pve paths untouched.
#
# Run with:  prove -v t/installer/02-priv-secret-ordering.t

use strict;
use warnings;
use Test::More;
use FindBin;
use File::Spec;
use File::Temp qw(tempdir);

my $SCRIPT = File::Spec->rel2abs("$FindBin::Bin/../../install.sh");
plan skip_all => "install.sh not found at $SCRIPT" unless -f $SCRIPT;

for my $tool (qw(bash)) {
    plan skip_all => "$tool not available" if system("command -v $tool >/dev/null 2>&1") != 0;
}

# ------------------------------------------------------------- STATIC ---
{
    open(my $fh, '<', $SCRIPT) or die "cannot read $SCRIPT: $!";
    my @lines = <$fh>;
    close($fh);

    # add_storage_config()'s own body contains the same
    # `echo "$config" >> "$STORAGE_CFG"` shape - that one is fine as-is:
    # it's the vetted, shared primitive every OTHER call site delegates
    # to, and its own callers are the ones responsible for calling
    # write_priv_secret() first (checked below). Exclude its own line
    # range from the regression guard, or this test would have to demand
    # write_priv_secret() call itself, which makes no sense.
    my ($add_start, $add_end);
    for my $i (0 .. $#lines) {
        if (!defined($add_start) && $lines[$i] =~ /^add_storage_config\(\)\s*\{/) {
            $add_start = $i;
        } elsif (defined($add_start) && !defined($add_end) && $lines[$i] =~ /^\}/) {
            $add_end = $i;
        }
    }
    ok(defined($add_start) && defined($add_end),
        'sanity: found add_storage_config()\'s own line range to exclude from the guard below');

    my @publish_lines;
    for my $i (0 .. $#lines) {
        next if defined($add_start) && $i >= $add_start && $i <= $add_end;
        push @publish_lines, $i
            if $lines[$i] =~ /^\s*echo\s+"\$config"\s*>>\s*"\$STORAGE_CFG"/;
    }
    ok(scalar(@publish_lines) >= 1,
        'sanity: found at least one OTHER raw `echo "$config" >> "$STORAGE_CFG"` publish site '
      . '(if this is 0, the automated-provisioning flow was rewritten - update this test, do not just delete it)');

    for my $i (@publish_lines) {
        my $window_start = $i - 20 < 0 ? 0 : $i - 20;
        my $window = join('', @lines[$window_start .. $i]);
        my $lineno = $i + 1;
        like($window, qr/write_priv_secret\s+"\$storage_name"/,
            "line $lineno: a raw storage.cfg publish has write_priv_secret() within the preceding 20 lines");
    }

    # The two vetted, shared publish primitives don't need to call
    # write_priv_secret() themselves - every CALLER already did, right
    # before invoking them. Confirm both still exist as named functions,
    # so the regression guard above stays meaningful (it would be
    # vacuously true if these were inlined away).
    my $body = join('', @lines);
    like($body, qr/^add_storage_config\(\)\s*\{/m, 'add_storage_config() still exists as a shared function');
    like($body, qr/^update_storage_config\(\)\s*\{/m, 'update_storage_config() still exists as a shared function');
}

# --------------------------------------------------------- BEHAVIORAL ---
# Captures STDOUT only. install.sh's top-level `trap ... EXIT` (registered
# the moment the whole script is sourced, not just its functions) runs
# cleanup_all() on every subshell exit here, which unconditionally prints a
# "restore cursor visibility" ANSI escape to STDERR - harmless in a real
# terminal, but it would corrupt an exact-string comparison against
# anything captured via 2>&1.
sub run_bash_fn {
    my ($env, $script, $call) = @_;
    my $out = `bash -c "$env source '$script' >/dev/null 2>/dev/null; $call" 2>/dev/null`;
    my $rc = $? >> 8;
    return ($rc, $out);
}

SKIP: {
    my $bash_ok = eval { system("bash -c 'source \"$SCRIPT\" 2>/dev/null; exit 0'") == 0 };
    skip 'install.sh cannot be sourced in this shell', 13 unless $bash_ok;

    my $priv_dir   = tempdir(CLEANUP => 1);
    my $cfg_dir    = tempdir(CLEANUP => 1);
    my $backup_dir = tempdir(CLEANUP => 1);
    my $log_dir    = tempdir(CLEANUP => 1);
    my $cfg_file   = "$cfg_dir/storage.cfg";
    open(my $fh, '>', $cfg_file) or die $!;
    close($fh);

    my $env = "TRUENAS_TEST_PRIV_DIR='$priv_dir' TRUENAS_TEST_STORAGE_CFG='$cfg_file' "
      . "TRUENAS_TEST_BACKUP_DIR='$backup_dir' TRUENAS_TEST_LOG_FILE='$log_dir/installer.log'";

    # write_priv_secret(): writes the file, atomically, mode 0600.
    {
        my ($rc, $out) = run_bash_fn($env, $SCRIPT,
            q{write_priv_secret tn-test pw SECRET-VALUE-1});
        is($rc, 0, 'write_priv_secret: succeeds') or diag("rc=$rc out=$out");
    }
    my $pw_file = "$priv_dir/tn-test.pw";
    ok(-f $pw_file, 'write_priv_secret: the .pw file exists after the call');
    {
        open(my $rfh, '<', $pw_file) or die $!;
        my $line = <$rfh>;
        close($rfh);
        chomp $line;
        is($line, 'SECRET-VALUE-1', '  ...with exactly the given value');
    }
  SKIP: {
        # Same filesystem-capability probe as t/nvme/24-sensitive-secrets.t:
        # some filesystems (NTFS through a Windows/MSYS mount, notably)
        # don't enforce Unix permission bits at all.
        my $probe = "$priv_dir/.permprobe";
        open(my $pfh, '>', $probe) or die $!;
        close($pfh);
        chmod(0600, $probe);
        my $enforces_perms = (((stat($probe))[2] // 0) & 07777) == 0600;
        unlink($probe);
        skip 'filesystem does not enforce Unix permission bits', 1 unless $enforces_perms;

        my $mode = sprintf('%04o', (stat($pw_file))[2] & 07777);
        is($mode, '0600', '  ...mode 0600');
    }
    {
        # No tmp file left behind after a successful write.
        opendir(my $dh, $priv_dir) or die $!;
        my @leftover = grep { /\.tmp\./ } readdir($dh);
        closedir($dh);
        is(scalar(@leftover), 0, 'write_priv_secret: no leftover tmp file after a successful write');
    }

    # get_storage_config_value(): priv wins over inline.
    {
        open(my $cfh, '>', $cfg_file) or die $!;
        print $cfh "truenasplugin: tn-test\n\ttn_api_host 192.0.2.1\n\ttn_api_key STALE-INLINE\n\ttn_dataset tank/pve\n";
        close($cfh);

        my (undef, $out) = run_bash_fn($env, $SCRIPT,
            q{get_storage_config_value tn-test tn_api_key});
        chomp $out;
        is($out, 'SECRET-VALUE-1',
            'get_storage_config_value: priv wins over a stale inline duplicate');
    }
    {
        open(my $cfh, '>', $cfg_file) or die $!;
        print $cfh "truenasplugin: tn-legacy\n\ttn_api_host 192.0.2.1\n\ttn_api_key INLINE-ONLY\n\ttn_dataset tank/pve\n";
        close($cfh);

        my (undef, $out) = run_bash_fn($env, $SCRIPT,
            q{get_storage_config_value tn-legacy tn_api_key});
        chomp $out;
        is($out, 'INLINE-ONLY',
            'get_storage_config_value: falls back to inline when there is no priv file (unmigrated storage)');
    }

    # remove_storage_config(): deletes all four possible priv files.
    {
        for my $suffix (qw(pw chap dhchap dhchapctrl)) {
            run_bash_fn($env, $SCRIPT, qq{write_priv_secret tn-del $suffix VALUE-$suffix});
        }
        ok(-f "$priv_dir/tn-del.dhchap", 'sanity: tn-del has all four priv files before removal');

        open(my $cfh, '>', $cfg_file) or die $!;
        print $cfh "truenasplugin: tn-del\n\ttn_api_host 192.0.2.1\n\ttn_dataset tank/pve\n";
        close($cfh);

        run_bash_fn($env, $SCRIPT, q{remove_storage_config tn-del >/dev/null 2>&1});

        for my $suffix (qw(pw chap dhchap dhchapctrl)) {
            ok(!-f "$priv_dir/tn-del.$suffix",
                "remove_storage_config: deletes the .$suffix priv file");
        }
    }
}

done_testing();
