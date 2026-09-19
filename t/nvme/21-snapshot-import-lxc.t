#!/usr/bin/perl
# import_foreign_snapshots() for CONTAINERS.
#
# A container's zvols are snapshotted by the same TrueNAS periodic task as a
# VM's, and were just as invisible to PVE - but the importer used to refuse
# every CT by name. It no longer does, and what changes for a container is
# only the config class and how a volume is spelled:
#
#   - the guest type comes from which configuration file exists, and LXC goes
#     through PVE::LXC::Config (same AbstractConfig primitives: lock_config,
#     load_config, write_config, __snapshot_copy_config - LXC overrides none
#     of them);
#   - the volumes are rootfs and mpN, and only the ones classify_mountpoint()
#     calls a 'volume' count: a bind mount (mp1=/mnt/host/data) is not a
#     storage volume and must be IGNORED, not refused - refusing it would
#     refuse most containers;
#   - an mpN on another storage IS refused, exactly like a VM disk elsewhere:
#     a section naming it could never be rolled back as a whole;
#   - a CT template is refused, like a VM template;
#   - there is never a vmstate.
#
# Run with:  prove -v t/nvme/21-snapshot-import-lxc.t

use strict;
use warnings;
use Test::More;
use FindBin;
use File::Spec;
use File::Temp qw(tempdir);
use Storable qw(dclone);

my $PLUGIN = File::Spec->rel2abs("$FindBin::Bin/../../TrueNASPlugin.pm");
plan skip_all => "TrueNASPlugin.pm not found at $PLUGIN" unless -f $PLUGIN;

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
unless ($PKG->can('import_foreign_snapshots')) {
    plan tests => 1;
    fail('import_foreign_snapshots existe');
    exit 1;
}

# ------------------------------------------------ stub PVE::LXC::Config ---
# Same contract as the real one on PVE 9.2.4: load_config hands out a COPY,
# foreach_volume walks rootfs + mp0..mpN and hands the callback the PARSED
# mountpoint (volume/type/mp), and __snapshot_copy_config is inherited
# verbatim from PVE::AbstractConfig.
our %CONF;
our @WRITES;
our $LOCKS = 0;
{
    package PVE::LXC::Config;
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
    # PVE::LXC::Config::classify_mountpoint, verbatim.
    sub classify_mountpoint {
        my ($class, $vol) = @_;
        if ($vol =~ m!^/!) {
            return 'device' if $vol =~ m!^/dev/!;
            return 'bind';
        }
        return 'volume';
    }
    sub valid_volume_keys {
        my ($class) = @_;
        return ('rootfs', map { "mp$_" } 0 .. 7);
    }
    sub foreach_volume {
        my ($class, $conf, $func, @param) = @_;
        for my $key ($class->valid_volume_keys()) {
            my $str = $conf->{$key};
            next if !defined($str);
            my ($volume, @opts) = split(/,/, $str);
            my $mp = { volume => $volume,
                       type   => $class->classify_mountpoint($volume) };
            for my $o (@opts) {
                my ($k, $v) = split(/=/, $o, 2);
                $mp->{$k} = $v;
            }
            $mp->{mp} = '/' if $key eq 'rootfs';
            $func->($key, $mp, @param);
        }
    }
    # Verbatim from PVE::AbstractConfig (PVE 9.2.4); LXC::Config does not
    # override it.
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
$INC{'PVE/LXC/Config.pm'} = 1;

# A VM config class that must never be reached for a container.
our $QEMU_TOUCHED = 0;
{
    package PVE::QemuConfig;
    sub load_config { $QEMU_TOUCHED++; die "PVE::QemuConfig used for a CT\n" }
    sub lock_config { $QEMU_TOUCHED++; die "PVE::QemuConfig used for a CT\n" }
}
$INC{'PVE/QemuConfig.pm'} = 1;

our $STORECFG = {
    ids => {
        tnnvme => { type => 'truenasplugin', tn_dataset => 'pool/pve',
                    tn_api_host => 'array-a' },
        'local'     => { type => 'dir' },
        'local-lvm' => { type => 'lvmthin' },
    },
};
{
    no strict 'refs';
    no warnings 'redefine';
    *{"PVE::Storage::config"} = sub { return $STORECFG };
}

# --------------------------------------------------------- stub the array ---
# rootfs is disk-0, mp0 is disk-1. 'Daily-1' and 'tn-weekly-7' exist on both;
# 'only-root' exists on the rootfs alone and is therefore partial.
sub records {
    my @r;
    for my $ds (qw(pool/pve/vm-9991-disk-0 pool/pve/vm-9991-disk-1)) {
        push @r,
            { dataset => $ds, snapshot_name => 'Daily-1', createtxg => '101',
              properties => { creation => { rawvalue => '1789700000' } } },
            { dataset => $ds, snapshot_name => 'tn-weekly-7', createtxg => '202',
              properties => { creation => { rawvalue => '1789800000' } } };
    }
    push @r,
        { dataset => 'pool/pve/vm-9991-disk-0', snapshot_name => 'only-root',
          createtxg => '303',
          properties => { creation => { rawvalue => '1789900000' } } };
    return \@r;
}

our @api;
our @ASKED;
{
    no strict 'refs';
    no warnings 'redefine';
    *{"${PKG}::_log"} = sub { 1 };
    *{"${PKG}::_api_call"} = sub {
        my ($scfg, $method, $params) = @_;
        push @api, $method;
        if ($method eq 'pool.snapshot.query') {
            my $ds = eval { $params->[0][0][2] };
            push @ASKED, @$ds if ref($ds) eq 'ARRAY';
            return records();
        }
        return [] if $method eq 'pool.dataset.query';
        die "unexpected API call $method\n";
    };
}

my $VMID = 9991;

# The guest type is decided by the configuration file that exists. A real
# /etc/pve is not available here, so both directories are redirected.
my $LXCDIR  = tempdir(CLEANUP => 1);
my $QEMUDIR = tempdir(CLEANUP => 1);
{
    no strict 'refs';
    ${"${PKG}::TN_LXC_CONF_DIR"}  = $LXCDIR;
    ${"${PKG}::TN_QEMU_CONF_DIR"} = $QEMUDIR;
}
sub make_ct_conf_file {
    open(my $fh, '>', "$LXCDIR/$VMID.conf") or die $!;
    print $fh "arch: amd64\n";
    close($fh);
}

sub base_conf {
    return {
        hostname => 'ct-importtest',
        arch     => 'amd64',
        memory   => 512,
        ostype   => 'debian',
        rootfs   => 'tnnvme:vol-vm-9991-disk-0-lun0,size=8G',
        mp0      => 'tnnvme:vol-vm-9991-disk-1-lun1,mp=/data,size=16G',
        mp1      => '/mnt/host/photos,mp=/photos',       # bind mount: ignored
        mp2      => '/dev/sdz,mp=/dev/sdz',              # device: ignored
    };
}

sub reset_world {
    %CONF = ($VMID => base_conf());
    @WRITES = ();
    @api    = ();
    @ASKED  = ();
    $LOCKS  = 0;
    $QEMU_TOUCHED = 0;
    make_ct_conf_file();
}

# ------------------------------------ 1-11. a container imports normally ---
reset_world();
my $res = eval { $PKG->import_foreign_snapshots($VMID, {}) };
if (!$res) {
    # Against a plugin that still refuses containers by name this is the
    # first thing that goes red, and the rest of the file must still report
    # instead of taking the whole run down with it.
    fail("CT: import_foreign_snapshots acepta un contenedor");
    diag($@ // 'died');
    $res = { imported => 0, partial => {}, import => [] };
}
is($res->{imported}, 2, 'CT: importa los 2 snapshots completos');
is($QEMU_TOUCHED, 0, '  ...sin tocar PVE::QemuConfig');
is($LOCKS, 1, '  ...dentro de un unico lock_config de PVE::LXC::Config');
is(scalar(@WRITES), 1, '  ...y una sola escritura');

my $snaps = $CONF{$VMID}{snapshots};
is_deeply([ sort keys %$snaps ], [ sort qw(Daily-1 tn-weekly-7) ],
    'las secciones nuevas son exactamente las importables');
is_deeply($res->{partial}{'only-root'}, [ 'tnnvme:vol-vm-9991-disk-1-lun1' ],
    'un snapshot que falta en mp0 es parcial, no importable');

my $sec = $snaps->{'tn-weekly-7'};
is($sec->{rootfs}, 'tnnvme:vol-vm-9991-disk-0-lun0,size=8G',
    'la seccion copia el rootfs tal cual');
is($sec->{mp1}, '/mnt/host/photos,mp=/photos',
    '  ...y tambien el bind mount, que se copia pero no se exige en la cabina');
ok(!exists $sec->{vmstate}, 'sin vmstate: un CT nunca lo tiene');
is($sec->{parent}, 'Daily-1', 'la cadena de parents se arma por tiempo');
is($CONF{$VMID}{parent}, 'tn-weekly-7', 'conf.parent pasa al mas nuevo importado');

# 12. Only the two zvols were asked about: a bind mount is not a dataset.
{
    reset_world();
    eval { $PKG->import_foreign_snapshots($VMID, { dry_run => 1 }) };
    my %uniq = map { $_ => 1 } @ASKED;
    is_deeply([ sort keys %uniq ],
        [ qw(pool/pve/vm-9991-disk-0 pool/pve/vm-9991-disk-1) ],
        'solo se consultan los zvols: el bind mount y el device no son datasets');
}

# ------------------------------------------------------- 13-16. refusals ---
sub refuses {
    my ($mangle) = @_;
    reset_world();
    $mangle->($CONF{$VMID});
    my $ok = eval { $PKG->import_foreign_snapshots($VMID, {}); 1 };
    return ($ok ? '' : ($@ // 'died'), scalar(@WRITES));
}

{
    my ($err, $writes) = refuses(sub { $_[0]->{mp0} = 'local-lvm:vm-9991-disk-0,mp=/data' });
    like($err, qr/outside this plugin/, 'mp0 en otro storage: se rehusa');
    is($writes, 0, '  ...sin escribir nada');
}
{
    my ($err, $writes) = refuses(sub { $_[0]->{template} = 1 });
    like($err, qr/CT $VMID is a template/, 'CT template: se rehusa, y se nombra como CT');
    is($writes, 0, '  ...sin escribir nada');
}

# --------------------------------- 17. a VMID that is a VM sigue siendo VM ---
{
    reset_world();
    unlink("$LXCDIR/$VMID.conf");
    my $ok = eval { $PKG->import_foreign_snapshots($VMID, {}); 1 };
    ok(!$ok && $QEMU_TOUCHED,
        'sin /etc/pve/lxc/<vmid>.conf el invitado se trata como VM');
}

done_testing();
