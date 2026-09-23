#!/usr/bin/perl
# t/nvme/24-sensitive-secrets.t stubs PVE::Storage::write_config() as a
# total no-op for its migrate_priv_secrets() tests. That is fine for
# testing migrate_priv_secrets()'s own decision logic, but it also means
# those tests could never have caught a bug in what actually gets
# serialized: "idempotent" there only proves the in-memory hash was
# mutated, not that a REAL write_config()+parse_config() round-trip agrees
# (a QA finding from Kimi/Opus's real-node audit - Opus reproduced this
# file's scenarios against genuine PVE::SectionConfig parse_config/
# write_config on a live node, see repro.pl in this PR's discussion).
#
# This file exercises the REAL PVE::Storage::Plugin->parse_config()/
# write_config() (PVE::SectionConfig underneath) for everything that
# writes to or reads from storage.cfg's TEXT, not just its in-memory
# representation:
#
#   - check_config() stashes storeid onto $scfg (see TrueNASPlugin.pm),
#     but write_config() must never turn that into an actual "storeid"
#     line - it isn't a declared option();
#   - rotating tn_api_key on an UNMIGRATED storage (still inline) removes
#     the stale inline copy from the text write_config() produces - not
#     just from an in-memory hash (this is the H1 bug: without stripping
#     $scfg, the OLD key stayed in the real serialized text after a
#     "successful" rotation);
#   - after that rotation, migrate_priv_secrets() finds nothing left
#     inline (idempotent as observed through a REAL re-parse of
#     write_config()'s own output, not a stub);
#   - migrating twice, re-parsing the actual text write_config() produced
#     in between, confirms nothing to move" the second time for real;
#   - on_update_hook() (the api()<13 legacy shape) still gets the rotated
#     key into the priv file, but - documented, not silently broken -
#     cannot strip a stale inline copy on that path, because PVE never
#     hands that hook shape a live $scfg reference to strip it from; the
#     real Config.pm merge step (`for my $k (keys %$opts) { $scfg->{$k} =
#     $opts->{$k} }`) is simulated here to prove exactly that.
#
# Run with:  prove -v t/nvme/25-real-sectionconfig-roundtrip.t
# Needs a real libpve-storage-perl (skip_all otherwise, same as
# t/nvme/09-check-config-update.t).

use strict;
use warnings;
use Test::More;
use FindBin;

# Mark PVE::Storage.pm as already loaded BEFORE requiring anything else,
# same trick this PR's own repro.pl uses. Requiring PVE::Storage::DirPlugin
# below pulls in PVE::Storage for real unless this is set first - and on at
# least one real node that chain reaches PVE::GuestImport::OVF, which fails
# to compile there (an unrelated, pre-existing environment gap, not
# something this file is testing). With $INC pre-poisoned, every later
# `require PVE::Storage;` (including the one inside
# TrueNASPlugin.pm::migrate_priv_secrets()) is a silent no-op, which is
# fine: every PVE::Storage::* sub this file needs is either irrelevant
# (write_config()/parse_config() are PVE::Storage::Plugin methods, not
# PVE::Storage's) or stubbed explicitly further down before it is called.
BEGIN { $INC{'PVE/Storage.pm'} = 1; }

my $PLUGIN = "$FindBin::Bin/../../TrueNASPlugin.pm";
unless (eval { require $PLUGIN; 1 }) {
    plan skip_all => "cannot load TrueNASPlugin.pm (needs PVE perl modules): $@";
}

my $PKG = 'PVE::Storage::Custom::TrueNASPlugin';

unless (eval {
    require PVE::Storage::Plugin;
    # write_config() dies "unknown section type" for any section whose
    # type has no registered plugin - and, unlike check_config() alone
    # (which is all t/nvme/09-check-config-update.t needs), this file
    # calls write_config() for real, so at least one other type needs to
    # be registered alongside ours for PVE::Storage::Plugin->init() to
    # settle correctly (confirmed empirically, and matches repro.pl).
    require PVE::Storage::DirPlugin;
    PVE::Storage::DirPlugin->register();
    $PKG->register();
    PVE::Storage::Plugin->init();
    1;
}) {
    plan skip_all => "cannot register the plugin with PVE::SectionConfig: $@";
}

use File::Temp qw(tempdir);
my $PRIV_DIR = tempdir(CLEANUP => 1);
$ENV{TRUENAS_PRIV_DIR} = $PRIV_DIR;

# This file's job is the real parse_config()/write_config() round-trip -
# the cluster-readiness guard that gates stripping an inline secret
# (_tn_cluster_secrets_ready(), called from on_update_hook_full()'s
# self-heal/rotation path and from migrate_priv_secrets() without
# --all-nodes-upgraded) is covered exhaustively in
# t/nvme/24-sensitive-secrets.t instead, with full control over every
# node/SSH scenario. Stubbed here to always report ready: on a real
# multi-node cluster (this suite is meant to run on one), leaving it
# un-stubbed would make on_update_hook_full()'s rotation actually SSH out
# to the other nodes, turning this file's assertions about what gets
# stripped from storage.cfg into a coin flip on whether that SSH
# succeeds - orthogonal to what this file exists to prove.
{
    no strict 'refs';
    no warnings 'redefine';
    *{"${PKG}::_tn_cluster_secrets_ready"} = sub { return { ready => 1 } };
}

sub call { my ($sub, @args) = @_; no strict 'refs'; return &{"${PKG}::$sub"}(@args); }

my $BASE = <<'CFG';
truenasplugin: %s
	tn_api_host 192.0.2.10
	tn_dataset tank/pve
	tn_transport_mode iscsi
	tn_target_iqn iqn.2005-10.org.freenas.ctl:x
	tn_discovery_portal 192.0.2.10:3260
	content images
	shared 1
CFG

# ------------------------------------------------- A: no "storeid" line ---
{
    my $raw = sprintf($BASE, 'tnA');
    my $cfg = PVE::Storage::Plugin->parse_config('storage.cfg', $raw);
    ok(exists($cfg->{ids}{tnA}), 'parse_config: real PVE::SectionConfig keeps the section (not SKIPped)');
    is($cfg->{ids}{tnA}{storeid}, 'tnA',
        '  ...and check_config() really did stash storeid onto it (this is $scfg everywhere else)');

    my $out = PVE::Storage::Plugin->write_config('storage.cfg', $cfg);
    unlike($out, qr/^\s*storeid\b/m,
        'write_config: a REAL write never emits a "storeid" line - only options() keys are ever written');
}

# ---------------------------------- B: rotate on an UNMIGRATED storage ---
my $raw_b = sprintf($BASE, 'tnB');
$raw_b =~ s/(\ttn_api_host)/\ttn_api_key OLDKEY\n$1/;
my $cfg_b = PVE::Storage::Plugin->parse_config('storage.cfg', $raw_b);
my $scfg_b = $cfg_b->{ids}{tnB};
is($scfg_b->{tn_api_key}, 'OLDKEY',
    'sanity: a genuinely unmigrated storage has tn_api_key inline after a real parse_config()');

$PKG->on_update_hook_full('tnB', $scfg_b, {}, undef, { tn_api_key => 'NEWKEY' });
# $scfg_b IS $cfg_b->{ids}{tnB} (parse_config stores by reference), so the
# hook's `delete $scfg->{tn_api_key}` already mutated what write_config()
# is about to serialize - no separate merge step needed for this call.
my $out_b = PVE::Storage::Plugin->write_config('storage.cfg', $cfg_b);
unlike($out_b, qr/tn_api_key/,
    'H1: rotating on an unmigrated storage removes tn_api_key from the REAL serialized text entirely (not just in-memory)');
is(call('_tn_priv_read', 'tnB', 'pw'), 'NEWKEY',
    '  ...and the priv file has the NEW key, not the old one');

# --------------------------- C: migrate after that rotation is a no-op ---
{
    # Re-parse the ACTUAL text write_config() produced above - this is the
    # "relectura real del fichero" the audit asked for, not the in-memory
    # $cfg_b structure that already has the delete applied.
    my $reparsed = PVE::Storage::Plugin->parse_config('storage.cfg', $out_b);
    ok(!exists($reparsed->{ids}{tnB}{tn_api_key}),
        're-parsing write_config()\'s own output: tn_api_key is genuinely gone, not just deleted in memory');

    no strict 'refs';
    no warnings 'redefine';
    local *{'PVE::Storage::config'}              = sub { return $reparsed };
    local *{'PVE::Storage::storage_config'}       = sub { return $reparsed->{ids}{$_[1]} };
    local *{'PVE::Storage::write_config'}         = sub { return; };
    local *{'PVE::Storage::lock_storage_config'}  = sub { my ($code) = @_; $code->(); };

    my $res = $PKG->migrate_priv_secrets('tnB', all_nodes_upgraded => 1);
    is(scalar(@{ $res->{moved} }), 0,
        'migrate_priv_secrets after a rotation: nothing left inline to move (confirmed via a real re-parse)');
    is(call('_tn_priv_read', 'tnB', 'pw'), 'NEWKEY',
        '  ...priv still has the rotated NEW key, untouched');
}

# --------------------------------- D: migrate twice, real file re-reads ---
{
    my $raw_d = sprintf($BASE, 'tnD');
    $raw_d =~ s/(\ttn_api_host)/\ttn_api_key D-INLINE-KEY\n$1/;

    # $STATE simulates storage.cfg's actual bytes on disk. Every stub below
    # round-trips through the REAL parse_config()/write_config() - this is
    # deliberately NOT the same shortcut t/nvme/24 uses (a no-op
    # write_config on a shared in-memory hash), specifically to catch a bug
    # that only shows up in the real serialized text.
    my $STATE = $raw_d;
    no strict 'refs';
    no warnings 'redefine';
    local *{'PVE::Storage::config'} = sub {
        return PVE::Storage::Plugin->parse_config('storage.cfg', $STATE);
    };
    local *{'PVE::Storage::storage_config'} = sub {
        my ($cfg, $storeid) = @_;
        return $cfg->{ids}{$storeid};
    };
    local *{'PVE::Storage::write_config'} = sub {
        my ($cfg) = @_;
        $STATE = PVE::Storage::Plugin->write_config('storage.cfg', $cfg);
    };
    local *{'PVE::Storage::lock_storage_config'} = sub { my ($code) = @_; $code->(); };

    my $first = $PKG->migrate_priv_secrets('tnD', all_nodes_upgraded => 1);
    is(scalar(@{ $first->{moved} }), 1, 'migrate (real file): first run moves the inline key');
    unlike($STATE, qr/tn_api_key/,
        '  ...and the real on-disk text no longer has it (re-read from $STATE, not a cached hash)');

    my $second = $PKG->migrate_priv_secrets('tnD', all_nodes_upgraded => 1);
    is(scalar(@{ $second->{moved} }), 0,
        'migrate (real file): second run is genuinely idempotent - re-parses the real text and finds nothing');
    is(call('_tn_priv_read', 'tnD', 'pw'), 'D-INLINE-KEY',
        '  ...priv has the migrated key');
}

# ------------------------------------- E: api()<13 via on_update_hook ---
{
    my $raw_e = sprintf($BASE, 'tnE');
    $raw_e =~ s/(\ttn_api_host)/\ttn_api_key E-OLDKEY\n$1/;
    my $cfg_e = PVE::Storage::Plugin->parse_config('storage.cfg', $raw_e);
    my $scfg_e = $cfg_e->{ids}{tnE};

    # Simulate PVE::API2::Storage::Config's update handler on a host whose
    # clamped api() is < 13 (libpve-storage-perl older than 9.0.16): it
    # calls on_update_hook($storeid, $opts, %sensitive) - $opts only, NOT
    # the live $scfg - and only AFTER that, unconditionally merges $opts
    # into the live $scfg it already holds a reference to. tn_api_key is
    # sensitive-routed, so it never appears in $opts - the merge step is a
    # no-op for it either way.
    my %opts = ();
    $PKG->on_update_hook('tnE', \%opts, tn_api_key => 'E-ROTATED-VIA-LEGACY');
    for my $k (keys %opts) { $scfg_e->{$k} = $opts{$k}; }

    my $out_e = PVE::Storage::Plugin->write_config('storage.cfg', $cfg_e);
    like($out_e, qr/tn_api_key E-OLDKEY/,
        'on_update_hook (api()<13 legacy shape): documented limitation - cannot strip the stale inline '
      . 'copy because PVE never hands this shape a live $scfg reference to strip it from');
    is(call('_tn_priv_read', 'tnE', 'pw'), 'E-ROTATED-VIA-LEGACY',
        '  ...but the NEW key still reaches the priv file correctly regardless');
}

# ---------------------------- F: recreate a storeid without CHAP again ---
{
    my $raw_f = sprintf($BASE, 'tnF');
    my $cfg_f1 = PVE::Storage::Plugin->parse_config('storage.cfg', $raw_f);
    $PKG->on_add_hook('tnF', $cfg_f1->{ids}{tnF}, tn_api_key => 'F-KEY-1', tn_chap_password => 'F-CHAP-1');
    ok(-f call('_tn_priv_file', 'tnF', 'chap'), 'sanity: tnF has a CHAP file after the first create');

    # Storage deleted (real on_delete_hook - the file goes away)...
    $PKG->on_delete_hook('tnF', $cfg_f1->{ids}{tnF});
    ok(!-f call('_tn_priv_file', 'tnF', 'chap'), 'sanity: on_delete_hook removed it');

    # ...but suppose it comes back WITHOUT going through on_delete_hook
    # first (a hand-edited storage.cfg, or an older plugin version that
    # predates on_delete_hook cleaning up all four files) - the .chap file
    # is still lying around from the earlier life of this storeid.
    call('_tn_priv_write', 'tnF', 'chap', 'ORPHANED-FROM-BEFORE');
    ok(-f call('_tn_priv_file', 'tnF', 'chap'), 'sanity: an orphan CHAP file exists again');

    my $cfg_f2 = PVE::Storage::Plugin->parse_config('storage.cfg', $raw_f);
    $PKG->on_add_hook('tnF', $cfg_f2->{ids}{tnF}, tn_api_key => 'F-KEY-2');   # no tn_chap_password this time
    ok(!-f call('_tn_priv_file', 'tnF', 'chap'),
        'M3: recreating the same storeid without CHAP removes the orphaned .chap file - never silently reused');
}

done_testing();
