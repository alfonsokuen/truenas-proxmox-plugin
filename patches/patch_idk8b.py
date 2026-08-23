#!/usr/bin/env python3
"""Parche idk8b: el bucle principal de login iSCSI era codigo muerto.

`iscsiadm -m node -T <iqn>` imprime el RECORD completo del nodo, no la lista
"portal,tpgt iqn" que el parser espera, asi que @nodes quedaba vacio siempre:
ni node.startup, ni CHAP, ni login por el camino principal. Toda sesion entraba
por el fallback del final - un discovery PLANO + login SIN auth - que ademas
resetea el registro discoverydb. Sin CHAP eso colaba; con CHAP es exactamente
el camino que no puede autenticar. Verificado en vivo 2026-08-23: la secuencia
correcta a mano funciona; la del plugin, no.

Uso: patch_idk8b.py <fichero_idk8> <fichero_salida>
"""
import sys, subprocess

base, out = sys.argv[1], sys.argv[2]
src = open(base, encoding="utf-8").read()
assert "_iscsi_discover" in src, "la base no tiene idk8"
assert "was dead code" not in src, "la base ya tiene idk8b"

def rep(old, new, what):
    assert src.count(old) == 1, f"ancla no unica o ausente: {what}"
    return src.replace(old, new, 1)

A = """    my $iqn = $scfg->{tn_target_iqn};
    my @nodes = _run_lines(['iscsiadm','-m','node','-T',$iqn]);
"""
N = """    my $iqn = $scfg->{tn_target_iqn};
    # `iscsiadm -m node -T <iqn>` prints the full node RECORD, not the
    # "portal,tpgt iqn" list this loop parses - so @nodes never matched and the
    # whole loop below was dead code: the primary portal only ever logged in
    # through the no-auth fallback at the bottom of this sub. Plain mode never
    # noticed; CHAP mode could not establish a single session. List ALL nodes
    # (that one does print the list) and filter ourselves.
    my @nodes = grep { /\\s\\Q$iqn\\E$/ } _run_lines(['iscsiadm','-m','node']);
"""
src = rep(A, N, "listado de nodos")

A = """        next unless $n =~ /^(\\S+)\\s+$iqn$/;
        my $portal = _normalize_portal($1);
"""
N = """        # the list form is "190.0.2.1:3260,1 iqn..." - strip the ,tpgt suffix
        next unless $n =~ /^(\\S+?)(?:,\\d+)?\\s+\\Q$iqn\\E$/;
        my $portal = _normalize_portal($1);
"""
src = rep(A, N, "parse del portal")

A = """    if (!$have_session) {
        _try_run(['iscsiadm','-m','discovery','-t','sendtargets','-p',$primary], "iSCSI discovery retry");
"""
N = """    if (!$have_session) {
        # CHAP-aware retry: the plain `-m discovery` this used to run RESETS
        # the discoverydb record, wiping the auth idk8 just configured - the
        # fallback must go through the same helper as the main path.
        _iscsi_discover($scfg, $primary, 'retry');
"""
src = rep(A, N, "fallback CHAP-aware")

open(out, "w", encoding="utf-8").write(src)
r = subprocess.run(["perl", "-c", out], capture_output=True, text=True)
tail = r.stderr.strip().splitlines()[-1] if r.stderr else "?"
print("perl -c:", tail)
sys.exit(0 if r.returncode == 0 else 1)
