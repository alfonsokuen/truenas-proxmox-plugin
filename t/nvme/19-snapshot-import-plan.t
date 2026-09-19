#!/usr/bin/perl
# The planner that decides which snapshots taken on the TrueNAS side may be
# imported into a guest configuration - and, just as important, which may not.
#
# Background: snapshots created on the array (a periodic task, or a human on
# the TrueNAS UI) are invisible to the Snapshots tab, because that tab reads
# only $conf->{snapshots} in /etc/pve/qemu-server/<vmid>.conf. They are not
# harmless, though: one of them being newer than s1 makes `qm rollback s1`
# fail with "not most recent snapshot", and a rollback past it destroys it.
# `truenas-proxmox-manage import-snapshots` writes the missing sections so the
# GUI can see and delete them.
#
# Importing the wrong thing is worse than importing nothing: a section that
# covers only some of the disks leaves the others in unusedN on rollback, and
# a name PVE cannot parse poisons the config file for every later operation.
# So the planner is fail-closed, and this file pins both directions - the
# candidates it must accept and the ones it must refuse.
#
# Run with:  prove -v t/nvme/19-snapshot-import-plan.t

use strict;
use warnings;
use Test::More;
use FindBin;
use File::Spec;
use JSON::PP;

my $PLUGIN = File::Spec->rel2abs("$FindBin::Bin/../../TrueNASPlugin.pm");
plan skip_all => "TrueNASPlugin.pm not found at $PLUGIN" unless -f $PLUGIN;

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
my $query = $PKG->can('_tn_snapshot_query_datasets');
my $plan  = $PKG->can('_plan_snapshot_import');

# A missing subroutine is a failure, not a skip: the whole point of this file
# is to go red on a plugin that cannot plan an import.
unless ($query && $plan) {
    plan tests => 2;
    ok($query, '_tn_snapshot_query_datasets existe');
    ok($plan,  '_plan_snapshot_import existe');
    exit 1;
}

plan tests => 42;

# ---------------------------------------------------------------- fixture ---
# Real shape of pool.snapshot.query captured on the array, with the datasets
# and names rewritten to the cases below.
my $FIXTURE = "$FindBin::Bin/fixtures/tn-pool-snapshot-query.json";
open(my $fh, '<', $FIXTURE) or die "cannot read $FIXTURE: $!";
my $raw = do { local $/; <$fh> };
close($fh);
my $RECORDS = JSON::PP->new->decode($raw);

my $DS0 = 'pool/pve/vm-9990-disk-0';
my $DS1 = 'pool/pve/vm-9990-disk-1';
my $V0  = 'tnnvme:vol-vm-9990-disk-0-lun0';
my $V1  = 'tnnvme:vol-vm-9990-disk-1-lun1';
my $LONG = 'a' . ('b' x 40);   # 41 chars: one over what pve-configid accepts

my @calls;
my $api_answer = sub { return $RECORDS };
{
    no strict 'refs';
    no warnings 'redefine';
    *{"${PKG}::_log"}      = sub { 1 };
    *{"${PKG}::_api_call"} = sub {
        my ($scfg, $method, $params) = @_;
        push @calls, [ $method, $params ];
        return $api_answer->($method, $params);
    };
}

my $scfg = { tn_dataset => 'pool/pve' };

# ------------------------------------------------- 1-5. the query itself ---
my $by_ds = $query->($scfg, [ $DS0, $DS1 ]);
is(scalar(@calls), 1, 'una sola llamada a la API para ambos datasets');
is($calls[0][0], 'pool.snapshot.query', '  ...y es pool.snapshot.query');
is_deeply($calls[0][1][0], [ [ 'dataset', 'in', [ $DS0, $DS1 ] ] ],
    '  ...filtrada por dataset in [...] (nada de traerse la cabina entera)');
is_deeply($calls[0][1][1], { extra => { properties => ['creation'] } },
    '  ...pidiendo explicitamente la propiedad creation');
is($by_ds->{$DS0}{'Daily-1'}, 1789707600, 'creation.rawvalue llega como epoch');

# 6-9. An answer the plugin cannot understand is an error, never "no
#      snapshots": an empty hash here would make every candidate look absent
#      and would report a full array as having nothing to import.
for my $bad ( [ undef, 'respuesta nula' ],
              [ { }, 'respuesta que no es lista' ],
              [ [ 'not-a-hash' ], 'registro que no es hash' ],
              [ [ { dataset => $DS0 } ], 'registro sin nombre de snapshot' ] ) {
    my ($answer, $what) = @$bad;
    $api_answer = sub { return $answer };
    my $ok = eval { $query->($scfg, [ $DS0 ]); 1 };
    ok(!$ok, "$what: muere en vez de responder 'sin snapshots'");
}
$api_answer = sub { return $RECORDS };

# 10. Snapshots of a dataset we did not ask about are dropped, so a filter the
#     middleware silently ignored cannot smuggle a neighbour's snapshot in.
{
    my $only0 = $query->($scfg, [ $DS0 ]);
    is_deeply([ sort keys %$only0 ], [ $DS0 ],
        'solo se conservan los datasets consultados');
}

# ----------------------------------------------------------- the planner ---
my $by_volid = { $V0 => $by_ds->{$DS0}, $V1 => $by_ds->{$DS1} };
my $existing = { s1 => { snaptime => 1789610000 } };

# The array also holds 'cloned-snap', which something else is cloned from.
# The caller establishes that separately (one pool.dataset.query per
# candidate) and hands the verdict to the planner.
my %BLOCK = ( clone_blocked => { 'cloned-snap' => 1 } );

my $p = $plan->($existing, $by_volid, 's1', { %BLOCK });

# 11-16. >=5 positives: complete on every volume, name PVE can parse.
my %imported = map { $_->{name} => $_ } @{ $p->{import} };
for my $good (qw(auto-2026-09-18_00-00 Daily-1 tn-weekly-7 manual_snap snap2026)) {
    ok($imported{$good}, "importable: $good");
}
is(scalar(@{ $p->{import} }), 5, 'y no se cuela nada mas en la lista de importables');

# 17-18. snaptime is the array's creation time, not the time of the import.
is($imported{'Daily-1'}{snaptime}, 1789707600, 'snaptime = creation del snapshot');
is($imported{'snap2026'}{snaptime}, 1789718400, '  ...para cada uno el suyo');

# 19-22. The chain: each imported snapshot hangs off the newest snapshot older
#        than itself, the ones PVE already had included.
is($imported{'auto-2026-09-18_00-00'}{parent}, 's1',
    'el mas antiguo importado cuelga del ultimo snapshot que ya tenia PVE');
is($imported{'Daily-1'}{parent}, 'auto-2026-09-18_00-00', 'cadena por snaptime (2)');
is($imported{'tn-weekly-7'}{parent}, 'Daily-1', 'cadena por snaptime (3)');
is($imported{'snap2026'}{parent}, 'manual_snap', 'cadena por snaptime (4)');

# 23. The list comes back oldest first, which is the order it must be applied
#     in for the parents to exist when they are referenced.
is_deeply([ map { $_->{name} } @{ $p->{import} } ],
    [ qw(auto-2026-09-18_00-00 Daily-1 tn-weekly-7 manual_snap snap2026) ],
    'los importables salen ordenados de mas antiguo a mas nuevo');

# 24. The newest of everything is imported, so the guest's parent moves to it.
is($p->{new_parent}, 'snap2026', 'conf.parent pasa al importado mas nuevo');

# 25-31. >=5 negatives: names PVE would refuse, and names PVE reserves.
my %invalid = %{ $p->{invalid} };
like($invalid{'auto.bad'} // '', qr/valid/i, 'invalido: punto en el nombre');
like($invalid{'vzdump'} // '', qr/reserv/i, 'invalido: vzdump esta reservado');
like($invalid{'__base__'} // '', qr/reserv/i, 'invalido: __base__ esta reservado');
like($invalid{'__replicate_9990-0_1789700300'} // '', qr/reserv/i,
    'invalido: __replicate_*');
like($invalid{'pending'} // '', qr/reserv/i, 'invalido: pending mata a write_vm_config');
like($invalid{'current'} // '', qr/reserv/i, 'invalido: current lo usa la API');
like($invalid{$LONG} // '', qr/40|long/i, 'invalido: 41 caracteres');

# 32. No creation time from the array: refuse rather than invent one. A
#     section with snaptime 0 shows as 1970 in the GUI and breaks the order.
like($invalid{'no-creation'} // '', qr/creation|timestamp/i,
    'invalido: sin creation no se inventa la fecha');

# 33-34. Partial coverage is listed, with the volume that is missing, and is
#        NOT imported: a section without one of the disks sends that disk to
#        unusedN on rollback.
ok(!$imported{'partial-one'}, 'parcial: no se importa');
is_deeply($p->{partial}{'partial-one'}, [ $V1 ],
    '  ...y se dice en que volumen falta');

# 35. Already in the configuration: nothing to do, and the existing section is
#     never rewritten.
is_deeply($p->{present}, [ 's1' ], 'lo ya presente se salta');

# 36-37. A snapshot with a dependent clone cannot be deleted from PVE later
#        (ZFS refuses), so it is not imported - and the guard is checked in
#        both directions: the same snapshot, with no clone reported, IS
#        importable. A rule that refuses everything passes the first half.
ok(!$imported{'cloned-snap'}, 'con clon dependiente: no se importa');
like($invalid{'cloned-snap'} // '', qr/clone/i, '  ...y el motivo lo dice');
{
    my $q = $plan->($existing, $by_volid, 's1', {});
    my %imp = map { $_->{name} => 1 } @{ $q->{import} };
    ok($imp{'cloned-snap'}, 'sin clones: el mismo snapshot si se importa');
}

# 38-39. --match narrows the candidates without changing any verdict.
{
    my $q = $plan->($existing, $by_volid, 's1', { match => '^Daily-' });
    is_deeply([ map { $_->{name} } @{ $q->{import} } ], [ 'Daily-1' ],
        '--match deja solo lo que coincide');
    is($q->{new_parent}, 'Daily-1', '  ...y el parent se recalcula sobre eso');
}

# 40. If PVE already holds the newest snapshot, conf.parent must not move: the
#     imported ones are older, and stealing the pointer would rewrite history.
{
    my $newer = { s1 => { snaptime => 1789610000 },
                  s9 => { snaptime => 1789999999 } };
    my $q = $plan->($newer, $by_volid, 's9', {});
    is($q->{new_parent}, undef, 'si el mas nuevo ya era de PVE, conf.parent no se toca');
}

# 41. Second pass: everything importable is now in the config, so the plan is
#     empty. This is what makes the command idempotent.
{
    my %all = %$existing;
    $all{$_} = { snaptime => $imported{$_}{snaptime} } for keys %imported;
    my $q = $plan->(\%all, $by_volid, 'snap2026', { %BLOCK });
    is(scalar(@{ $q->{import} }), 0, 'segunda pasada: no queda nada por importar');
}
