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
    skip 'install.sh cannot be sourced in this shell', 30 unless $bash_ok;

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

    # --------------------------------------------------------------- R3 ---
    # get_storage_config_value() declared `local config_block value`
    # without initializing $value - under `set -u`, that leaves it UNSET
    # (not empty), and the case statement only assigns $value for
    # tn_api_key/tn_chap_password, so reading any OTHER property hit
    # "value: unbound variable" and aborted the whole script.
    {
        open(my $cfh, '>', $cfg_file) or die $!;
        print $cfh "truenasplugin: tn-r3\n\ttn_api_host 192.0.2.9\n\ttn_dataset tank/pve\n";
        close($cfh);

        my ($rc, $out) = run_bash_fn($env, $SCRIPT,
            q{get_storage_config_value tn-r3 tn_api_host});
        chomp $out;
        is($rc, 0, 'R3: reading a non-secret property does not abort under set -u')
            or diag("rc=$rc out=$out");
        is($out, '192.0.2.9', '  ...and returns the right value');
    }

    # --------------------------------------------------------------- R4 ---
    # get_all_storage_config_values() piped several greps together under
    # `set -euo pipefail`; any of them finding no match (exit 1) aborted
    # the WHOLE function before it ever reached the priv-file fallback -
    # exactly the case for a migrated storage (no tn_api_key inline at
    # all) or a legacy one that never configured CHAP.
    {
        # (a) migrated: no tn_api_key inline, only in priv.
        run_bash_fn($env, $SCRIPT, q{write_priv_secret tn-r4a pw MIGRATED-KEY});
        open(my $cfh, '>', $cfg_file) or die $!;
        print $cfh "truenasplugin: tn-r4a\n\ttn_api_host 192.0.2.10\n\ttn_dataset tank/pve\n";
        close($cfh);
        my ($rc_a, $out_a) = run_bash_fn($env, $SCRIPT, q{get_all_storage_config_values tn-r4a});
        is($rc_a, 0, 'R4a: a migrated storage (no inline tn_api_key) does not abort') or diag($out_a);
        like($out_a, qr/^tn_api_key=MIGRATED-KEY$/m, '  ...and the priv key still comes through');

        # (b) legacy, no CHAP ever configured: tn_chap_password absent
        # both inline and in priv.
        open($cfh, '>', $cfg_file) or die $!;
        print $cfh "truenasplugin: tn-r4b\n\ttn_api_host 192.0.2.11\n\ttn_api_key INLINE-B\n\ttn_dataset tank/pve\n";
        close($cfh);
        my ($rc_b, $out_b) = run_bash_fn($env, $SCRIPT, q{get_all_storage_config_values tn-r4b});
        is($rc_b, 0, 'R4b: legacy storage with no CHAP at all does not abort') or diag($out_b);
        like($out_b, qr/^tn_api_key=INLINE-B$/m, '  ...inline key still comes through');
        unlike($out_b, qr/tn_chap_password/, '  ...and no tn_chap_password line is fabricated');

        # (c) legacy, everything inline (pre-idk21 storage, never migrated).
        open($cfh, '>', $cfg_file) or die $!;
        print $cfh "truenasplugin: tn-r4c\n\ttn_api_host 192.0.2.12\n\ttn_api_key INLINE-C\n"
          . "\ttn_chap_password CHAP-C\n\ttn_dataset tank/pve\n";
        close($cfh);
        my ($rc_c, $out_c) = run_bash_fn($env, $SCRIPT, q{get_all_storage_config_values tn-r4c});
        is($rc_c, 0, 'R4c: fully legacy (inline) storage does not abort') or diag($out_c);
        like($out_c, qr/^tn_api_key=INLINE-C$/m, '  ...inline key present');
        like($out_c, qr/^tn_chap_password=CHAP-C$/m, '  ...inline CHAP present');
    }

    # --------------------------------------------------------------- R2 ---
    # remove_storage_config() used to `mv "$temp_file" "$STORAGE_CFG"`
    # with no error check, then delete the priv secrets regardless of
    # whether that mv actually succeeded - a failed publish (disk full,
    # permission issue) still lost the key. Shadow `mv` with a function
    # that always fails, sourced AFTER install.sh so it overrides the
    # builtin lookup, and confirm the priv files survive.
    {
        run_bash_fn($env, $SCRIPT, q{write_priv_secret tn-r2 pw SURVIVES});
        open(my $cfh, '>', $cfg_file) or die $!;
        print $cfh "truenasplugin: tn-r2\n\ttn_api_host 192.0.2.13\n\ttn_dataset tank/pve\n";
        close($cfh);

        # install.sh runs under `set -euo pipefail`, inherited by this
        # sourcing shell - a bare `remove_storage_config tn-r2` returning
        # 1 would abort the whole one-liner before the echo below ever
        # ran. An if/else condition is exempt from `set -e` (same reason
        # every other call site in install.sh itself checks this
        # function's result with `if`/`||`, never bare).
        my $out = `bash -c "$env source '$SCRIPT' >/dev/null 2>/dev/null; mv() { return 1; }; if remove_storage_config tn-r2; then rc=0; else rc=\\\$?; fi; echo RC=\\\$rc" 2>/dev/null`;
        my ($rc_line) = $out =~ /RC=(\d+)/;
        is($rc_line, '1', 'R2: remove_storage_config reports failure when mv fails')
            or diag("output was: $out");
        is(call_cat("$priv_dir/tn-r2.pw"), 'SURVIVES',
            '  ...and the priv secret is NOT deleted when storage.cfg could not be updated');
    }

    # ------------------------------------------------------------- F2 ---
    # generate_storage_config()'s new (optional) 14th argument: only when
    # a caller passes it non-empty does the generated block carry
    # tn_api_key inline at all. Every existing call site (guided create,
    # automated provisioning) never passes it - confirm the default
    # behavior (omit tn_api_key) is completely unchanged.
    {
        my (undef, $out_default) = run_bash_fn($env, $SCRIPT,
            q{generate_storage_config tn-gen 192.0.2.20 UNUSED tank/pve iqn.test 192.0.2.20:3260});
        unlike($out_default, qr/^\ttn_api_key\b/m,
            'F2: generate_storage_config omits tn_api_key by default, same as before this fix');

        my (undef, $out_inline) = run_bash_fn($env, $SCRIPT,
            q{generate_storage_config tn-gen 192.0.2.20 UNUSED tank/pve iqn.test 192.0.2.20:3260 } .
            q{16K 1 '' '' iscsi '' '' INLINE-SYNCED-KEY});
        like($out_inline, qr/^\ttn_api_key INLINE-SYNCED-KEY$/m,
            'F2: generate_storage_config writes tn_api_key inline when the 14th arg is given '
          . '(menu_edit_storage on an unready cluster with a pre-existing inline copy)');
    }

    # storage_has_inline_secret(): does storage.cfg currently carry an
    # inline copy of a given key for a given storage? This is what
    # menu_edit_storage() checks BEFORE regenerating a storage's section,
    # to decide whether the F2 14th argument above is needed at all.
    {
        open(my $cfh, '>', $cfg_file) or die $!;
        print $cfh "truenasplugin: tn-inline\n\ttn_api_host 192.0.2.21\n\ttn_api_key HAS-ONE\n\ttn_dataset tank/pve\n";
        print $cfh "truenasplugin: tn-noinline\n\ttn_api_host 192.0.2.22\n\ttn_dataset tank/pve\n";
        close($cfh);

        my ($rc_yes) = run_bash_fn($env, $SCRIPT,
            q{storage_has_inline_secret tn-inline tn_api_key});
        is($rc_yes, 0, 'F2: storage_has_inline_secret finds an existing inline tn_api_key');

        my ($rc_no) = run_bash_fn($env, $SCRIPT,
            q{storage_has_inline_secret tn-noinline tn_api_key});
        isnt($rc_no, 0, '  ...and reports false for a storage with no inline copy (already migrated)');

        my ($rc_missing) = run_bash_fn($env, $SCRIPT,
            q{storage_has_inline_secret tn-does-not-exist tn_api_key});
        isnt($rc_missing, 0, '  ...and false, not a crash, for a storage that does not even exist');
    }

    # tn_installer_cluster_ready(): shadows `perl` the same way the R2
    # block above shadows `mv` - install.sh's real perl invocation needs a
    # live PVE::Storage::Custom::TrueNASPlugin to answer meaningfully,
    # which this test environment does not have; what matters here is
    # that the bash wrapper interprets that perl call's stdout correctly,
    # and fails CLOSED on anything that is not an exact "1".
    {
        my $out = `bash -c "$env source '$SCRIPT' >/dev/null 2>/dev/null; perl() { echo 1; }; if tn_installer_cluster_ready; then rc=0; else rc=\\\$?; fi; echo RC=\\\$rc" 2>/dev/null`;
        my ($rc) = $out =~ /RC=(\d+)/;
        is($rc, '0', 'F2: tn_installer_cluster_ready is ready when the perl check prints exactly "1"');

        $out = `bash -c "$env source '$SCRIPT' >/dev/null 2>/dev/null; perl() { echo 0; }; if tn_installer_cluster_ready; then rc=0; else rc=\\\$?; fi; echo RC=\\\$rc" 2>/dev/null`;
        ($rc) = $out =~ /RC=(\d+)/;
        is($rc, '1', '  ...not ready when the perl check prints "0"');

        $out = `bash -c "$env source '$SCRIPT' >/dev/null 2>/dev/null; perl() { exit 1; }; if tn_installer_cluster_ready; then rc=0; else rc=\\\$?; fi; echo RC=\\\$rc" 2>/dev/null`;
        ($rc) = $out =~ /RC=(\d+)/;
        is($rc, '1', '  ...fails CLOSED (not ready) when perl itself fails, instead of dying or defaulting to ready');

        # G1 (QA round 6, Codex): stdout=="1" alone used to be enough,
        # regardless of perl's own exit status - `printf 1; exit 1` (a
        # partial success: the print ran, then something afterwards
        # failed) was being read as READY. Both must hold now.
        $out = `bash -c "$env source '$SCRIPT' >/dev/null 2>/dev/null; perl() { printf 1; exit 1; }; if tn_installer_cluster_ready; then rc=0; else rc=\\\$?; fi; echo RC=\\\$rc" 2>/dev/null`;
        ($rc) = $out =~ /RC=(\d+)/;
        is($rc, '1', '  ...G1: stdout "1" with a non-zero perl exit is NOT ready - both must agree');
    }
}

sub call_cat {
    my ($path) = @_;
    open(my $fh, '<', $path) or return undef;
    my $line = <$fh>;
    close($fh);
    chomp $line if defined $line;
    return $line;
}

# ------------------------------------------------------------------ K5 ---
# menu_edit_storage() writes the NEW key to priv before calling
# update_storage_config() (H5's ordering). If that update then fails, the
# rotation must be rolled back - otherwise priv has the NEW key while
# storage.cfg still describes the OLD configuration, a half-applied edit.
# Full interactive coverage would need to drive menu_edit_storage()'s TTY
# prompts; this pins the fix as a static regression guard instead, the
# same technique the K1 guard above uses.
my $menu_edit_storage_body;
{
    open(my $fh, '<', $SCRIPT) or die "cannot read $SCRIPT: $!";
    my $body = do { local $/; <$fh> };
    close($fh);

    if ($body =~ /^menu_edit_storage\(\)\s*\{(.*?)^\}/ms) {
        $menu_edit_storage_body = $1;
        like($menu_edit_storage_body, qr/had_previous_key/,
            'K5: menu_edit_storage() captures whether a previous priv key existed before rotating');
        like($menu_edit_storage_body, qr/write_priv_secret "\$storage_name" "pw" "\$previous_key"/,
            '  ...and restores it specifically on update_storage_config failure');
    } else {
        fail('K5: could not find menu_edit_storage() to check for the rollback');
    }
}

# ------------------------------------------------------------------ C3 ---
# Two follow-on bugs in the K5 rollback itself:
#   - "restore" when there was no PREVIOUS key (file absent, or present
#     but empty) must DELETE the .pw file - calling write_priv_secret()
#     with an empty value is a silent no-op by that function's own
#     contract (see write_priv_secret()'s own comment), which would have
#     left the NEW (rotated) key in place while claiming the rollback
#     succeeded;
#   - if READING the previous key fails (not "absent", a genuine I/O
#     error), there is no safe value to roll back to - abort BEFORE the
#     NEW key is ever written, not after.
SKIP: {
    skip 'menu_edit_storage() body not extracted above', 2 if !defined($menu_edit_storage_body);

    like($menu_edit_storage_body,
        qr/if \[\[ "\$had_previous_key" == true && -n "\$previous_key" \]\]/,
        'C3: rollback restore-vs-delete decision requires $previous_key non-empty, not just "a file existed" '
      . '(had_previous_key alone would call write_priv_secret() with an empty value - a silent no-op - '
      . 'instead of deleting the file)');
    like($menu_edit_storage_body, qr/if\s*!\s*previous_key=\$\(cat "\$priv_file"/,
        'C3: reading the previous key failing is checked before the NEW key is ever written (not silently treated as "empty")');
}

# ------------------------------------------------------------------ F2 ---
# menu_edit_storage() regenerates a storage's ENTIRE section from
# scratch. generate_storage_config() by default omits tn_api_key - so
# without checking, BEFORE generating the new block, whether this storage
# already has an inline copy AND whether the cluster is confirmed
# upgraded, every single reconfigure through this installer would
# unconditionally strip that inline copy, exactly the failure mode
# TrueNASPlugin.pm's own F1 fix (this same QA round) exists to prevent on
# the plugin side - except here it would not even be conditional on
# cluster readiness, it would just always happen.
SKIP: {
    skip 'menu_edit_storage() body not extracted above', 3 if !defined($menu_edit_storage_body);

    like($menu_edit_storage_body, qr/storage_has_inline_secret\s+"\$storage_name"\s+"tn_api_key"/,
        'F2: menu_edit_storage() checks for a pre-existing inline tn_api_key before regenerating the section');
    like($menu_edit_storage_body, qr/tn_installer_cluster_ready/,
        '  ...and asks the same cluster-readiness question the plugin itself asks before stripping one');
    like($menu_edit_storage_body, qr/generate_storage_config\s+"\$storage_name".*"\$inline_api_key"\)/,
        '  ...and threads the decision through to generate_storage_config() as its 14th argument');
}

done_testing();
