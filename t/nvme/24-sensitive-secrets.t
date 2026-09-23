#!/usr/bin/perl
# tn_api_key (a FULL_ADMIN TrueNAS credential) and tn_chap_password used to
# be plain options in storage.cfg (mode 0644) - readable by anyone with
# `pvesh get /storage/<id>` access, and tn_api_key was `fixed => 1` on top,
# so rotating it meant hand-editing storage.cfg on every node. Both are now
# 'sensitive-properties' (plugindata()): PVE::API2::Storage::Config strips
# them out of the request before check_config ever sees it and hands them
# only to on_add_hook / on_update_hook_full / on_delete_hook, which write
# them to /etc/pve/priv/storage/<storeid>.{pw,chap} (mode 0600) - the same
# mechanism and directory PVE's own PBSPlugin.pm/CIFSPlugin.pm use.
#
# This file pins:
#   - the priv-file read/write/delete roundtrip, and its 0600 permissions;
#   - _tn_api_key()/_tn_chap_password() priority: priv file wins over an
#     inline scfg value, so a rotated key can't be shadowed by a stale
#     leftover in storage.cfg;
#   - _tn_api_key() falls back to scfg for a cluster that has not migrated
#     yet, and dies with a clear, actionable message when neither exists;
#   - _tn_chap_password() never dies (CHAP is optional) - absence just
#     means "no CHAP auth", same as before this file existed;
#   - on_add_hook() refuses to create a storage with no API key, and stores
#     one that is given; CHAP password is stored only if present;
#   - on_update_hook_full() rotates the key, refuses to delete it (a
#     TrueNAS storage cannot run without one, unlike CIFS's password which
#     falls back to a guest mount), and allows deleting the CHAP password;
#   - on_delete_hook() removes both priv files, and is a no-op if they
#     were never created;
#   - migrate_priv_secrets()/migrate_api_key_cli(): moves inline secrets to
#     the priv files, is idempotent, --dry-run never writes, and a
#     non-truenasplugin storage is refused.
#
# Run with:  prove -v t/nvme/24-sensitive-secrets.t

use strict;
use warnings;
use Test::More;
use FindBin;
use File::Spec;
use File::Temp qw(tempdir);

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
                on_add_hook on_update_hook_full on_delete_hook
                migrate_priv_secrets migrate_api_key_cli)) {
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
    like($err, qr/migrate-api-key tn-missing/,
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
    # A `pvesm set` that never touched either sensitive property must not
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

# ------------------------------------------------- migrate_priv_secrets ---
SKIP: {
    skip 'PVE::Storage not loadable here', 13 unless eval { require PVE::Storage; 1 };

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

    %STORECFG_IDS = (
        'tn-mig' => {
            type => 'truenasplugin', tn_api_host => 'h', tn_dataset => 'd',
            tn_api_key => '1-inline-key', tn_chap_password => 'inline-chap',
        },
        'local' => { type => 'dir' },
    );

    # --dry-run: reports what would move, writes nothing.
    my $dry = $PKG->migrate_priv_secrets('tn-mig', dry_run => 1);
    is(scalar(@{ $dry->{moved} }), 2, 'migrate --dry-run: reports both secrets as movable');
    ok(exists($STORECFG_IDS{'tn-mig'}{tn_api_key}),
        '  ...and tn_api_key is still inline (nothing written)');

    my $real = $PKG->migrate_priv_secrets('tn-mig');
    is(scalar(@{ $real->{moved} }), 2, 'migrate: moves both secrets');
    ok(!exists($STORECFG_IDS{'tn-mig'}{tn_api_key}),
        '  ...tn_api_key removed from the in-memory config');
    ok(!exists($STORECFG_IDS{'tn-mig'}{tn_chap_password}),
        '  ...tn_chap_password removed too');
    is(call('_tn_priv_read', 'tn-mig', 'pw'), '1-inline-key',
        '  ...and the priv file actually has the key');
    is(call('_tn_priv_read', 'tn-mig', 'chap'), 'inline-chap',
        '  ...and the CHAP password');

    # Idempotent: nothing left inline, second run moves nothing.
    my $second = $PKG->migrate_priv_secrets('tn-mig');
    is(scalar(@{ $second->{moved} }), 0, 'migrate: second run is a no-op (idempotent)');

    # Wrong storage type: refused, nothing touched.
    my $wrong = $PKG->migrate_priv_secrets('local');
    is($wrong->{type}, 'dir', 'migrate: reports the real type for a non-truenasplugin storage');
    is(scalar(@{ $wrong->{moved} }), 0, '  ...and moves nothing');

    # CLI wrapper, capturing STDOUT/STDERR like t/nvme/20's run_cli().
    %STORECFG_IDS = (
        'tn-cli' => { type => 'truenasplugin', tn_api_key => '1-cli-key' },
    );
    my ($out, $rc);
    {
        my $capture;
        open(my $oldout, '>&', \*STDOUT) or die $!;
        close(STDOUT); open(STDOUT, '>', \$capture) or die $!;
        # NOT $PKG->migrate_api_key_cli(...): that method-call form
        # prepends the class name as the first element of @argv (same
        # trap run_cli() in t/nvme/20-snapshot-import-config.t avoids by
        # going through can() instead), which would show up here as an
        # "unexpected argument 'tn-cli'" - a bug in the test, not the sub.
        $rc = eval { $PKG->can('migrate_api_key_cli')->('tn-cli', '--dry-run') };
        close(STDOUT); open(STDOUT, '>&', $oldout) or die $!;
        $out = $capture;
    }
    is($rc, 0, 'migrate_api_key_cli --dry-run: exit 0');
    like($out, qr/\[dry-run\]/, '  ...marks the output as a dry run');
    ok(exists($STORECFG_IDS{'tn-cli'}{tn_api_key}), '  ...and did not actually move anything');
}

done_testing();
