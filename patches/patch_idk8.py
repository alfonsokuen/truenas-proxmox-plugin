#!/usr/bin/env python3
"""Parche idk8: discovery-CHAP para iSCSI.

TrueNAS 25.10 impone CHAP de discovery IMPLICITO en cuanto existe cualquier grupo
iscsi/auth en la cabina (el knob discovery_authmethod ya no existe). El plugin
configuraba CHAP solo en node.session.auth.*, asi que su propio discovery moria
con "initiator failed authorization" antes de llegar a la sesion. Verificado en
vivo 2026-08-23: discovery plano rechazado; discoverydb con las mismas
credenciales -> login OK.

Uso: patch_idk8.py <fichero_base> <fichero_salida>
"""
import sys, subprocess

base, out = sys.argv[1], sys.argv[2]
src = open(base, encoding="utf-8").read()
assert "_iscsi_discover" not in src, "la base ya tiene idk8"

ANCHOR = """    # Discovery (don't die on non-zero)
    _try_run(['iscsiadm','-m','discovery','-t','sendtargets','-p',$primary], "iSCSI discovery failed (primary)");
    for my $p (@extra) {
        _try_run(['iscsiadm','-m','discovery','-t','sendtargets','-p',$p], "iSCSI discovery failed ($p)");
    }
"""
NEW = """    # Discovery (don't die on non-zero)
    _iscsi_discover($scfg, $primary, 'primary');
    for my $p (@extra) {
        _iscsi_discover($scfg, $p, $p);
    }
"""
assert src.count(ANCHOR) == 1, "ancla del discovery no unica"
src = src.replace(ANCHOR, NEW, 1)

HELPER = """# TrueNAS 25.10 enforces discovery-CHAP implicitly the moment ANY iscsi auth
# group exists on the array - the old per-portal discovery_authmethod knob is
# gone from the API. So with CHAP credentials configured, a plain sendtargets
# discovery is refused ("initiator failed authorization") before the session
# auth this file already sets ever gets a chance. Feed the same credentials to
# the discoverydb first; without CHAP, keep the old one-shot discovery.
# Verified live 2026-08-23 against TrueNAS 25.10.4.
sub _iscsi_discover {
    my ($scfg, $portal, $label) = @_;
    if ($scfg->{tn_chap_user} && $scfg->{tn_chap_password}) {
        _try_run(['iscsiadm','-m','discoverydb','-t','sendtargets','-p',$portal,'-o','new'],
                 "iSCSI discoverydb create failed ($label)");
        for my $kv (['discovery.sendtargets.auth.authmethod','CHAP'],
                    ['discovery.sendtargets.auth.username',$scfg->{tn_chap_user}],
                    ['discovery.sendtargets.auth.password',$scfg->{tn_chap_password}]) {
            _try_run(['iscsiadm','-m','discoverydb','-t','sendtargets','-p',$portal,
                      '-o','update','-n',$kv->[0],'-v',$kv->[1]],
                     "iSCSI discoverydb auth update failed ($label)");
        }
        _try_run(['iscsiadm','-m','discoverydb','-t','sendtargets','-p',$portal,'--discover'],
                 "iSCSI discovery failed ($label)");
    } else {
        _try_run(['iscsiadm','-m','discovery','-t','sendtargets','-p',$portal],
                 "iSCSI discovery failed ($label)");
    }
}

"""
# insertar el helper a nivel de fichero, justo antes del sub que contiene el discovery
idx = src.find("    _iscsi_discover($scfg, $primary, 'primary');")
sub_start = src.rfind("\nsub ", 0, idx)
assert sub_start > 0, "no encuentro el sub contenedor"
src = src[:sub_start+1] + HELPER + src[sub_start+1:]

open(out, "w", encoding="utf-8").write(src)
r = subprocess.run(["perl", "-c", out], capture_output=True, text=True)
tail = r.stderr.strip().splitlines()[-1] if r.stderr else "?"
print("perl -c:", tail)
sys.exit(0 if r.returncode == 0 else 1)
