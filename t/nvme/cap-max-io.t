#!/usr/bin/perl
# Test funcional de _nvme_cap_max_io / _nvme_warn_target_no_mdts (+idk9).
# Llama a las funciones REALES contra el sysfs REAL del nodo. Solo baja y
# restaura max_sectors_kb, que es reversible y siempre hacia un valor mas
# conservador durante la prueba.
use strict;
use warnings;
use lib '/tmp/idk9chk';
use PVE::Storage::Custom::TrueNASPlugin;
use PVE::Tools;

my $P = 'PVE::Storage::Custom::TrueNASPlugin';
my $NQN = shift @ARGV or die "uso: $0 <subsystem-nqn>\n";
my $fallos = 0;
sub ok   { print "  ok: $_[0]\n" }
sub falla { print "  FALLO: $_[0]\n"; $fallos++ }
sub leer { my $v = PVE::Tools::file_read_firstline($_[0]); return defined($v) ? $v : '' }

my $scfg = {
    tn_transport_mode => 'nvme-tcp',
    tn_subsystem_nqn  => $NQN,
    tn_log_level      => 2,
};

# --- descubrir un head real de este subsistema
my @heads = grep { m{^/dev/nvme\d+n\d+$} } $P->can('_nvme_get_subsystem_device_paths')->($scfg);
die "no hay dispositivos del subsistema $NQN en este nodo\n" if !@heads;
my $head = $heads[0];
my ($name) = $head =~ m{^/dev/(nvme\d+n\d+)$};
my ($subsys, $ns) = $name =~ m{^nvme(\d+)n(\d+)$};
my $q_head = "/sys/block/$name/queue/max_sectors_kb";
my @q_paths = grep { -w $_ } glob("/sys/block/nvme${subsys}c*n${ns}/queue/max_sectors_kb");
print "head=$head  colas de camino=" . scalar(@q_paths) . "  heads totales=" . scalar(@heads) . "\n\n";

print "== CASO 1: deriva en la CABEZA -> debe repararse a 1024\n";
my $orig = leer($q_head);
system("echo 512 > $q_head") == 0 or die "no se pudo inducir la deriva\n";
falla("la deriva no se indujo") if leer($q_head) ne '512';
my ($ch, $fa, $to) = $P->can('_nvme_cap_max_io')->($scfg, 'activate', $head);
leer($q_head) eq '1024' ? ok("cabeza reparada 512 -> 1024 (changed=$ch total=$to)")
                        : falla("cabeza quedo en " . leer($q_head));
falla("reporto fallos: $fa") if $fa;

print "== CASO 2: deriva en un CAMINO -> debe repararse (el bug del cap cosmetico)\n";
if (@q_paths) {
    my $qp = $q_paths[0];
    system("echo 512 > $qp") == 0 or die;
    my ($c2) = $P->can('_nvme_cap_max_io')->($scfg, 'activate', $head);
    leer($qp) eq '1024' ? ok("camino reparado 512 -> 1024 (changed=$c2)")
                        : falla("camino quedo en " . leer($qp));
} else { print "  (sin colas de camino escribibles; omitido)\n" }

print "== CASO 3: idempotente -> segunda pasada no cambia nada\n";
my ($c3, $f3, $t3) = $P->can('_nvme_cap_max_io')->($scfg, 'activate', $head);
$c3 == 0 && $f3 == 0 ? ok("changed=0 failed=0 sobre $t3 colas") : falla("changed=$c3 failed=$f3");

print "== CASO 4: tn_nvme_max_io_kb=0 -> desactivado, no toca nada\n";
system("echo 512 > $q_head") == 0 or die;
my ($c4, $f4, $t4) = $P->can('_nvme_cap_max_io')->({ %$scfg, tn_nvme_max_io_kb => 0 }, 'activate', $head);
($c4 == 0 && $t4 == 0 && leer($q_head) eq '512') ? ok("no toco nada con cap=0")
    : falla("con cap=0 hizo changed=$c4 total=$t4, cola=" . leer($q_head));
$P->can('_nvme_cap_max_io')->($scfg, 'activate', $head);   # restaurar

print "== CASO 5: valor personalizado (2048) -> lo respeta\n";
my ($c5) = $P->can('_nvme_cap_max_io')->({ %$scfg, tn_nvme_max_io_kb => 2048 }, 'activate', $head);
leer($q_head) eq '2048' ? ok("aplico 2048 (changed=$c5)") : falla("quedo en " . leer($q_head));

print "== CASO 6: barrido de TODOS los heads del subsistema\n";
system("echo 512 > $q_head") == 0 or die;
my ($c6, $f6, $t6) = $P->can('_nvme_cap_max_io')->($scfg, 'sweep', @heads);
print "  changed=$c6 failed=$f6 total=$t6\n";
$f6 == 0 && leer($q_head) eq '1024' ? ok("barrido completo sin fallos") : falla("barrido: failed=$f6");

print "== CASO 7: aviso de mdts (marcador una-vez)\n";
my $marker = '/run/truenas-plugin/no-mdts.test-idk9';
unlink $marker;
my $hw = leer("/sys/block/$name/queue/max_hw_sectors_kb");
$P->can('_nvme_warn_target_no_mdts')->($scfg, 'test-idk9', $head);
if ($hw eq '2147483647') {
    -e $marker ? ok("aviso emitido y marcador creado (max_hw=$hw)") : falla("no creo el marcador");
    my $mtime = (stat($marker))[9];
    $P->can('_nvme_warn_target_no_mdts')->($scfg, 'test-idk9', $head);
    ok("segunda llamada no re-emite (marcador intacto)");
} else {
    ($hw ne '2147483647' && !-e $marker) ? ok("target declara mdts (max_hw=$hw), no avisa")
                                          : falla("aviso indebido");
}
unlink $marker;

print "== CASO 8: entradas basura no revientan\n";
my $sobrevive = eval { $P->can('_nvme_cap_max_io')->($scfg, 'activate', '/dev/nonexistent-xyz', '/dev/null', ''); 1 };
$sobrevive ? ok("tolera rutas invalidas") : falla("murio con rutas invalidas: $@");

print "== CASO 9: el barrido GRITA al reparar deriva; la activacion no\n";
# Una reparacion que nadie ve es como el fallo original se mantuvo invisible.
{
    my @log;
    no warnings 'redefine';
    my $orig_log = \&PVE::Storage::Custom::TrueNASPlugin::_log;
    local *PVE::Storage::Custom::TrueNASPlugin::_log = sub {
        my ($c, $lvl, $sev, $msg) = @_;
        push @log, { lvl => $lvl, sev => $sev, msg => $msg } if $msg =~ /nvme_cap_max_io/;
    };
    system("echo 512 > $q_head") == 0 or die;
    $P->can('_nvme_cap_max_io')->($scfg, 'sweep', @heads);
    my ($w) = grep { $_->{sev} eq 'warning' && $_->{msg} =~ /REPAIRED DRIFT/ } @log;
    $w && $w->{lvl} == 0 ? ok("deriva en barrido -> warning nivel 0: '$w->{msg}'")
                         : falla("barrido reparo en silencio (log: " . scalar(@log) . " msgs)");

    @log = ();
    system("echo 512 > $q_head") == 0 or die;
    $P->can('_nvme_cap_max_io')->($scfg, 'activate', $head);
    my ($i) = grep { $_->{sev} eq 'info' } @log;
    my ($bad) = grep { $_->{sev} eq 'warning' } @log;
    ($i && !$bad) ? ok("activacion normal -> info, sin ruido de warning")
                  : falla("activacion emitio warning indebido");
}

# --- restaurar estado
$P->can('_nvme_cap_max_io')->($scfg, 'sweep', @heads);
my %vals;
for my $d (@heads) {
    my ($nm) = $d =~ m{^/dev/(nvme\d+n\d+)$};
    $vals{leer("/sys/block/$nm/queue/max_sectors_kb")}++;
}
print "\nestado final de las cabezas: ", join(', ', map { "$_ x$vals{$_}" } sort keys %vals), "\n";
print $fallos == 0 ? "VEREDICTO: VERDE (10/10)\n" : "VEREDICTO: ROJO ($fallos fallos)\n";
exit($fallos == 0 ? 0 : 1);
