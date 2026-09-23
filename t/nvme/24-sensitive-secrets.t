#!/usr/bin/perl
# tn_api_key (a FULL_ADMIN TrueNAS credential), tn_chap_password,
# tn_nvme_dhchap_secret and tn_nvme_dhchap_ctrl_secret used to be plain
# options in storage.cfg - readable via `pvesh get /storage/<id>` by anyone
# holding Datastore.Allocate on /storage, and by the www-data group that
# owns storage.cfg on disk (mode 0640, NOT world-readable - correcting an
# earlier version of this comment that said 0644). tn_api_key was also
# `fixed => 1`, so rotating it meant hand-editing storage.cfg on every
# node. All four are now 'sensitive-properties' (plugindata()):
# PVE::API2::Storage::Config strips them out of the request before
# check_config ever sees it and hands them only to on_add_hook /
# on_update_hook_full / on_delete_hook, which write them to
# /etc/pve/priv/storage/<storeid>.{pw,chap,dhchap,dhchapctrl} (mode 0600) -
# the same mechanism and directory PVE's own PBSPlugin.pm/CIFSPlugin.pm use.
#
# This file pins:
#   - the priv-file read/write/delete roundtrip, and its 0600 permissions;
#   - _tn_api_key()/_tn_chap_password()/_tn_nvme_dhchap_secret()/
#     _tn_nvme_dhchap_ctrl_secret() priority: priv file wins over an inline
#     scfg value, so a rotated secret can't be shadowed by a stale leftover
#     in storage.cfg;
#   - _tn_api_key() falls back to scfg for a cluster that has not migrated
#     yet, and dies with a clear, actionable message when neither exists;
#   - the other three never die (all optional) - absence just means "no
#     CHAP/DHCHAP auth", same as before this file existed;
#   - on_add_hook() refuses to create a storage with no API key, and stores
#     one that is given; the three optional secrets are stored only if
#     present;
#   - on_update_hook_full() rotates the key, refuses to delete it (a
#     TrueNAS storage cannot run without one, unlike CIFS's password which
#     falls back to a guest mount), and allows deleting any of the three
#     optional secrets;
#   - on_delete_hook() removes all four priv files, and is a no-op if they
#     were never created;
#   - migrate_priv_secrets()/migrate_secrets_cli(): moves all inline
#     secrets to the priv files, is idempotent, --dry-run never writes, a
#     non-truenasplugin storage is refused, a priv value that DIFFERS from
#     a stale inline duplicate is kept (never overwritten) and reported,
#     and a real (non---dry-run) migration refuses to run unless every
#     cluster node can be confirmed to run a plugin that reads priv files -
#     idk20 and older require tn_api_key inline and silently SKIP the
#     section without it;
#   - _tn_redact_for_log() strips known-sensitive JSON keys (api_key,
#     dhchap_key, dhchap_ctrl_key, ...) before anything reaches the
#     tn_debug=2 log, the same technique tools/truenas-plugin-broker uses;
#   - the process-local secret cache: a write in THIS process is visible to
#     the very next read in the same process, never masked by a value
#     cached before the write.
#
# Run with:  prove -v t/nvme/24-sensitive-secrets.t

use strict;
use warnings;
use Test::More;
use FindBin;
use File::Spec;
use File::Temp qw(tempdir);
use JSON::PP qw(encode_json);

my $PLUGIN = File::Spec->rel2abs("$FindBin::Bin/../../TrueNASPlugin.pm");
plan skip_all => "TrueNASPlugin.pm not found at $PLUGIN" unless -f $PLUGIN;

# Same ordering rationale as t/nvme/20-snapshot-import-config.t: load the
# real PVE::Storage first (if present) so a node with the plugin already
# installed under /usr/share/perl5/PVE/Storage/Custom does not clobber the
# file under test.
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

for my $sub (qw(_tn_priv_file _tn_api_key _tn_chap_password
                _tn_nvme_dhchap_secret _tn_nvme_dhchap_ctrl_secret
                on_add_hook on_update_hook on_update_hook_full on_delete_hook
                migrate_priv_secrets migrate_secrets_cli
                _tn_cluster_secrets_ready _tn_redact_for_log)) {
    unless ($PKG->can($sub)) {
        plan tests => 1;
        fail("$sub exists");
        exit 1;
    }
}

# Point the priv-file helpers at a scratch directory so this suite never
# touches a real /etc/pve, on a laptop or on a node alike.
my $PRIV_DIR = tempdir(CLEANUP => 1);
$ENV{TRUENAS_PRIV_DIR} = $PRIV_DIR;

sub call { my ($sub, @args) = @_; no strict 'refs'; return &{"${PKG}::$sub"}(@args); }

# CLI-style wrapper, capturing STDOUT like t/nvme/20's run_cli(). Goes
# through can() rather than a method call: $PKG->$sub_name(...) would
# prepend the class name as the first element of @argv (a plain @argv sub,
# not a method), which would show up as an "unexpected argument" - a bug in
# the test, not the sub under test.
sub capture_cli {
    my ($sub_name, @args) = @_;
    my $capture;
    open(my $oldout, '>&', \*STDOUT) or die $!;
    close(STDOUT); open(STDOUT, '>', \$capture) or die $!;
    my $rc = eval { $PKG->can($sub_name)->(@args) };
    close(STDOUT); open(STDOUT, '>&', $oldout) or die $!;
    return ($rc, $capture);
}

sub file_mode {
    my ($path) = @_;
    my @st = stat($path) or return undef;
    return sprintf('%04o', $st[2] & 07777);
}

# Some filesystems (NTFS through a Windows/MSYS mount, notably) do not
# enforce Unix permission bits at all: chmod(0600, ...) silently no-ops and
# every file reads back as whatever the mount's default is. Detect that
# ONCE, so the mode assertions below are skipped on a filesystem that could
# never make them fail honestly, without weakening them on a real node -
# where they matter, because storage.cfg being 0644 is the entire bug this
# file exists to catch.
my $ENFORCES_PERMS = do {
    my $probe = "$PRIV_DIR/.permprobe";
    open(my $fh, '>', $probe) or die $!;
    close($fh);
    chmod(0600, $probe);
    my @st = stat($probe);
    unlink($probe);
    (($st[2] // 0) & 07777) == 0600;
};

# ------------------------------------------------------- priv file I/O ---
{
    my $file = call('_tn_priv_file', 'tn-store', 'pw');
    is($file, "$PRIV_DIR/tn-store.pw", '_tn_priv_file: builds the expected path');

    is(call('_tn_priv_file', undef, 'pw'), undef,
        '_tn_priv_file: refuses to build a path with no storeid, instead of guessing one');
}

# ---------------------------------------------- on_add_hook / creation ---
{
    my ($ok, $err) = (1, undef);
    eval { call('on_add_hook', $PKG, 'tn-new', {}, ()); 1 } or do { $ok = 0; $err = $@; };
    ok(!$ok, 'on_add_hook: refuses creation with no tn_api_key at all');
    like($err, qr/tn_api_key is required/, '  ...and says so');
}
{
    my $err = eval { call('on_add_hook', $PKG, 'tn-new', {}, tn_api_key => ''); 1 } ? '' : $@;
    like($err, qr/tn_api_key is required/, 'on_add_hook: an empty string is treated as missing, not as a valid key');
}
{
    call('on_add_hook', $PKG, 'tn-new', {}, tn_api_key => '1-abc123');
    my $file = call('_tn_priv_file', 'tn-new', 'pw');
    ok(-f $file, 'on_add_hook: writes the priv file for a valid key');
  SKIP: {
        skip 'filesystem does not enforce Unix permission bits', 1 unless $ENFORCES_PERMS;
        is(file_mode($file), '0600', '  ...mode 0600');
    }
    open(my $fh, '<', $file) or die $!;
    my $line = <$fh>;
    close($fh);
    chomp $line;
    is($line, '1-abc123', '  ...with exactly the given key');

    ok(!-f call('_tn_priv_file', 'tn-new', 'chap'),
        'on_add_hook: no CHAP file written when tn_chap_password was not given');
}
{
    call('on_add_hook', $PKG, 'tn-chap', { tn_chap_user => 'alice' },
        tn_api_key => '1-def456', tn_chap_password => 's3cret');
    my $file = call('_tn_priv_file', 'tn-chap', 'chap');
    ok(-f $file, 'on_add_hook: stores tn_chap_password too when given');
  SKIP: {
        skip 'filesystem does not enforce Unix permission bits', 1 unless $ENFORCES_PERMS;
        is(file_mode($file), '0600', '  ...mode 0600');
    }
}
{
    # Both DHCHAP secrets (NVMe/TCP) at once, same as CHAP above - and on a
    # DIFFERENT priv file each, so they cannot clobber one another or 'pw'/'chap'.
    call('on_add_hook', $PKG, 'tn-dhchap', {},
        tn_api_key => '1-ghi789',
        tn_nvme_dhchap_secret      => 'DHHC-1:01:host-secret:',
        tn_nvme_dhchap_ctrl_secret => 'DHHC-1:01:ctrl-secret:');
    my $host_file = call('_tn_priv_file', 'tn-dhchap', 'dhchap');
    my $ctrl_file = call('_tn_priv_file', 'tn-dhchap', 'dhchapctrl');
    ok(-f $host_file, 'on_add_hook: stores tn_nvme_dhchap_secret');
    ok(-f $ctrl_file, 'on_add_hook: stores tn_nvme_dhchap_ctrl_secret');
    isnt($host_file, $ctrl_file, '  ...in two distinct files, not one shared with the other or with CHAP');
    isnt($host_file, call('_tn_priv_file', 'tn-dhchap', 'chap'), '  ...and distinct from the CHAP suffix too');
}

# --------------------------------------------------------- _tn_api_key ---
{
    my $scfg = { storeid => 'tn-new' };
    is(call('_tn_api_key', $scfg), '1-abc123',
        '_tn_api_key: reads back what on_add_hook wrote to the priv file');
}
{
    # Back-compat: a storage never migrated still has the key inline in
    # storage.cfg (i.e. plain in $scfg, no priv file for it).
    my $scfg = { storeid => 'tn-legacy', tn_api_key => '1-legacy-key' };
    is(call('_tn_api_key', $scfg), '1-legacy-key',
        '_tn_api_key: falls back to $scfg for an unmigrated storage');
}
{
    # Priority: once a priv file exists, it wins even if a stale copy is
    # still sitting in $scfg (e.g. storage.cfg edited by hand afterwards).
    my $scfg = { storeid => 'tn-new', tn_api_key => '1-STALE-COPY' };
    is(call('_tn_api_key', $scfg), '1-abc123',
        '_tn_api_key: the priv file wins over a stale inline value');
}
{
    my $scfg = { storeid => 'tn-missing' };
    my $err = eval { call('_tn_api_key', $scfg); 1 } ? '' : $@;
    like($err, qr/API key missing for storage 'tn-missing'/,
        '_tn_api_key: dies with a clear, storeid-naming message when neither exists');
    like($err, qr/pvesm set tn-missing --tn_api_key/,
        '  ...and gives the exact fix');
    like($err, qr/migrate-secrets tn-missing/,
        '  ...mentioning the migration command too');
}

# --------------------------------------------------- _tn_chap_password ---
{
    my $scfg = { storeid => 'tn-chap' };
    is(call('_tn_chap_password', $scfg), 's3cret',
        '_tn_chap_password: reads back the priv file');
}
{
    my $scfg = { storeid => 'tn-no-chap' };
    is(call('_tn_chap_password', $scfg), undef,
        '_tn_chap_password: never dies for a storage with no CHAP configured');
}
{
    my $scfg = { storeid => 'tn-legacy-chap', tn_chap_password => 'inline-pw' };
    is(call('_tn_chap_password', $scfg), 'inline-pw',
        '_tn_chap_password: falls back to $scfg the same way the API key does');
}

# ------------------------------------------ _tn_nvme_dhchap_{,ctrl_}secret ---
{
    my $scfg = { storeid => 'tn-dhchap' };
    is(call('_tn_nvme_dhchap_secret', $scfg), 'DHHC-1:01:host-secret:',
        '_tn_nvme_dhchap_secret: reads back its own priv file');
    is(call('_tn_nvme_dhchap_ctrl_secret', $scfg), 'DHHC-1:01:ctrl-secret:',
        '_tn_nvme_dhchap_ctrl_secret: reads back its own priv file, not the host one');
}
{
    my $scfg = { storeid => 'tn-no-dhchap' };
    is(call('_tn_nvme_dhchap_secret', $scfg), undef,
        '_tn_nvme_dhchap_secret: never dies (open-access nvme-tcp has none)');
    is(call('_tn_nvme_dhchap_ctrl_secret', $scfg), undef,
        '_tn_nvme_dhchap_ctrl_secret: same');
}
{
    my $scfg = { storeid => 'tn-legacy-dhchap', tn_nvme_dhchap_secret => 'inline-dhchap' };
    is(call('_tn_nvme_dhchap_secret', $scfg), 'inline-dhchap',
        '_tn_nvme_dhchap_secret: falls back to $scfg for an unmigrated storage');
}

# --------------------------------------------------------- rotation/update ---
{
    call('on_update_hook_full', $PKG, 'tn-new', { storeid => 'tn-new' },
        {}, [], { tn_api_key => '1-rotated' });
    is(call('_tn_api_key', { storeid => 'tn-new' }), '1-rotated',
        'on_update_hook_full: rotates the key in the priv file');
}
{
    my $err = eval {
        call('on_update_hook_full', $PKG, 'tn-new', { storeid => 'tn-new' },
            {}, ['tn_api_key'], { tn_api_key => undef });
        1;
    } ? '' : $@;
    like($err, qr/tn_api_key cannot be removed/,
        'on_update_hook_full: refuses to delete the API key outright');
    is(call('_tn_api_key', { storeid => 'tn-new' }), '1-rotated',
        '  ...and the priv file is unchanged after the refusal');
}
{
    ok(-f call('_tn_priv_file', 'tn-chap', 'chap'), 'sanity: CHAP file present before delete');
    call('on_update_hook_full', $PKG, 'tn-chap', { storeid => 'tn-chap' },
        {}, ['tn_chap_password'], { tn_chap_password => undef });
    ok(!-f call('_tn_priv_file', 'tn-chap', 'chap'),
        'on_update_hook_full: DOES allow deleting the CHAP password (optional, unlike the API key)');
}
{
    # DHCHAP host secret rotates like CHAP; the ctrl secret is untouched
    # since $sensitive does not mention it here.
    call('on_update_hook_full', $PKG, 'tn-dhchap', { storeid => 'tn-dhchap' },
        {}, [], { tn_nvme_dhchap_secret => 'DHHC-1:01:rotated:' });
    is(call('_tn_nvme_dhchap_secret', { storeid => 'tn-dhchap' }), 'DHHC-1:01:rotated:',
        'on_update_hook_full: rotates tn_nvme_dhchap_secret independently of the ctrl secret');
    is(call('_tn_nvme_dhchap_ctrl_secret', { storeid => 'tn-dhchap' }), 'DHHC-1:01:ctrl-secret:',
        '  ...which is untouched');
}
{
    ok(-f call('_tn_priv_file', 'tn-dhchap', 'dhchapctrl'), 'sanity: ctrl-secret file present before delete');
    call('on_update_hook_full', $PKG, 'tn-dhchap', { storeid => 'tn-dhchap' },
        {}, ['tn_nvme_dhchap_ctrl_secret'], { tn_nvme_dhchap_ctrl_secret => undef });
    ok(!-f call('_tn_priv_file', 'tn-dhchap', 'dhchapctrl'),
        'on_update_hook_full: allows deleting tn_nvme_dhchap_ctrl_secret (optional)');
    ok(-f call('_tn_priv_file', 'tn-dhchap', 'dhchap'),
        '  ...without touching the still-present host secret');
}
{
    # A `pvesm set` that never touched any sensitive property must not
    # write or delete anything - $sensitive simply does not mention them.
    call('on_update_hook_full', $PKG, 'tn-new', { storeid => 'tn-new' },
        { nodes => 'pve3' }, [], {});
    is(call('_tn_api_key', { storeid => 'tn-new' }), '1-rotated',
        'on_update_hook_full: an unrelated update (e.g. --nodes) leaves the key untouched');
}

# ----------------------------------------------------------- deletion ---
{
    call('on_delete_hook', $PKG, 'tn-new', { storeid => 'tn-new' });
    ok(!-f call('_tn_priv_file', 'tn-new', 'pw'), 'on_delete_hook: removes the priv key file');
}
{
    my $ok = eval { call('on_delete_hook', $PKG, 'tn-new', { storeid => 'tn-new' }); 1 };
    ok($ok, 'on_delete_hook: a second call (file already gone) does not die');
}
{
    ok(-f call('_tn_priv_file', 'tn-dhchap', 'pw'), 'sanity: tn-dhchap has files before delete');
    ok(-f call('_tn_priv_file', 'tn-dhchap', 'dhchap'), '  ...including the DHCHAP host secret');
    call('on_delete_hook', $PKG, 'tn-dhchap', { storeid => 'tn-dhchap' });
    ok(!-f call('_tn_priv_file', 'tn-dhchap', 'pw'), 'on_delete_hook: removes the API key file too');
    ok(!-f call('_tn_priv_file', 'tn-dhchap', 'dhchap'), '  ...and the DHCHAP host secret');
}

# ------------------------------------------------- migrate_priv_secrets ---
SKIP: {
    skip 'PVE::Storage not loadable here', 33 unless eval { require PVE::Storage; 1 };

    my %STORECFG_IDS;
    {
        no strict 'refs';
        no warnings 'redefine';
        *{'PVE::Storage::config'} = sub { return { ids => \%STORECFG_IDS } };
        *{'PVE::Storage::storage_config'} = sub {
            my ($cfg, $storeid) = @_;
            die "storage '$storeid' does not exist\n" if !$cfg->{ids}{$storeid};
            return $cfg->{ids}{$storeid};
        };
        *{'PVE::Storage::write_config'} = sub { return; };
        *{'PVE::Storage::lock_storage_config'} = sub {
            my ($code, $errmsg) = @_;
            eval { $code->() };
            if (my $e = $@) { die $errmsg ? "$errmsg: $e" : $e; }
        };
    }

    # _tn_cluster_secrets_ready() shells out to `pvesh get /nodes` and, per
    # online node, `ssh ... perl -MPVE::Storage::Custom::TrueNASPlugin -e
    # ...`. Stub PVE::Tools::run_command so every scenario below controls
    # exactly what that looks like, without a real cluster or real SSH.
    # $NODES_JSON drives the 'pvesh get /nodes' answer; $NODE_PROBE_OK maps
    # node name -> probe output ('1'/'0'/undef for "ssh itself failed").
    my ($NODES_JSON, %NODE_PROBE_OK);
    {
        no strict 'refs';
        no warnings 'redefine';
        *{'PVE::Tools::run_command'} = sub {
            my ($cmd, %opts) = @_;
            my $out = $opts{outfunc};
            if ($cmd->[0] eq 'pvesh') {
                die "pvesh not stubbed for this scenario\n" if !defined $NODES_JSON;
                $out->($NODES_JSON) if $out;
                return 0;
            }
            if ($cmd->[0] eq 'ssh') {
                my ($node) = grep { /^root\@/ } @$cmd;
                ($node) = $node =~ /^root\@(.+)$/;
                my $answer = $NODE_PROBE_OK{$node};
                die "ssh to $node refused\n" if !defined $answer;
                $out->($answer) if $out;
                return 0;
            }
            die "unexpected command in test stub: @$cmd\n";
        };
    }

    # ---------------------------------------------- _tn_cluster_secrets_ready ---
    {
        # Standalone host: pvesh lists only itself - nothing to verify.
        $NODES_JSON = encode_json([{ node => 'solo', status => 'online' }]);
        my $r = $PKG->_tn_cluster_secrets_ready();
        ok($r->{ready}, '_tn_cluster_secrets_ready: a single-node "cluster" is always ready');
    }
    {
        $NODES_JSON = encode_json([
            { node => 'pve1', status => 'online' },
            { node => 'pve2', status => 'online' },
        ]);
        %NODE_PROBE_OK = (pve1 => '1', pve2 => '1');
        my $r = $PKG->_tn_cluster_secrets_ready();
        ok($r->{ready}, '_tn_cluster_secrets_ready: every online node confirms migrate_priv_secrets exists -> ready');
    }
    {
        $NODES_JSON = encode_json([
            { node => 'pve1', status => 'online' },
            { node => 'pve2', status => 'online' },
        ]);
        # pve2 answers '0': its installed plugin does NOT have
        # migrate_priv_secrets (idk20 or older).
        %NODE_PROBE_OK = (pve1 => '1', pve2 => '0');
        my $r = $PKG->_tn_cluster_secrets_ready();
        ok(!$r->{ready}, '_tn_cluster_secrets_ready: one node too old -> not ready');
        like($r->{reason}, qr/pve2/, '  ...and names it');
    }
    {
        $NODES_JSON = encode_json([
            { node => 'pve1', status => 'online' },
            { node => 'pve3', status => 'offline' },
        ]);
        %NODE_PROBE_OK = (pve1 => '1');
        my $r = $PKG->_tn_cluster_secrets_ready();
        ok(!$r->{ready}, '_tn_cluster_secrets_ready: an offline node cannot be verified -> not ready');
        like($r->{reason}, qr/pve3/, '  ...and names it');
    }
    {
        $NODES_JSON = undef;   # 'pvesh get /nodes' itself fails
        my $r = $PKG->_tn_cluster_secrets_ready();
        ok(!$r->{ready}, '_tn_cluster_secrets_ready: cannot even list nodes -> not ready, not a crash');
    }

    # Every scenario after this point uses a single-node "cluster" so the
    # guard auto-passes without needing --all-nodes-upgraded - the guard
    # itself is fully covered above; what follows tests migration logic.
    $NODES_JSON = encode_json([{ node => 'solo', status => 'online' }]);

    %STORECFG_IDS = (
        'tn-mig' => {
            type => 'truenasplugin', tn_api_host => 'h', tn_dataset => 'd',
            tn_api_key => '1-inline-key', tn_chap_password => 'inline-chap',
            tn_nvme_dhchap_secret => 'inline-dhchap',
            tn_nvme_dhchap_ctrl_secret => 'inline-dhchapctrl',
        },
        'local' => { type => 'dir' },
    );

    # --dry-run: reports what would move, writes nothing, and does not even
    # need the cluster-readiness check (it never writes).
    $NODES_JSON = undef;
    my $dry = $PKG->migrate_priv_secrets('tn-mig', dry_run => 1);
    is(scalar(@{ $dry->{moved} }), 4, 'migrate --dry-run: reports all four secrets as movable');
    ok(exists($STORECFG_IDS{'tn-mig'}{tn_api_key}),
        '  ...and tn_api_key is still inline (nothing written)');
    $NODES_JSON = encode_json([{ node => 'solo', status => 'online' }]);

    # A real (non-dry-run) migration on a multi-node cluster with an
    # unverifiable node is refused outright - this is the H3 guard exercised
    # end-to-end through migrate_priv_secrets(), not just the helper above.
    {
        $NODES_JSON = encode_json([
            { node => 'pve1', status => 'online' },
            { node => 'pve2', status => 'online' },
        ]);
        %NODE_PROBE_OK = (pve1 => '1', pve2 => '0');
        my $err = eval { $PKG->migrate_priv_secrets('tn-mig'); 1 } ? '' : $@;
        like($err, qr/migrate-secrets refused/, 'migrate_priv_secrets: refuses on an unready cluster');
        ok(exists($STORECFG_IDS{'tn-mig'}{tn_api_key}), '  ...and writes nothing');

        # --all-nodes-upgraded overrides the refusal.
        my $forced = $PKG->migrate_priv_secrets('tn-mig', all_nodes_upgraded => 1);
        is(scalar(@{ $forced->{moved} }), 4,
            'migrate_priv_secrets: --all-nodes-upgraded bypasses the check and migrates');
        $NODES_JSON = encode_json([{ node => 'solo', status => 'online' }]);
    }

    is(call('_tn_priv_read', 'tn-mig', 'pw'), '1-inline-key',
        'migrate: the priv file actually has the key');
    is(call('_tn_priv_read', 'tn-mig', 'chap'), 'inline-chap',
        '  ...and the CHAP password');
    is(call('_tn_priv_read', 'tn-mig', 'dhchap'), 'inline-dhchap',
        '  ...and the DHCHAP host secret');
    is(call('_tn_priv_read', 'tn-mig', 'dhchapctrl'), 'inline-dhchapctrl',
        '  ...and the DHCHAP controller secret');

    # Idempotent: nothing left inline, second run moves nothing.
    my $second = $PKG->migrate_priv_secrets('tn-mig');
    is(scalar(@{ $second->{moved} }), 0, 'migrate: second run is a no-op (idempotent)');

    # Wrong storage type: refused, nothing touched.
    my $wrong = $PKG->migrate_priv_secrets('local');
    is($wrong->{type}, 'dir', 'migrate: reports the real type for a non-truenasplugin storage');
    is(scalar(@{ $wrong->{moved} }), 0, '  ...and moves nothing');

    # --------------------------------------------------- H2: priv-vs-inline conflict ---
    {
        # 'tn-conflict' already has a priv .pw with a DIFFERENT value than
        # what is still (stale) inline in storage.cfg - e.g. rotated after
        # migrating, then storage.cfg was hand-edited back to the old key.
        call('on_add_hook', $PKG, 'tn-conflict', {}, tn_api_key => 'PRIV-VALUE');
        %STORECFG_IDS = ('tn-conflict' => {
            type => 'truenasplugin', tn_api_key => 'STALE-INLINE-VALUE',
        });

        my $res = $PKG->migrate_priv_secrets('tn-conflict');
        is($res->{moved}[0]{action}, 'conflict-kept-priv',
            'migrate: priv and inline disagree -> action is conflict-kept-priv');
        is(scalar(@{ $res->{warnings} }), 1, '  ...and a warning is recorded');
        like($res->{warnings}[0], qr/tn_api_key/, '    ...naming the key');
        is(call('_tn_priv_read', 'tn-conflict', 'pw'), 'PRIV-VALUE',
            '  ...priv keeps ITS value - never overwritten by the stale inline one');
        ok(!exists($STORECFG_IDS{'tn-conflict'}{tn_api_key}),
            '  ...and the stale inline copy is still removed from storage.cfg');
    }
    {
        # 'tn-dup' has a priv .pw whose value is IDENTICAL to the inline
        # one - just a redundant leftover, not a conflict.
        call('on_add_hook', $PKG, 'tn-dup', {}, tn_api_key => 'SAME-VALUE');
        %STORECFG_IDS = ('tn-dup' => {
            type => 'truenasplugin', tn_api_key => 'SAME-VALUE',
        });

        my $res = $PKG->migrate_priv_secrets('tn-dup');
        is($res->{moved}[0]{action}, 'duplicate',
            'migrate: priv and inline already agree -> action is duplicate');
        is(scalar(@{ $res->{warnings} }), 0, '  ...no warning, this is not a conflict');
        is(call('_tn_priv_read', 'tn-dup', 'pw'), 'SAME-VALUE', '  ...priv unchanged');
        ok(!exists($STORECFG_IDS{'tn-dup'}{tn_api_key}), '  ...inline duplicate removed');
    }
    {
        # --dry-run must report the conflict/duplicate distinction too,
        # without writing.
        call('on_add_hook', $PKG, 'tn-conflict2', {}, tn_api_key => 'PRIV-VALUE');
        %STORECFG_IDS = ('tn-conflict2' => {
            type => 'truenasplugin', tn_api_key => 'STALE-INLINE-VALUE',
        });
        my $res = $PKG->migrate_priv_secrets('tn-conflict2', dry_run => 1);
        is($res->{moved}[0]{action}, 'conflict-kept-priv',
            'migrate --dry-run: reports the conflict too');
        ok(exists($STORECFG_IDS{'tn-conflict2'}{tn_api_key}), '  ...without writing anything');
    }

    # CLI wrapper, capturing STDOUT/STDERR like t/nvme/20's run_cli().
    %STORECFG_IDS = (
        'tn-cli' => { type => 'truenasplugin', tn_api_key => '1-cli-key' },
    );
    my ($rc, $out) = capture_cli('migrate_secrets_cli', 'tn-cli', '--dry-run');
    is($rc, 0, 'migrate_secrets_cli --dry-run: exit 0');
    like($out, qr/\[dry-run\]/, '  ...marks the output as a dry run');
    ok(exists($STORECFG_IDS{'tn-cli'}{tn_api_key}), '  ...and did not actually move anything');
}

# ---------------------------------------------------- H4: on_update_hook ---
# Legacy shape (api() < 13): PVE hands this no live $scfg at all, only the
# CHANGED properties. It must still write the rotated key to priv - it just
# cannot strip a stale inline copy, since it has nothing to strip it from.
{
    call('on_add_hook', $PKG, 'tn-legacy-api', {}, tn_api_key => 'FIRST-KEY');
    call('on_update_hook', $PKG, 'tn-legacy-api', {}, tn_api_key => 'SECOND-KEY');
    is(call('_tn_api_key', { storeid => 'tn-legacy-api' }), 'SECOND-KEY',
        'on_update_hook: delegates to on_update_hook_full with $scfg=undef and still rotates the key');
}

# ------------------------------------- H4: on_add_hook, pre-8.3.5 fallback ---
# A host old enough that 'sensitive-properties' extraction does not exist
# at all never populates %sensitive: the raw value arrives as a plain
# option in $scfg instead (already having passed check_config()
# unstripped). on_add_hook must still find it and still keep it out of
# storage.cfg.
{
    my $scfg = { tn_api_key => 'INLINE-ONLY-KEY' };   # nothing in %sensitive
    call('on_add_hook', $PKG, 'tn-old-host', $scfg);
    is(call('_tn_api_key', { storeid => 'tn-old-host' }), 'INLINE-ONLY-KEY',
        'on_add_hook: $scfg->{tn_api_key} fallback works when %sensitive is empty (pre-8.3.5 host)');
    ok(!exists($scfg->{tn_api_key}),
        '  ...and it is stripped from $scfg before returning (never reaches storage.cfg)');
}

# ------------------------------------------------------ K2: log redaction ---
{
    my $redacted = call('_tn_redact_for_log',
        '{"api_key":"1-verysecret","dhchap_key":"DHHC-1:01:xyz:","dhchap_ctrl_key":"DHHC-1:01:abc:","host":"192.0.2.1"}');
    unlike($redacted, qr/verysecret/, '_tn_redact_for_log: strips api_key');
    unlike($redacted, qr/DHHC-1:01:xyz/, '  ...strips dhchap_key');
    unlike($redacted, qr/DHHC-1:01:abc/, '  ...strips dhchap_ctrl_key');
    like($redacted, qr/"host":"192\.0\.2\.1"/, '  ...and leaves non-sensitive fields alone');
    like($redacted, qr/"api_key":"<redacted>"/, '  ...replacing with an explicit marker, not deleting the key');
}
{
    is(call('_tn_redact_for_log', undef), undef,
        '_tn_redact_for_log: passes undef through instead of dying (a non-ref $res can be undef)');
}

# ---------------------------------------------------- K4: process cache ---
{
    call('on_add_hook', $PKG, 'tn-cache', {}, tn_api_key => 'CACHE-V1');
    my $scfg = { storeid => 'tn-cache' };
    is(call('_tn_api_key', $scfg), 'CACHE-V1', 'cache: first read gets the value just written');

    # Rewrite the file directly, bypassing _tn_priv_write() - simulates
    # nothing (this is deliberately NOT how a real rotation happens); the
    # point is that the cache, once populated, is what a same-process read
    # returns until something in-process invalidates it.
    my $file = call('_tn_priv_file', 'tn-cache', 'pw');
    open(my $fh, '>', $file) or die $!;
    print $fh "BYPASSED-WRITE\n";
    close($fh);
    is(call('_tn_api_key', $scfg), 'CACHE-V1',
        '  ...a file changed OUTSIDE _tn_priv_write() does not invalidate the cache (documented scope: same-process only)');

    # A rotation THROUGH the plugin's own hook, in the same process, must
    # be visible on the very next read - this is the actual guarantee K4
    # asks for.
    call('on_update_hook_full', $PKG, 'tn-cache', { storeid => 'tn-cache' },
        {}, [], { tn_api_key => 'CACHE-V2' });
    is(call('_tn_api_key', $scfg), 'CACHE-V2',
        'cache: a same-process rotation via the hook is visible on the very next read');
}

done_testing();
