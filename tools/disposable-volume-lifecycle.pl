#!/usr/bin/perl
# Ciclo de vida de un volumen DESECHABLE (vm-<VMID>-disk-N) con un arbol de plugin, contra el TrueNAS
# REAL: alloc -> escribir y verificar un patron -> snapshot -> rollback (el patron original vuelve) ->
# borrar snapshot -> crecer -> liberar, 3 veces por el broker instalado y por un broker PRIVADO del
# arbol, y despues una prueba de fallo (broker privado congelado) solo contra el privado.
# Encontro un fallo que ningun test unitario veia: JSON::XS codificaba volsize como cadena.
#
# TOCA EL ARRAY REAL: crea y borra volumenes de 1-2 GiB llamados vm-<VMID>-disk-N.
# SEGURIDAD (revisada por Sol y Fable):
#   - Antes de cambiar nada comprueba que el VMID (9900-9999) NO existe como VM/CT, que no hay
#     volumenes, datasets ni namespaces con ese VMID y que el PID dado es de verdad un broker
#     privado de truenas-plugin con el directorio del socket indicado. Si algo no cuadra, sale sin
#     tocar nada Y SIN EJECUTAR LA LIMPIEZA FINAL.
#   - Solo libera y borra lo que ESTE proceso creo (lleva registro de volumenes y datasets propios).
# Lo ideal es un laboratorio. Variables: IDK_PLUGIN_PM (TrueNASPlugin.pm del arbol), IDK_STORE
# (por defecto tn-prod), IDK_VMID (por defecto 9970), PRIVLOG (stderr del broker privado).
# uso: perl disposable-volume-lifecycle.pl <socket-privado> <pid-padre-broker-privado>
use strict; use warnings;
use PVE::Storage; use Time::HiRes qw(time sleep); use IO::Socket::UNIX; use Socket qw(SOCK_STREAM);
use Digest::SHA qw(sha256_hex); use File::Temp qw(tempfile);
$| = 1;
my ($priv, $bp) = @ARGV; die "uso: socket pid\n" unless $priv && $bp && $bp =~ /^[0-9]+$/;
my $VMID  = $ENV{IDK_VMID} // 9970;
my $STORE = $ENV{IDK_STORE} // 'tn-prod';
die "VMID fuera del rango de pruebas 9900-9999\n" unless $VMID =~ /^99[0-9][0-9]$/;
die "el socket privado no puede estar en /run/truenas-plugin (es el de produccion)\n" if $priv =~ m{^/run/truenas-plugin/};

# ---------- el PID es de verdad el broker privado ----------
{
    open(my $cf, '<', "/proc/$bp/cmdline") or die "el pid $bp no existe\n";
    my $cmd = do { local $/; <$cf> } // ''; close $cf;
    die "el pid $bp no es un truenas-plugin-broker\n" unless $cmd =~ /truenas-plugin-broker/;
    open(my $ef, '<', "/proc/$bp/environ") or die "no puedo leer el entorno del pid $bp\n";
    my $env = do { local $/; <$ef> } // ''; close $ef;
    my ($rundir) = $env =~ /(?:^|\0)TRUENAS_BROKER_RUNDIR=([^\0]*)/;
    (my $want = $priv) =~ s{/[^/]*$}{};
    die "el broker $bp no usa el directorio $want (usa " . ($rundir // 'el de produccion') . ")\n"
        unless defined $rundir && $rundir eq $want;
}

my $cfg  = PVE::Storage::config();
my $scfg = PVE::Storage::storage_config($cfg, $STORE) or die "storage $STORE desconocido\n";
my $P = 'PVE::Storage::Custom::TrueNASPlugin';
{ my $pm = $ENV{IDK_PLUGIN_PM} or die "falta IDK_PLUGIN_PM\n"; no warnings 'redefine'; no warnings 'prototype'; require $pm; }
no strict 'refs';
my $ds = $scfg->{tn_dataset};
my $orig_open = \&{"${P}::_broker_open_socket"};
sub via_private { no warnings 'redefine'; *{"${P}::_broker_open_socket"} = sub { IO::Socket::UNIX->new(Peer => $priv, Type => SOCK_STREAM) }; }
sub via_prod    { no warnings 'redefine'; *{"${P}::_broker_open_socket"} = $orig_open; }
sub api { my ($m, $p) = @_; return &{"${P}::_api_call"}($scfg, $m, $p) }

my ($pass, $fail) = (0, 0);
sub ok { my ($c, $msg) = @_; if ($c) { $pass++; print "    PASS  $msg\n" } else { $fail++; print "    FAIL  $msg\n" } return $c }
sub sh { my $o = `$_[0] 2>&1`; return ($? >> 8, $o) }

sub mine { my $v = shift; return defined($v) && $v =~ /vm-${VMID}-disk-[0-9]/ }
sub my_volumes { my $l = $P->list_images($STORE, $scfg, $VMID, undef, {}); return grep { mine($_->{volid} // $_->{volname}) } @{ $l || [] } }
sub bare { my $v = shift; $v =~ s/^\Q$STORE\E://; return $v }

# ---------- PREFLIGHT: nada de lo que sigue se ejecuta si algo de aqui falla ----------
die "VMID $VMID ya tiene un fichero de configuracion de VM/CT en el cluster; abortando sin tocar nada\n"
    if glob("/etc/pve/nodes/*/qemu-server/$VMID.conf /etc/pve/nodes/*/lxc/$VMID.conf");
die "ya hay volumenes vm-$VMID-* en $STORE; abortando sin tocar nada\n" if my_volumes();
{
    my $dd = api('pool.dataset.query', [ [ ['id', '^', "$ds/vm-${VMID}-disk-"] ], { select => ['id'] } ]) // [];
    die "ya hay datasets $ds/vm-$VMID-disk-* en TrueNAS (" . join(',', map { $_->{id} } @$dd) . "); abortando sin tocar nada\n" if @$dd;
    my $nn = api('nvmet.namespace.query', [ [ ['device_path', '~', "vm-${VMID}-disk-"] ] ]) // [];
    die "ya hay namespaces vm-$VMID-disk-* en TrueNAS; abortando sin tocar nada\n" if @$nn;
}
# A partir de aqui lo que aparezca con este VMID lo hemos creado nosotros.
my $STARTED = 1;
my (%OWN_VOL, %OWN_DS);

sub inventory {
    my $d = api('pool.dataset.query', [ [ ['id', '^', "$ds/"] ], { select => ['id'] } ]) // [];
    my $n = api('nvmet.namespace.query', [ [], { select => ['id'] } ]) // [];
    my $s = api('pool.snapshot.query', [ [ ['dataset', '^', "$ds/"] ], { select => ['id'] } ]) // [];
    return (scalar(@$d), scalar(@$n), scalar(@$s));
}
my @base = inventory();
print "inventario inicial (datasets bajo $ds, namespaces, snapshots): @base\n";

# Todo alloc pasa por aqui: se anota el dataset que se va a crear (el preflight garantizo que no existia)
sub alloc {
    my ($name, $kib) = @_;
    $OWN_DS{"$ds/$name"} = 1;
    my $v = eval { $P->alloc_image($STORE, $scfg, $VMID, 'raw', $name, $kib) };
    my $e = $@;
    $OWN_VOL{ bare($v) } = 1 if $v;
    return ($v, $e);
}
sub release {   # deactivate + free_image + el worker diferido que PVE::Storage::vdisk_free ejecuta fuera del lock
    my ($vn) = @_;
    eval { $P->deactivate_volume($STORE, $scfg, $vn, undef, {}); 1 };
    my $w = eval { $P->free_image($STORE, $scfg, $vn, 0, 'raw') }; my $e = $@;
    eval { $w->() } if ref($w) eq 'CODE';
    delete $OWN_VOL{$vn} unless $e;
    return ($w, $e);
}
sub purge_orphans {   # SOLO datasets que este proceso creo y que quedaron sin namespace ni snapshots
    for my $id (sort keys %OWN_DS) {
        my $x = (api('pool.dataset.query', [ [ ['id', '=', $id] ], { extra => { retrieve_children => JSON::PP::false, properties => [qw(volsize)] } } ]) // [])->[0] or next;
        next unless $x->{type} eq 'VOLUME';
        my $sz = $x->{volsize}{parsed} // 0; next unless $sz == 1073741824 || $sz == 2147483648;
        next if @{ api('nvmet.namespace.query', [ [ ['device_path', '~', $id] ] ]) // [] };
        next if @{ api('pool.snapshot.query', [ [ ['dataset', '=', $id] ], { select => ['id'] } ]) // [] };
        eval { api('pool.dataset.delete', [ $id, { recursive => JSON::PP::false, force => JSON::PP::false } ]); 1 }
            ? print "  (cleanup) resto huerfano propio borrado: $id\n" : print "  (cleanup) no pude borrar $id: $@";
    }
}
sub cleanup {
    return unless $STARTED;
    my %present = map { (bare($_->{volid} // $_->{volname}) => 1) } my_volumes();
    for my $vn (sort keys %OWN_VOL) {
        next unless $present{$vn} && mine($vn);
        my (undef, $e) = release($vn); print "  (cleanup) no pude liberar $vn: $e" if $e;
    }
    sleep 1; purge_orphans();
}
# La limpieza final solo corre si el preflight paso ($STARTED lo fija DESPUES de las guardas).
END { local $?; if ($STARTED) { eval { via_prod(); cleanup() } } }

sub pattern_file { my $mib = shift; my ($fh, $fn) = tempfile('idk28pat-XXXXXX', DIR => '/tmp', UNLINK => 1);
    open(my $r, '<', '/dev/urandom') or die; binmode $fh; binmode $r; read($r, my $buf, $mib * 1048576); print {$fh} $buf; close $fh; close $r;
    return ($fn, sha256_hex($buf)); }
sub dev_sha { my ($dev, $mib, $skip) = @_; my ($rc, $o) = sh("dd if=$dev bs=1M count=$mib skip=" . ($skip // 0) . " iflag=direct 2>/dev/null | sha256sum"); return (split ' ', $o)[0] }

sub cycle {
    my ($label) = @_;
    print "\n===== ciclo de vida: $label =====\n";
    my %t; my $t0;
    my $tick = sub { my $k = shift; $t{$k} = (time - $t0) * 1000 };
    $t0 = time;
    my ($vol, $aerr) = alloc("vm-$VMID-disk-0", 1048576);
    $tick->('alloc_image'); ok($vol && mine($vol), "alloc_image creo el volumen (" . ($vol // 'undef') . ")") or do { print "      error: $aerr"; cleanup(); return };
    $vol = bare($vol);
    ok(scalar(grep { ($_->{volid} // $_->{volname} // '') =~ /vm-$VMID-disk-[0-9]/ } @{ $P->list_images($STORE, $scfg, $VMID, undef, {}) || [] }) == 1, 'list_images lo ve exactamente una vez');
    my $sz = eval { $P->volume_size_info($scfg, $STORE, $vol, 5) };
    ok($sz && $sz == 1073741824, "volume_size_info = 1 GiB (" . ($sz // 'undef') . ")");
    $t0 = time; eval { $P->activate_volume($STORE, $scfg, $vol, undef, {}) }; $tick->('activate_volume');
    ok(!$@, 'activate_volume sin error' . ($@ ? ": $@" : ''));
    my ($dev) = $P->path($scfg, $vol, $STORE, undef);
    ok($dev && -b $dev, "path() apunta a un dispositivo de bloque (" . ($dev // 'undef') . ")") or do { cleanup(); return };
    my ($pf1, $sha1) = pattern_file(32);
    my ($rc) = sh("dd if=$pf1 of=$dev bs=1M oflag=direct conv=fsync");
    ok($rc == 0, 'escritura de 32 MiB de patron aleatorio');
    ok(dev_sha($dev, 32) eq $sha1, 'lectura directa = patron escrito (sha256)');
    $t0 = time; eval { $P->volume_snapshot($scfg, $STORE, $vol, 'idk28t1', 0) }; $tick->('volume_snapshot');
    ok(!$@, 'volume_snapshot idk28t1' . ($@ ? ": $@" : ''));
    my (undef, $zn) = $P->parse_volname($vol); my $snapid = "$ds/$zn\@idk28t1";
    ok(scalar(@{ api('pool.snapshot.query', [ [ ['id', '=', $snapid] ], { select => ['id'] } ]) // [] }) == 1, 'el snapshot existe en TrueNAS (exactamente uno)');
    my ($pf2, $sha2) = pattern_file(16);
    sh("dd if=$pf2 of=$dev bs=1M oflag=direct conv=fsync");
    ok(dev_sha($dev, 16) eq $sha2, 'tras el snapshot se sobrescriben 16 MiB (sha distinta del original)');
    $t0 = time; eval { $P->volume_snapshot_rollback($scfg, $STORE, $vol, 'idk28t1') }; $tick->('rollback');
    ok(!$@, 'volume_snapshot_rollback' . ($@ ? ": $@" : ''));
    eval { $P->deactivate_volume($STORE, $scfg, $vol, undef, {}); $P->activate_volume($STORE, $scfg, $vol, undef, {}) };
    ok(dev_sha($dev, 32) eq $sha1, 'tras el rollback los 32 MiB vuelven a ser el patron ORIGINAL');
    $t0 = time; eval { $P->volume_snapshot_delete($scfg, $STORE, $vol, 'idk28t1') }; $tick->('snapshot_delete');
    ok(!$@, 'volume_snapshot_delete' . ($@ ? ": $@" : ''));
    ok(scalar(@{ api('pool.snapshot.query', [ [ ['id', '=', $snapid] ], { select => ['id'] } ]) // [] }) == 0, 'el snapshot ya no existe en TrueNAS');
    $t0 = time; my $new = eval { $P->volume_resize($scfg, $STORE, $vol, 2147483648, 0) }; $tick->('volume_resize');
    ok(!$@, 'volume_resize a 2 GiB' . ($@ ? ": $@" : ''));
    my $sz2 = eval { $P->volume_size_info($scfg, $STORE, $vol, 5) };
    ok($sz2 && $sz2 == 2147483648, "volume_size_info = 2 GiB (" . ($sz2 // 'undef') . ")");
    ok(dev_sha($dev, 32) eq $sha1, 'crecer el disco no toca los datos que ya estaban');
    $t0 = time; eval { $P->deactivate_volume($STORE, $scfg, $vol, undef, {}) }; $tick->('deactivate_volume');
    $t0 = time; my ($w, $ferr) = release($vol); $tick->('free_image');
    ok(!$ferr, 'free_image' . ($ferr ? ": $ferr" : ''));
    ok(ref($w) eq 'CODE', 'free_image devolvio el worker diferido y se ejecuto');
    ok(scalar(my_volumes()) == 0, 'no queda ningun volumen vm-<VMID>-* en list_images');
    my @after = inventory();
    ok("@after" eq "@base", "inventario final = inicial (@after)");
    print "  tiempos (ms): " . join('  ', map { sprintf("%s=%.0f", $_, $t{$_} // 0) } qw(alloc_image activate_volume volume_snapshot rollback snapshot_delete volume_resize deactivate_volume free_image)) . "\n";
    return \%t;
}

my (@tp, @tn);
for my $i (1 .. 3) {
    via_prod();    my $a = cycle("ronda $i - broker de PRODUCCION + plugin del arbol"); push @tp, $a if $a;
    via_private(); my $b = cycle("ronda $i - broker PRIVADO del arbol, socket privado");   push @tn, $b if $b;
}
sub med { my ($arr, $k) = @_; my @v = sort { $a <=> $b } map { $_->{$k} // 0 } @$arr; return @v ? $v[int(@v / 2)] : 0 }
my @keys = qw(alloc_image activate_volume volume_snapshot rollback snapshot_delete volume_resize free_image);
print "\n  MEDIANA de 3 ciclos (ms)   "; printf "%-12s", substr($_, 0, 11) for @keys; print "\n";
printf "  broker produccion          "; printf "%-12.0f", med(\@tp, $_) for @keys; print "\n";
printf "  broker privado del arbol   "; printf "%-12.0f", med(\@tn, $_) for @keys; print "\n";

# ---------- fallo: el broker privado congelado mientras llega un snapshot ----------
print "\n===== fallo: broker privado congelado (SIGSTOP) durante volume_snapshot =====\n";
via_private();
my ($vol, $aerr2) = alloc("vm-$VMID-disk-1", 1048576);
ok($vol && mine($vol), "volumen de prueba creado (" . ($vol // 'undef') . ")") or do { print "      error: $aerr2"; exit 2 };
$vol = bare($vol);
my (undef, $zn) = $P->parse_volname($vol); my $snapid = "$ds/$zn\@idk28f1";
my @workers = grep { /^[0-9]+$/ } split ' ', `pgrep -P $bp`;
ok(scalar(@workers) >= 1, "workers del broker privado localizados (@workers)");
kill 'STOP', @workers;
my $t0 = time; my $local = { %$scfg, tn_broker_timeout => 2, tn_api_retry_max => 0 };
my $err = do { local $@; eval { $P->volume_snapshot($local, $STORE, $vol, 'idk28f1', 0) }; $@ };
my $took = time - $t0;
kill 'CONT', @workers;
ok($err ne '', "volume_snapshot con el broker congelado FALLA (en lugar de colgarse): " . substr($err, 0, 70));
ok($took >= 3.0 && $took <= 9.0, sprintf('tardo %.1fs (dos esperas de ~2 s, no un cuelgue)', $took));
sleep 2.5;   # el broker descongelado atiende la cola: las peticiones ya vencieron
ok(scalar(@{ api('pool.snapshot.query', [ [ ['id', '=', $snapid] ], { select => ['id'] } ]) // [] }) == 0,
   'NO se creo ningun snapshot fantasma: el broker rechazo la peticion vencida SIN ejecutarla');
my $log = ''; for my $lf ("$ENV{PRIVLOG}", "$ENV{PRIVLOG}.err") { if (open(my $fh, '<', $lf)) { local $/; $log .= <$fh>; close $fh } }
my $n_exp = () = $log =~ /request expired in queue/g;
ok($n_exp >= 1, "el log del broker privado cuenta $n_exp peticion(es) vencida(s) en cola");
my ($w2, $ferr) = release($vol); sleep 1; purge_orphans();
ok(!$ferr && scalar(my_volumes()) == 0, 'volumen de prueba liberado' . ($ferr ? ": $ferr" : ''));
my @final = inventory();
ok("@final" eq "@base", "inventario final = inicial (@final)");

via_prod(); cleanup();
my @end = inventory();
print "\n== RESUMEN: $pass PASS, $fail FAIL; inventario inicial (@base) -> final (@end): " . ("@base" eq "@end" ? "SIN RESTOS" : "HAY DIFERENCIAS") . "\n";
exit($fail ? 1 : 0);
