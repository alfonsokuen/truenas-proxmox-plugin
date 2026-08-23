#!/usr/bin/perl
# Does a newly created namespace ever reach the host as a block device?
#
# A disk move onto the pilot failed with "Could not locate NVMe device for
# TrueNAS UUID ...", reporting one namespace in the TrueNAS API and zero block
# devices in Linux. That is issue #12's symptom, and the plugin already carries
# a workaround for it - _nvme_resync_configfs writes the subsystem back to poke
# middleware into re-rendering the kernel target. What nobody had measured is
# which step actually publishes the namespace, or whether any of them do.
#
# This isolates that one question. It creates a namespace on a zvol that already
# exists, then looks for the device after each escalation in turn:
#
#   1. just wait                  - does the target send an AEN?
#   2. nvme ns-rescan             - does an explicit rescan find it?
#   3. nvmet.subsys.update        - does the #12 workaround publish it?
#   4. wait again after the poke
#
# and deletes the namespace at the end. Namespace deletion is permitted to the
# pilot key even though dataset deletion is not, so this leaves nothing behind
# that was not already there.
#
#   i32-nspublish.pl <storeid> <zvol-relative-path>
#   i32-nspublish.pl tn-pilot NVMe-DATA/pve-plugin-pilot/vm-9990-disk-0
#
# Exit: 0 the namespace published, 1 it never did, 2 refused to run.

use strict;
use warnings;
use lib '/usr/share/perl5';
use PVE::Storage;
use PVE::Storage::Custom::TrueNASPlugin;
use JSON::PP;

my ($storeid, $zvol) = @ARGV;
unless (defined $storeid && defined $zvol) {
    print STDERR "usage: $0 <storeid> <dataset/path/of/zvol>\n";
    exit 2;
}

my $cfg  = PVE::Storage::config();
my $scfg = PVE::Storage::storage_config($cfg, $storeid);
my $api  = \&PVE::Storage::Custom::TrueNASPlugin::_api_call;

my $nqn = $scfg->{tn_subsystem_nqn} or die "storage $storeid has no tn_subsystem_nqn\n";

# Which block devices exist right now. The comparison is against this set, so a
# device that was already present cannot be mistaken for the one we created.
sub blockdevs {
    my %s;
    opendir(my $dh, '/sys/block') or return {};
    $s{$_} = 1 for grep { /^nvme/ } readdir($dh);
    closedir($dh);
    return \%s;
}

sub report_new {
    my ($before, $label) = @_;
    my $now = blockdevs();
    my @new = sort grep { !$before->{$_} } keys %$now;
    if (@new) {
        print "  $label: APARECIO -> " . join(', ', @new) . "\n";
        return 1;
    }
    print "  $label: nada nuevo\n";
    return 0;
}

# ---------------------------------------------------------------------------

my $subsys = $api->($scfg, 'nvmet.subsys.query', [[['subnqn', '=', $nqn]]]);
die "subsystem $nqn not found on the target\n" unless ref $subsys eq 'ARRAY' && @$subsys;
my $sid = $subsys->[0]{id};
printf("subsistema id=%s name=%s namespaces=%d\n",
    $sid, $subsys->[0]{name} // '?', scalar @{ $subsys->[0]{namespaces} // [] });

my $before = blockdevs();
printf("dispositivos nvme antes: %s\n\n", join(', ', sort keys %$before) || '(ninguno)');

print "creando namespace sobre zvol/$zvol ...\n";
my $ns = $api->($scfg, 'nvmet.namespace.create', [{
    subsys_id   => $sid,
    device_type => 'ZVOL',
    device_path => "zvol/$zvol",
    enabled     => JSON::PP::true,
}]);
my $nsid = $ns->{id};
printf("  creado id=%s nsid=%s enabled=%s uuid=%s\n\n",
    $nsid // '?', $ns->{nsid} // '?',
    (defined $ns->{enabled} ? ($ns->{enabled} ? 'true' : 'false') : '?'),
    $ns->{device_uuid} // '-');

my $published = 0;

# Step 1 - the target should announce the change and the host should rescan.
for my $s (1 .. 6) {
    sleep 1;
    if (report_new($before, "paso 1, esperando (${s}s)")) { $published = 1; last }
}

# Step 2 - ask the host to look, in case no announcement arrived.
unless ($published) {
    print "\n";
    for my $c (sort glob('/dev/nvme[0-9]*')) {
        next unless -c $c;
        system('nvme', 'ns-rescan', $c);
    }
    sleep 2;
    $published = 1 if report_new($before, 'paso 2, tras nvme ns-rescan');
}

# Step 3 - the plugin's own #12 workaround: write the subsystem back unchanged
# so middleware re-renders the kernel target.
unless ($published) {
    print "\n";
    my $cur = $api->($scfg, 'nvmet.subsys.query', [[['id', '=', $sid]]]);
    my $aah = $cur->[0]{allow_any_host} ? JSON::PP::true : JSON::PP::false;
    eval {
        $api->($scfg, 'nvmet.subsys.update', [ $sid, { allow_any_host => $aah } ]);
        print "  nvmet.subsys.update aceptado (re-render solicitado)\n";
        1;
    } or print "  nvmet.subsys.update FALLO: $@";
    sleep 2;
    $published = 1 if report_new($before, 'paso 3, tras el workaround del #12');
}

# Step 4 - give it longer, then rescan once more.
unless ($published) {
    print "\n";
    for my $s (1 .. 10) {
        sleep 1;
        if (report_new($before, "paso 4, esperando (${s}s)")) { $published = 1; last }
    }
    unless ($published) {
        for my $c (sort glob('/dev/nvme[0-9]*')) {
            next unless -c $c;
            system('nvme', 'ns-rescan', $c);
        }
        sleep 2;
        $published = 1 if report_new($before, 'paso 4, rescan final');
    }
}

print "\n=== estado del namespace segun TrueNAS ===\n";
my $chk = $api->($scfg, 'nvmet.namespace.query', [[['id', '=', $nsid]]]) || [];
for my $n (@$chk) {
    printf("  id=%s nsid=%s enabled=%s device_path=%s uuid=%s\n",
        $n->{id} // '?', $n->{nsid} // '?',
        (defined $n->{enabled} ? ($n->{enabled} ? 'true' : 'false') : '?'),
        $n->{device_path} // '?', $n->{device_uuid} // '-');
}

print "\nlimpiando: borrando el namespace ...\n";
my $ok = eval { $api->($scfg, 'nvmet.namespace.delete', [ $nsid ]); 1 };
print $ok ? "  borrado\n" : "  FALLO al borrar: $@";

print "\n";
print $published
    ? "RESULTADO: el namespace SI se publica. Anota en que paso apareció.\n"
    : "RESULTADO: el namespace NO llega nunca al host. Ni el aviso del target, ni\n"
    . "un rescan explícito, ni el workaround del #12 lo hacen visible. El fallo\n"
    . "está entre middleware y el target del kernel, del lado de TrueNAS.\n";
exit($published ? 0 : 1);
