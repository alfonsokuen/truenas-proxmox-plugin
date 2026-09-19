#!/usr/bin/perl
# import_foreign_snapshots() writes guest configuration. That is the one thing
# a storage plugin normally has no business doing, so every rule it follows is
# pinned here against stubbed PVE::QemuConfig / PVE::Storage primitives:
#
#   - it goes through lock_config + load_config + write_config, never by
#     editing text in /etc/pve (the plugin still does that in
#     _cleanup_vm_snapshot_config, and that is the deuda this does not repeat);
#   - it only ADDS sections: an existing one is byte-for-byte the same after;
#   - a second run imports nothing and does not write at all - without that,
#     a cron calling this would rewrite the config of every VM forever;
#   - --dry-run does not even take the lock;
#   - it refuses a template, a locked config, a snapshot mid-flight
#     (snapstate) and any non-cdrom disk living outside this plugin, because
#     rolling back to a section covering a volume this plugin cannot snapshot
#     dies half way through.
#
# Run with:  prove -v t/nvme/20-snapshot-import-config.t

use strict;
use warnings;
use Test::More;
use FindBin;
use File::Spec;
use JSON::PP;
use Storable qw(dclone);

my $PLUGIN = File::Spec->rel2abs("$FindBin::Bin/../../TrueNASPlugin.pm");
plan skip_all => "TrueNASPlugin.pm not found at $PLUGIN" unless -f $PLUGIN;

# On a node where this plugin is INSTALLED, loading PVE::Storage pulls every
# file in /usr/share/perl5/PVE/Storage/Custom into the same package - which
# would redefine the code under test with whatever version is installed. Load
# it first, so the file under test is the last word.
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
# A missing subroutine is a failure, not a skip: this file exists to go red on
# a plugin that cannot import.
unless ($PKG->can('import_foreign_snapshots')) {
    plan tests => 1;
    fail('import_foreign_snapshots existe');
    exit 1;
}

plan tests => 26;

# ------------------------------------------------- stub PVE::QemuConfig ---
# The real module is not loadable outside a PVE node and pulls in qemu-server.
# These stubs keep the contract the plugin depends on: load_config hands out a
# COPY, so anything the plugin changes is only observable through
# write_config.
our %CONF;
our @WRITES;
our $LOCKS = 0;
{
    package PVE::QemuConfig;
    sub load_config {
        my ($class, $vmid) = @_;
        die "Configuration file for '$vmid' does not exist\n" if !$CONF{$vmid};
        return Storable::dclone($CONF{$vmid});
    }
    sub write_config {
        my ($class, $vmid, $conf) = @_;
        push @WRITES, Storable::dclone($conf);
        $CONF{$vmid} = Storable::dclone($conf);
    }
    sub lock_config {
        my ($class, $vmid, $code, @param) = @_;
        $LOCKS++;
        return $code->(@param);
    }
    # Same key set and same order as PVE::QemuServer::Drive::valid_drive_names
    # for the keys this test uses.
    sub foreach_volume {
        my ($class, $conf, $func, @param) = @_;
        for my $key (qw(ide0 ide1 ide2 scsi0 scsi1 scsi2 virtio0 sata0
                        efidisk0 tpmstate0)) {
            my $str = $conf->{$key};
            next if !defined($str);
            my ($file, @opts) = split(/,/, $str);
            my $drive = { file => $file };
            for my $o (@opts) {
                my ($k, $v) = split(/=/, $o, 2);
                $drive->{$k} = $v;
            }
            $func->($key, $drive, @param);
        }
    }
    # Verbatim from PVE::AbstractConfig (PVE 9.2.4).
    sub __snapshot_copy_config {
        my ($class, $source, $dest) = @_;
        foreach my $k (keys %$source) {
            next if $k eq 'snapshots';
            next if $k eq 'snapstate';
            next if $k eq 'snaptime';
            next if $k eq 'vmstate';
            next if $k eq 'lock';
            next if $k eq 'digest';
            next if $k eq 'description';
            next if $k =~ m/^unused\d+$/;
            $dest->{$k} = $source->{$k};
        }
    }
}
$INC{'PVE/QemuConfig.pm'} = 1;

# ---------------------------------------------------- stub the storage cfg ---
our $STORECFG = {
    ids => {
        tnnvme => { type => 'truenasplugin', tn_dataset => 'pool/pve' },
        'local' => { type => 'dir' },
        'local-lvm' => { type => 'lvmthin' },
    },
};
{
    no strict 'refs';
    no warnings 'redefine';
    *{"PVE::Storage::config"} = sub { return $STORECFG };
}

# --------------------------------------------------------- stub the array ---
my $FIXTURE = "$FindBin::Bin/fixtures/tn-pool-snapshot-query.json";
open(my $fh, '<', $FIXTURE) or die "cannot read $FIXTURE: $!";
my $raw = do { local $/; <$fh> };
close($fh);
my $RECORDS = JSON::PP->new->decode($raw);

my @api;
{
    no strict 'refs';
    no warnings 'redefine';
    *{"${PKG}::_log"} = sub { 1 };
    *{"${PKG}::_api_call"} = sub {
        my ($scfg, $method, $params) = @_;
        push @api, $method;
        return $RECORDS if $method eq 'pool.snapshot.query';
        # The clone lookup: 'cloned-snap' is the origin of a live clone, so
        # it must not be imported - PVE could never delete it again. Every
        # other candidate comes back with no dependents.
        if ($method eq 'pool.dataset.query') {
            my $id = eval { $params->[0][0][2] } // '';
            return [ { id => 'pool/pve/a-clone' } ] if $id =~ /\@cloned-snap$/;
            return [];
        }
        die "unexpected API call $method\n";
    };
}

my $VMID = 9990;
sub base_conf {
    return {
        name     => 'importtest',
        memory   => 2048,
        cores    => 2,
        scsi0    => 'tnnvme:vol-vm-9990-disk-0-lun0,size=32G',
        scsi1    => 'tnnvme:vol-vm-9990-disk-1-lun1,size=8G',
        ide2     => 'local:iso/debian.iso,media=cdrom',
        parent   => 's1',
        snapshots => {
            s1 => {
                name   => 'importtest',
                memory => 2048,
                cores  => 2,
                scsi0  => 'tnnvme:vol-vm-9990-disk-0-lun0,size=32G',
                scsi1  => 'tnnvme:vol-vm-9990-disk-1-lun1,size=8G',
                ide2   => 'local:iso/debian.iso,media=cdrom',
                snaptime => 1789610000,
            },
        },
    };
}

sub reset_world {
    %CONF   = ($VMID => base_conf());
    @WRITES = ();
    @api    = ();
    $LOCKS  = 0;
}

# ------------------------------------------------------- 1-3. --dry-run ---
reset_world();
my $plan = $PKG->import_foreign_snapshots($VMID, { dry_run => 1 });
is(scalar(@{ $plan->{import} }), 5, 'dry-run: planifica los 5 importables');
is(scalar(@WRITES), 0, 'dry-run: NO escribe la configuracion');
is($LOCKS, 0, 'dry-run: ni siquiera toma el lock');

# --------------------------------------------------- 4-16. the real run ---
reset_world();
my $res = $PKG->import_foreign_snapshots($VMID, {});
is($res->{imported}, 5, 'importa los 5 snapshots completos y validos');
is($LOCKS, 1, 'todo el trabajo ocurre dentro de un unico lock_config');
is(scalar(@WRITES), 1, 'y en una sola escritura de la configuracion');

my $after = $CONF{$VMID};
my $snaps = $after->{snapshots};
is_deeply([ sort keys %$snaps ],
    [ sort qw(s1 auto-2026-09-18_00-00 Daily-1 tn-weekly-7 manual_snap snap2026) ],
    'las secciones nuevas son exactamente las importables');

my $sec = $snaps->{'Daily-1'};
is_deeply([ sort keys %$sec ],
    [ sort qw(name memory cores scsi0 scsi1 ide2 parent snaptime description) ],
    'la seccion lleva copia de la config actual mas snaptime/description/parent');
ok(!exists $sec->{vmstate}, 'sin vmstate: no se promete RAM que no existe');
ok(!exists $sec->{snapstate}, 'sin snapstate: la seccion nace terminada');
ok(!exists $sec->{snapshots}, 'sin snapshots anidados');
is($sec->{snaptime}, 1789707600, 'snaptime es el creation de la cabina');
like($sec->{description}, qr/TrueNAS/, 'la descripcion dice de donde sale');
like($sec->{description}, qr/no RAM/i, '  ...y que no hay RAM');
like($sec->{description}, qr{pool/pve/vm-9990-disk-0}, '  ...y nombra el dataset');
is($sec->{parent}, 'auto-2026-09-18_00-00', 'parent = el snapshot inmediatamente anterior');
is($snaps->{'auto-2026-09-18_00-00'}{parent}, 's1',
    'el primero importado cuelga del s1 que ya existia');
is($after->{parent}, 'snap2026', 'conf.parent pasa al importado mas nuevo');

# 19. Nothing outside snapshots/parent changes: the written config is the one
#     that was loaded, plus the new sections. A writer that rebuilt the config
#     from the snapshot sections would pass every assertion above.
{
    my %top_after  = map { $_ => $after->{$_} }
        grep { $_ ne 'snapshots' && $_ ne 'parent' } keys %$after;
    my $before = base_conf();
    my %top_before = map { $_ => $before->{$_} }
        grep { $_ ne 'snapshots' && $_ ne 'parent' } keys %$before;
    is_deeply(\%top_after, \%top_before,
        'el resto de la configuracion de la VM queda intacta');
}

# 20. The one thing this command must never do: touch a section PVE wrote.
is_deeply($snaps->{s1}, base_conf()->{snapshots}{s1},
    'la seccion preexistente queda byte a byte igual');

# --------------------------------------------- 21-22. second pass (idempotencia) ---
@WRITES = ();
$LOCKS  = 0;
my $second = $PKG->import_foreign_snapshots($VMID, {});
is($second->{imported}, 0, 'segunda pasada: 0 importados');
is(scalar(@WRITES), 0, '  ...y NO se llama a write_config');

# ------------------------------------------------------- 23-26. refusals ---
sub refuses {
    my ($mangle) = @_;
    reset_world();
    $mangle->($CONF{$VMID});
    my $ok = eval { $PKG->import_foreign_snapshots($VMID, {}); 1 };
    my $err = $ok ? '' : ($@ // 'died');
    return ($err, scalar(@WRITES));
}

{
    my ($err, $writes) = refuses(sub { $_[0]->{template} = 1 });
    ok($err && !$writes, 'template: se rehusa y no escribe nada');
}
{
    my ($err, $writes) = refuses(sub { $_[0]->{lock} = 'backup' });
    ok($err && !$writes, 'config con lock: se rehusa y no escribe nada');
}
{
    my ($err, $writes) = refuses(sub { $_[0]->{snapshots}{s1}{snapstate} = 'prepare' });
    ok($err && !$writes, 'snapshot con snapstate: se rehusa y no escribe nada');
}
{
    my ($err, $writes) = refuses(sub { $_[0]->{scsi1} = 'local-lvm:vm-9990-disk-0,size=8G' });
    ok($err && !$writes, 'disco fuera del plugin: se rehusa y no escribe nada');
}
