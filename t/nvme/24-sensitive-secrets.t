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
                _tn_cluster_secrets_ready _tn_has_corosync_conf
                _tn_redact_for_log _tn_redact_structure _tn_redact_secrets_in_text
                _rpc_error_message _tn_backup_storage_cfg)) {
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
    skip 'PVE::Storage not loadable here', 71 unless eval { require PVE::Storage; 1 };

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

    # _tn_cluster_secrets_ready() reads /etc/pve/.members (pmxcfs's own live
    # membership file - see its own comment for why NOT node names/`pvesh
    # get /nodes`: on a real cluster, node names resolved via this
    # system's DNS to unrelated Cloudflare IPv6 addresses, not the
    # cluster's own network - R7) and, per non-local online node, `ssh
    # -o HostKeyAlias=<name> root@<ip> perl -MPVE::Storage::Custom::TrueNASPlugin
    # -e ...`. Stub both PVE::Tools::file_get_contents (the .members read)
    # and PVE::Tools::run_command (the ssh probe) so every scenario below
    # controls exactly what that looks like, without a real cluster.
    # $MEMBERS_JSON drives the .members answer; $NODE_PROBE_OK maps IP ->
    # probe output ('1'/'0'/undef for "ssh itself failed").
    my ($MEMBERS_JSON, %NODE_PROBE_OK, @SSH_CMDS);

    # Builds a .members-shaped JSON string. %nodes: name => { online => 0|1,
    # ip => '...' }. Local defaults to the first name given.
    sub members_json {
        my ($local, %nodes) = @_;
        return encode_json({
            nodename => $local,
            nodelist => \%nodes,
        });
    }

    my $MEMBERS_READS = 0;   # C4: how many times .members was actually read
    {
        no strict 'refs';
        no warnings 'redefine';
        *{'PVE::Tools::file_get_contents'} = sub {
            my ($path) = @_;
            die "unexpected file in test stub: $path\n" if $path ne '/etc/pve/.members';
            die ".members not stubbed for this scenario\n" if !defined $MEMBERS_JSON;
            $MEMBERS_READS++;
            return $MEMBERS_JSON;
        };
        *{'PVE::Tools::run_command'} = sub {
            my ($cmd, %opts) = @_;
            my $out = $opts{outfunc};
            if ($cmd->[0] eq 'ssh') {
                push @SSH_CMDS, $cmd;
                my ($target) = grep { /^root\@/ } @$cmd;
                my ($ip) = $target =~ /^root\@(.+)$/;
                my $answer = $NODE_PROBE_OK{$ip};
                die "ssh to $ip refused\n" if !defined $answer;
                $out->($answer) if $out;
                return 0;
            }
            die "unexpected command in test stub: @$cmd\n";
        };
    }

    # ---------------------------------------------- _tn_cluster_secrets_ready ---
    {
        # Standalone host: .members lists only itself - nothing to verify.
        $MEMBERS_JSON = members_json('solo', solo => { online => 1, ip => '10.0.0.1' });
        my $r = $PKG->_tn_cluster_secrets_ready();
        ok($r->{ready}, '_tn_cluster_secrets_ready: a single-node "cluster" is always ready');
    }

    # --------------------- C2: a NEVER-clustered host (pmxcfs's real shape) ---
    # QA round 4 (Codex): pmxcfs itself emits ONLY {"nodename":...,
    # "version":N} - no 'nodelist' key at all - when it has no corosync
    # cluster info (verified against pve-cluster's own
    # cfs_create_memberlist_msg(): nodecount == 0 skips 'nodelist'
    # entirely, it never emits an empty one). The previous version of this
    # check treated ANY missing nodelist as a parse failure and failed
    # closed, so migrate-secrets (and the rotation/self-heal cleanup)
    # could never succeed on a standalone, never-clustered node - exactly
    # the case that should be the easiest one to approve.
    {
        $ENV{TRUENAS_TEST_COROSYNC_CONF} = '/nonexistent/for-this-test/corosync.conf';
        $MEMBERS_JSON = encode_json({ nodename => 'solo', version => 0 });
        my $r = $PKG->_tn_cluster_secrets_ready();
        ok($r->{ready},
            'C2: a real standalone host (.members has no "nodelist" key at all, and no corosync.conf) is ready');
        delete $ENV{TRUENAS_TEST_COROSYNC_CONF};
    }
    {
        # Inconsistent data: no 'nodelist' key, but corosync.conf DOES
        # exist - do not trust either signal alone; fail closed instead of
        # guessing which one is stale.
        my $fake_corosync = tempdir(CLEANUP => 1) . '/corosync.conf';
        open(my $fh, '>', $fake_corosync) or die $!;
        close($fh);
        $ENV{TRUENAS_TEST_COROSYNC_CONF} = $fake_corosync;
        $MEMBERS_JSON = encode_json({ nodename => 'solo', version => 0 });
        my $r = $PKG->_tn_cluster_secrets_ready();
        ok(!$r->{ready},
            'C2: missing "nodelist" but corosync.conf DOES exist -> inconsistent, fails closed (not silently standalone)');
        delete $ENV{TRUENAS_TEST_COROSYNC_CONF};
    }
    {
        @SSH_CMDS = ();
        $MEMBERS_JSON = members_json('pve1',
            pve1 => { online => 1, ip => '10.0.0.1' },
            pve2 => { online => 1, ip => '10.0.0.2' },
        );
        %NODE_PROBE_OK = ('10.0.0.2' => '1');   # pve1 is local, checked in-process
        my $r = $PKG->_tn_cluster_secrets_ready();
        ok($r->{ready}, '_tn_cluster_secrets_ready: local node checked in-process, remote confirms -> ready');
        ok(!(grep { grep { /^root\@10\.0\.0\.1$/ } @$_ } @SSH_CMDS),
            '  ...and never SSHes to itself');
    }
    {
        # R7: connects by IP, not by node NAME - and keys host-key
        # verification by name via HostKeyAlias, not IP.
        @SSH_CMDS = ();
        $MEMBERS_JSON = members_json('pve1',
            pve1 => { online => 1, ip => '10.0.0.1' },
            pve2 => { online => 1, ip => '203.0.113.9' },
        );
        %NODE_PROBE_OK = ('203.0.113.9' => '1');
        $PKG->_tn_cluster_secrets_ready();
        my ($ssh_cmd) = @SSH_CMDS;
        ok((grep { $_ eq 'root@203.0.113.9' } @$ssh_cmd),
            'R7: connects to the IP from .members (root@203.0.113.9), never `root@pve2`');
        ok(!(grep { /^root\@pve2$/ } @$ssh_cmd), '  ...confirmed: no root@pve2 anywhere in the command');
        ok((grep { $_ eq 'HostKeyAlias=pve2' } @$ssh_cmd),
            '  ...but still keys host-key verification by name (HostKeyAlias=pve2)');
    }
    {
        $MEMBERS_JSON = members_json('pve1',
            pve1 => { online => 1, ip => '10.0.0.1' },
            pve2 => { online => 1, ip => '10.0.0.2' },
        );
        # pve2 answers '0': its installed plugin does NOT have
        # migrate_priv_secrets (idk20 or older).
        %NODE_PROBE_OK = ('10.0.0.2' => '0');
        my $r = $PKG->_tn_cluster_secrets_ready();
        ok(!$r->{ready}, '_tn_cluster_secrets_ready: one node too old -> not ready');
        like($r->{reason}, qr/pve2/, '  ...and names it');
    }
    {
        $MEMBERS_JSON = members_json('pve1',
            pve1 => { online => 1, ip => '10.0.0.1' },
            pve3 => { online => 0, ip => '10.0.0.3' },
        );
        my $r = $PKG->_tn_cluster_secrets_ready();
        ok(!$r->{ready}, '_tn_cluster_secrets_ready: an offline node cannot be verified -> not ready');
        like($r->{reason}, qr/pve3/, '  ...and names it');
    }
    {
        # K8: SSH banners/MOTD or the probe's own trailing newline must not
        # be mistaken for "answered 0" - only exact '1' alone on a line
        # counts as confirmed.
        $MEMBERS_JSON = members_json('pve1',
            pve1 => { online => 1, ip => '10.0.0.1' },
            pve2 => { online => 1, ip => '10.0.0.2' },
        );
        %NODE_PROBE_OK = ('10.0.0.2' => "Warning: extended attributes not supported\n1\n");
        my $r = $PKG->_tn_cluster_secrets_ready();
        ok($r->{ready}, 'K8: a login banner around the probe output does not look like a "too old" answer');
    }
    {
        $MEMBERS_JSON = undef;   # .members itself is unreadable
        my $r = $PKG->_tn_cluster_secrets_ready();
        ok(!$r->{ready}, '_tn_cluster_secrets_ready: cannot even read .members -> not ready, not a crash');
    }

    # --------------------------------------------- R6: fail closed on bad data ---
    {
        $MEMBERS_JSON = encode_json({ nodename => 'pve1', nodelist => {} });
        my $r = $PKG->_tn_cluster_secrets_ready();
        ok(!$r->{ready}, 'R6: an EMPTY nodelist is a data problem, not evidence of a standalone host -> not ready');
    }
    {
        $MEMBERS_JSON = encode_json({
            nodename => 'pve1',
            nodelist => { '' => { online => 1, ip => '10.0.0.9' } },
        });
        my $r = $PKG->_tn_cluster_secrets_ready();
        ok(!$r->{ready}, 'R6: an unnamed node entry -> not ready (fails closed, not silently skipped)');
    }
    {
        $MEMBERS_JSON = 'not even json';
        my $r = $PKG->_tn_cluster_secrets_ready();
        ok(!$r->{ready}, 'R6: unparseable .members -> not ready');
    }

    # Every scenario after this point uses a single-node "cluster" so the
    # guard auto-passes without needing --all-nodes-upgraded - the guard
    # itself is fully covered above; what follows tests migration logic.
    $MEMBERS_JSON = members_json('solo', solo => { online => 1, ip => '10.0.0.1' });

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
    $MEMBERS_JSON = undef;
    my $dry = $PKG->migrate_priv_secrets('tn-mig', dry_run => 1);
    is(scalar(@{ $dry->{moved} }), 4, 'migrate --dry-run: reports all four secrets as movable');
    ok(exists($STORECFG_IDS{'tn-mig'}{tn_api_key}),
        '  ...and tn_api_key is still inline (nothing written)');
    $MEMBERS_JSON = members_json('solo', solo => { online => 1, ip => '10.0.0.1' });

    # A real (non-dry-run) migration on a multi-node cluster with an
    # unverifiable node is refused outright - this is the H3 guard exercised
    # end-to-end through migrate_priv_secrets(), not just the helper above.
    {
        $MEMBERS_JSON = members_json('pve1',
            pve1 => { online => 1, ip => '10.0.0.1' },
            pve2 => { online => 1, ip => '10.0.0.2' },
        );
        %NODE_PROBE_OK = ('10.0.0.2' => '0');
        my $err = eval { $PKG->migrate_priv_secrets('tn-mig'); 1 } ? '' : $@;
        like($err, qr/migrate-secrets refused/, 'migrate_priv_secrets: refuses on an unready cluster');
        ok(exists($STORECFG_IDS{'tn-mig'}{tn_api_key}), '  ...and writes nothing');

        # --all-nodes-upgraded overrides the refusal.
        my $forced = $PKG->migrate_priv_secrets('tn-mig', all_nodes_upgraded => 1);
        is(scalar(@{ $forced->{moved} }), 4,
            'migrate_priv_secrets: --all-nodes-upgraded bypasses the check and migrates');
        $MEMBERS_JSON = members_json('solo', solo => { online => 1, ip => '10.0.0.1' });
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

    # ------------------------------- F3: backup before migrate ---
    # migrate_priv_secrets() must snapshot storage.cfg BEFORE the first
    # write it makes, so a bad migration (or just changing one's mind) has
    # an exact pre-migration copy to go back to - NOT under /etc/pve
    # (pmxcfs, cluster-replicated the instant anything lands there).
    {
        my $storage_cfg_path = tempdir(CLEANUP => 1) . '/storage.cfg';
        my $backup_dir = tempdir(CLEANUP => 1) . '/backups';
        my $fake_cfg_text = "truenasplugin: tn-backup\n\ttn_api_key BACKUP-ME\n";
        PVE::Tools::file_set_contents($storage_cfg_path, $fake_cfg_text, 0644, 1);

        local $ENV{TRUENAS_TEST_STORAGE_CFG} = $storage_cfg_path;
        local $ENV{TRUENAS_TEST_BACKUP_DIR} = $backup_dir;

        %STORECFG_IDS = (
            'tn-backup' => { type => 'truenasplugin', tn_api_key => 'BACKUP-ME' },
        );
        my $res = $PKG->migrate_priv_secrets('tn-backup');

        ok(defined($res->{backup}), 'F3: migrate_priv_secrets reports a backup path');
        ok(-f $res->{backup}, '  ...and the file actually exists');
        like($res->{backup}, qr/\Q$backup_dir\E\/storage\.cfg\.pre-migrate\.\d+$/,
            '  ...named storage.cfg.pre-migrate.<epoch> under the backup dir, not /etc/pve');
        my $backup_content = do {
            local $/ = undef;
            open(my $fh, '<', $res->{backup}) or die "cannot read backup: $!\n";
            <$fh>;
        };
        is($backup_content, $fake_cfg_text,
            '  ...and its content is an exact copy of storage.cfg as it was before migrating');
        SKIP: {
            skip 'file mode bits are not meaningful on this platform', 1
                if $^O =~ /^(?:MSWin32|msys|cygwin)$/;
            is((stat($res->{backup}))[2] & 07777, 0600, '  ...mode 0600, root-only');
        }

        # A second migrate_priv_secrets() call on an already-migrated
        # storage has nothing left to move, so nothing new to back up -
        # confirms the backup is conditioned on an actual write, not
        # unconditional on every call.
        my $res2 = $PKG->migrate_priv_secrets('tn-backup');
        is(scalar(@{ $res2->{moved} }), 0, '  ...idempotent: second call moves nothing');
        ok(!defined($res2->{backup}), '  ...and takes no new backup when there is nothing to change');
    }

    # A storage.cfg that does not exist yet (fresh install, no storages
    # defined at all) has nothing to back up - migrate_priv_secrets() must
    # not die trying.
    {
        local $ENV{TRUENAS_TEST_STORAGE_CFG} = tempdir(CLEANUP => 1) . '/never-created.cfg';
        local $ENV{TRUENAS_TEST_BACKUP_DIR} = tempdir(CLEANUP => 1) . '/backups';

        %STORECFG_IDS = (
            'tn-nobackup' => { type => 'truenasplugin', tn_api_key => 'SOME-KEY' },
        );
        my $res = $PKG->migrate_priv_secrets('tn-nobackup');
        ok(!defined($res->{backup}),
            'F3: no storage.cfg on disk yet -> migrate_priv_secrets does not fail, reports no backup');
        is(scalar(@{ $res->{moved} }), 1, '  ...but still migrates the secret itself');
    }

    # --------------------------- R8/F1: rotation on an unready cluster ---
    # pvesm set --tn_api_key ... (and any other update that would self-heal
    # a stale inline copy) applies the SAME cluster-readiness policy as
    # migrate_priv_secrets(): on an unconfirmed multi-node cluster, keep
    # BOTH copies (priv already wins at runtime) instead of stripping the
    # inline one and making the storage vanish on an old node. F1 (QA
    # round 5): production upgrades a cluster one node at a time, so
    # "mixed cluster" is the NORMAL case, not a corner case - the inline
    # copy that idk20 nodes actually read must track the CURRENT value,
    # not the one about to be revoked on TrueNAS.
    {
        $MEMBERS_JSON = members_json('pve1',
            pve1 => { online => 1, ip => '10.0.0.1' },
            pve2 => { online => 1, ip => '10.0.0.2' },
        );
        %NODE_PROBE_OK = ('10.0.0.2' => '0');   # pve2 too old to confirm

        my $scfg = { storeid => 'tn-rot', tn_api_host => 'h', tn_api_key => 'OLD-INLINE-KEY' };
        call('on_update_hook_full', $PKG, 'tn-rot', $scfg, {}, [], { tn_api_key => 'NEW-KEY' });

        is(call('_tn_priv_read', 'tn-rot', 'pw'), 'NEW-KEY',
            'R8/F1: rotation on an unready cluster still writes the NEW key to priv');
        is($scfg->{tn_api_key}, 'NEW-KEY',
            '  ...and keeps the inline copy too, but updated to the NEW value - idk20 nodes '
              . 'must never keep authenticating with a key that was just revoked');

        # Once the cluster IS confirmed ready, the next update (even one
        # that does not touch the key at all) self-heals the leftover
        # inline copy.
        $MEMBERS_JSON = members_json('solo', solo => { online => 1, ip => '10.0.0.1' });
        call('on_update_hook_full', $PKG, 'tn-rot', $scfg, { nodes => 'pve3' }, [], {});
        ok(!exists($scfg->{tn_api_key}),
            '  ...and self-heals once the cluster is confirmed ready on a later update');
        is(call('_tn_priv_read', 'tn-rot', 'pw'), 'NEW-KEY', '    ...priv still has the NEW key');
    }

    # ------------------- F1: self-heal branch never RE-SYNCS a value ---
    # (only the explicit-rotation branches above pass $new_value to
    # _tn_strip_inline_if_cluster_ready()). An update that does not touch
    # tn_api_key at all, on an unready cluster, with a STALE inline value
    # already sitting in storage.cfg, must keep exactly what was already
    # there - it has no new value to sync to, and overwriting it with
    # priv's value here would duplicate what migrate_priv_secrets()'s
    # explicit conflict handling already owns.
    {
        $MEMBERS_JSON = members_json('pve1',
            pve1 => { online => 1, ip => '10.0.0.1' },
            pve2 => { online => 1, ip => '10.0.0.2' },
        );
        %NODE_PROBE_OK = ('10.0.0.2' => '0');   # unready

        call('on_add_hook', $PKG, 'tn-selfheal', {}, tn_api_key => 'PRIV-VALUE');
        my $scfg = { storeid => 'tn-selfheal', tn_api_key => 'STALE-INLINE-VALUE' };
        call('on_update_hook_full', $PKG, 'tn-selfheal', $scfg, { nodes => 'pve3' }, [], {});

        is($scfg->{tn_api_key}, 'STALE-INLINE-VALUE',
            'F1: an untouched self-heal on an unready cluster does not rewrite the inline value');
        is(call('_tn_priv_read', 'tn-selfheal', 'pw'), 'PRIV-VALUE', '  ...priv is unchanged');
    }

    # ------------------------- R9: differing priv vs inline gets a warning ---
    {
        $MEMBERS_JSON = members_json('solo', solo => { online => 1, ip => '10.0.0.1' });
        call('on_add_hook', $PKG, 'tn-warn', {}, tn_api_key => 'PRIV-VALUE');
        my $scfg = { storeid => 'tn-warn', tn_api_key => 'DIFFERENT-STALE-VALUE' };

        my @warned;
        local $SIG{__WARN__} = sub { push @warned, @_ };
        # syslog() doesn't go through __WARN__, so this only proves the
        # self-heal branch runs without dying on a differing value; the
        # actual "conserva priv" outcome is asserted directly below (the
        # same guarantee migrate's conflict-kept-priv gives, applied here).
        call('on_update_hook_full', $PKG, 'tn-warn', $scfg, { nodes => 'pve3' }, [], {});

        is(call('_tn_priv_read', 'tn-warn', 'pw'), 'PRIV-VALUE',
            'R9: priv keeps ITS value when it differs from a stale inline copy - never silently overwritten');
        ok(!exists($scfg->{tn_api_key}),
            '  ...and the differing inline copy is still cleaned up (cluster is ready in this scenario)');
    }

    # ------------------- C1: an EMPTY/unreadable priv file is not "usable" ---
    # QA round 4 (Codex): the self-heal guard used to check only that the
    # priv file EXISTS (-e) before stripping the inline copy. A priv file
    # that exists but is empty (a zero-byte file, a failed partial write,
    # anything -e is still true for) would have left the storage with NO
    # usable credential anywhere once the inline copy was also stripped.
    {
        $MEMBERS_JSON = members_json('solo', solo => { online => 1, ip => '10.0.0.1' });

        # A priv file that exists but is empty - not "on_add_hook wrote an
        # empty string" (that's refused elsewhere), but the shape of a
        # corrupted/truncated file: create it directly, bypassing the
        # normal write path.
        my $file = call('_tn_priv_file', 'tn-empty', 'pw');
        open(my $fh, '>', $file) or die $!;
        close($fh);
        ok(-e $file, 'sanity: tn-empty has a .pw file that exists');
        is(call('_tn_priv_read', 'tn-empty', 'pw'), undef,
            'sanity: _tn_priv_read() already treats an empty file as "nothing usable"');

        my $scfg = { storeid => 'tn-empty', tn_api_key => 'ONLY-USABLE-CREDENTIAL' };
        # An update that does not touch tn_api_key at all - the self-heal
        # branch is the only thing that could strip the inline copy here.
        call('on_update_hook_full', $PKG, 'tn-empty', $scfg, { nodes => 'pve3' }, [], {});

        is($scfg->{tn_api_key}, 'ONLY-USABLE-CREDENTIAL',
            'C1: inline copy is KEPT when priv exists but has no usable content - '
          . 'stripping it would have left the storage with no credential anywhere');
    }

    # --------------------------- K9: on_add_hook warns on a mixed cluster ---
    {
        $MEMBERS_JSON = members_json('pve1',
            pve1 => { online => 1, ip => '10.0.0.1' },
            pve2 => { online => 1, ip => '10.0.0.2' },
        );
        %NODE_PROBE_OK = ('10.0.0.2' => '0');

        my $ok = eval {
            call('on_add_hook', $PKG, 'tn-newmixed', {}, tn_api_key => 'FRESH-KEY');
            1;
        };
        ok($ok, 'K9: on_add_hook does not refuse creation just because the cluster looks unready')
            or diag("died with: $@");
        is(call('_tn_priv_read', 'tn-newmixed', 'pw'), 'FRESH-KEY',
            '  ...the key is still written to priv normally');
    }

    # ------------------------- C4: cluster check memoized per hook call ---
    # QA round 4 (Kimi): _tn_cluster_secrets_ready() runs synchronous SSH
    # to every cluster node - on_update_hook_full() can reach the strip
    # decision up to 4 times (the key plus three optional secrets), and
    # computing it fresh each time meant up to 4x the SSH cost for a
    # single `pvesm set` that happens to touch several secrets at once.
    {
        $MEMBERS_JSON = members_json('pve1',
            pve1 => { online => 1, ip => '10.0.0.1' },
            pve2 => { online => 1, ip => '10.0.0.2' },
        );
        %NODE_PROBE_OK = ('10.0.0.2' => '1');

        call('on_add_hook', $PKG, 'tn-memo', {},
            tn_api_key => 'MEMO-KEY', tn_chap_password => 'MEMO-CHAP');
        my $scfg = {
            storeid => 'tn-memo', tn_api_key => 'STALE-INLINE-KEY',
            tn_chap_password => 'STALE-INLINE-CHAP',
        };

        $MEMBERS_READS = 0;
        # Touches BOTH the tn_api_key self-heal branch (inline present,
        # differs from priv) AND the tn_chap_password self-heal branch
        # (same) in ONE call - each would call _tn_cluster_secrets_ready()
        # if it were not memoized.
        call('on_update_hook_full', $PKG, 'tn-memo', $scfg, { nodes => 'pve3' }, [], {});

        ok(!exists($scfg->{tn_api_key}), 'sanity: tn_api_key self-heal ran (cluster is ready)');
        ok(!exists($scfg->{tn_chap_password}), 'sanity: tn_chap_password self-heal ran too');
        is($MEMBERS_READS, 1,
            'C4: .members is read exactly ONCE for a single hook call, even when two secrets both self-heal');
    }

    # ------------------------------- C6: single-entry nodelist, NOT local ---
    # QA round 4 (Kimi): the single-node shortcut used to approve on ENTRY
    # COUNT alone - a nodelist with exactly one entry that names some
    # OTHER node (not this process's own) would have been approved with
    # zero verification of anything. It must fall through to the normal
    # per-node loop instead, which actually probes that one node.
    {
        @SSH_CMDS = ();
        $MEMBERS_JSON = members_json('pve1',   # local is pve1...
            pve2 => { online => 1, ip => '10.0.0.2' },   # ...but the only entry is pve2
        );
        %NODE_PROBE_OK = ('10.0.0.2' => '1');
        my $r = $PKG->_tn_cluster_secrets_ready();
        ok($r->{ready}, 'C6: a single remote entry is still approved - but only after being probed');
        ok(scalar(@SSH_CMDS) >= 1,
            '  ...confirmed: it was NOT waved through by the entry-count shortcut - an SSH probe actually ran');
    }
    {
        @SSH_CMDS = ();
        $MEMBERS_JSON = members_json('pve1',
            pve2 => { online => 1, ip => '10.0.0.2' },
        );
        %NODE_PROBE_OK = ('10.0.0.2' => '0');   # this time the one remote node fails
        my $r = $PKG->_tn_cluster_secrets_ready();
        ok(!$r->{ready}, 'C6: ...and a single remote entry that fails verification is refused, not waved through');
    }
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

# R5: a naive `[^"]*` value pattern stops at the first escaped quote INSIDE
# the value and leaves everything after it exposed - found in review:
# {"password":"a\"SECRET"} leaked SECRET through the previous regex. Same
# bug applies to both the string-level fallback and would apply to any
# regex-based approach for the structural path too, which is exactly why
# _api_call()'s own logging switched to walking the decoded structure
# instead (tested separately below) - this pins the string-level fallback
# specifically, since tools/truenas-plugin-broker (K6) has no decoded
# structure to walk.
{
    my $redacted = call('_tn_redact_for_log', qq({"password":"a\\"SECRET","host":"h"}));
    unlike($redacted, qr/SECRET/, 'R5: an escaped quote inside the value does not stop the redaction early');
    like($redacted, qr/"host":"h"/, '  ...and a field after it is still left alone');
}

# ------------------------------------------------- R5: structural redaction ---
# _api_call()'s own request/response logging walks the DECODED structure
# and redacts by key before ever calling encode_json() - see
# _tn_redact_structure()'s own comment for why (a regex over already-quoted
# JSON has to reconstruct what "one string value" looks like and can get it
# wrong; walking real Perl values never has that problem).
{
    my $redacted = call('_tn_redact_structure', {
        api_key => '1-verysecret',
        host    => '192.0.2.1',
        nested  => { dhchap_key => 'DHHC-1:01:xyz:', label => 'ok' },
        list    => [ { password => 'a"SECRET' }, { plain => 'value' } ],
    });
    is($redacted->{api_key}, '<redacted>', '_tn_redact_structure: redacts a top-level sensitive key');
    is($redacted->{host}, '192.0.2.1', '  ...leaves a non-sensitive top-level key alone');
    is($redacted->{nested}{dhchap_key}, '<redacted>', '  ...redacts a sensitive key nested in a hash');
    is($redacted->{nested}{label}, 'ok', '  ...leaves the rest of that nested hash alone');
    is($redacted->{list}[0]{password}, '<redacted>',
        '  ...redacts inside an array of hashes, and the embedded quote is no obstacle at all (no JSON parsing involved)');
    is($redacted->{list}[1]{plain}, 'value', '  ...leaves an unrelated array entry alone');

    # The original is untouched - this is a redacted COPY, not a mutation,
    # so the real value is still there for whatever actually needs it
    # (e.g. the API call itself, which happens before this is ever
    # called).
    my $probe = { api_key => 'still-here' };
    call('_tn_redact_structure', $probe);
    is($probe->{api_key}, 'still-here', '_tn_redact_structure: does not mutate its argument');
}

# ------------------------------------------------------------------ C5 ---
# _rpc_error_message()'s $reason/$name come from TrueNAS's own free-text
# error message, not a JSON key this file controls - a validation error
# can quote the rejected value straight back (e.g. "Invalid dhchap_key
# format: <the value>"). Neither _tn_redact_structure() nor
# _tn_redact_for_log() catch that (both key off a JSON key name; free
# prose has none), so the fix does a literal substring replace of every
# secret this storage actually has configured.
{
    call('on_add_hook', $PKG, 'tn-c5', {},
        tn_api_key => 'C5-API-KEY', tn_nvme_dhchap_secret => 'C5-DHCHAP-SECRET');
    my $scfg = { storeid => 'tn-c5' };

    # The PRIMARY return path (a well-formed {data:{reason,errname}} body -
    # the one most real TrueNAS errors take).
    my $err1 = { data => { reason => "Invalid value: 'C5-DHCHAP-SECRET' is not a valid key", errname => 'ValidationError' } };
    my $msg1 = call('_rpc_error_message', $err1, $scfg);
    unlike($msg1, qr/C5-DHCHAP-SECRET/, 'C5: the primary [errname]: reason return path redacts a secret embedded in free text');
    like($msg1, qr/ValidationError/, '  ...without losing the rest of the message');

    # The FALLBACK return path (not a {reason,...}-shaped hash at all - a
    # plain string $err never enters the {data:{reason}} branch above).
    # Neither _tn_redact_structure() (nothing to walk, it's not a ref) nor
    # _tn_redact_for_log() (no "key":"value" JSON shape to match in plain
    # prose) would catch this alone - the literal substring pass is what
    # does.
    my $err2 = 'unexpected failure involving C5-API-KEY somewhere';
    my $msg2 = call('_rpc_error_message', $err2, $scfg);
    unlike($msg2, qr/C5-API-KEY/, 'C5: the fallback return path redacts too (plain-string error, no JSON shape at all)');
}
{
    # Never dies just because $scfg has no usable secrets to look up (a
    # storage with no key configured yet, or none passed at all).
    my $ok = eval { call('_rpc_error_message', { message => 'plain failure' }, undef); 1 };
    ok($ok, 'C5: does not die when $scfg has nothing to redact against') or diag("died: $@");
}

# --------------------------------------------------- R1: no priv cache ---
# QA round 3 (Codex+Opus, reproduced against a live node): an earlier
# version of this file HAD a process-local cache here, and it was a real
# regression, not a hypothetical - pvestatd runs for DAYS without forking,
# and pvedaemon reuses a worker for up to max_requests => 1000 before
# recycling, so a cache keyed only on "have I read this before in this
# process" never invalidates in either one. Measured effects: after
# migrate-secrets, long-running processes on every node kept reporting
# "API key missing" (the cache had memorized the pre-migration "nothing in
# priv" answer as permanent, forever); a rotation never took effect (the
# cache kept serving the revoked key to every subsequent call in that
# process); and the H1 self-heal guard used the cache as proof a priv file
# existed, which could delete a storage's only inline copy on a stale
# cached answer. Fixed by removing the cache entirely (_tn_priv_read()
# reads the file fresh every call, same as PBSPlugin.pm's own
# pbs_get_password()).
#
# This proves it with a genuinely SEPARATE, already-running process - not
# a fork, which would pass this assertion regardless of whether a cache
# existed (fork() gives the child independent memory immediately, so it
# proves nothing about THIS process's own cache). The scenario modeled is
# the real one: pvedaemon handling a concurrent `pvesm set --tn_api_key
# ...` while THIS process (standing in for pvestatd) is already running
# and has already read the old key once.
{
    call('on_add_hook', $PKG, 'tn-cache', {}, tn_api_key => 'CACHE-V1');
    my $scfg = { storeid => 'tn-cache' };
    is(call('_tn_api_key', $scfg), 'CACHE-V1',
        'sanity: this long-lived process reads the key it just wrote');

    # A second, real, independent `perl` process writes the priv file
    # directly - standing in for another PVE process performing a
    # rotation via on_update_hook_full() while this one keeps running.
    my $file = call('_tn_priv_file', 'tn-cache', 'pw');
    my $writer = tempdir(CLEANUP => 1) . '/writer.pl';
    open(my $wfh, '>', $writer) or die $!;
    print $wfh q{open(my $fh, '>', $ARGV[0]) or die $!; print $fh "$ARGV[1]\n"; close($fh);};
    close($wfh);
    system($^X, $writer, $file, 'CACHE-V2') == 0
        or die "setup failed: second perl process could not write $file";

    is(call('_tn_api_key', $scfg), 'CACHE-V2',
        'R1: a rotation made by a DIFFERENT, already-running process is visible on the very next read - nothing left to go stale');
}

done_testing();
