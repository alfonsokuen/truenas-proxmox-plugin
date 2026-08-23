#!/usr/bin/env python3
"""Parche idk7-v4: seguimientos del dual review de la v3 (APPROVE con 3 MEDIUM + 2 LOW).

Se aplica SOBRE la v3 instalada. Ancla por texto exacto y aborta si algo no casa.
Piezas:
  D1  constante WHITELIST_MIN_BUDGET_S
  D2  %_api_down_log_last pasa a `our` (testeable) + ventana del throttle derivada del backoff
  D3  helper _capped_api_deadline (clamp contra un deadline externo mas cercano)
  D4  activate_storage: usa el helper + clasifica el error del ensure (timeout esperado
      bajo marcador -> nota throttled; 401/DHCHAP/EINVAL -> warning nivel 0)
  D5  status(): el repair (unico otro camino API-capaz, via el self-heal de whitelist
      en _nvme_connect) tambien se acota cuando el marcador esta vigente
  D6  _nvme_reconcile_host_whitelist: reserva de presupuesto ANTES de cerrar el subsistema

Uso: patch_idk7_v4.py <fichero_v3> <fichero_salida>
"""
import sys, subprocess

base, out = sys.argv[1], sys.argv[2]
src = open(base, encoding="utf-8").read()
assert "_api_recently_down" in src, "la base no tiene la v3"
assert "_capped_api_deadline" not in src, "la base ya tiene la v4"

def rep(old, new, what):
    assert src.count(old) == 1, f"ancla no unica o ausente: {what}"
    return src.replace(old, new, 1)

# ---------- D1: constante ----------
A = "    API_DOWN_PROBE_BUDGET_S   => 2,    # deadline for API work while the marker stands\n"
N = A + (
    "    WHITELIST_MIN_BUDGET_S    => 5,    # don't BEGIN the close-then-authorize\n"
    "                                       # whitelist mutation with less API budget\n"
    "                                       # than this; deliberately above the probe\n"
    "                                       # budget, so a marker-capped ensure always\n"
    "                                       # defers it instead of starting it\n"
)
src = rep(A, N, "constantes")

# ---------- D2a: hash del throttle testeable ----------
src = rep("my %_api_down_log_last;\n", "our %_api_down_log_last;   # `our`, so tests can reach the throttle state\n",
          "declaracion del hash de throttle")

# ---------- D2b: ventana derivada del backoff ----------
A = ("    my $verbose = ($scfg->{tn_debug} // 0) >= 1;\n"
     "    return if !$verbose && ($now - $last) < API_DOWN_LOG_S;\n")
N = ("    my $verbose = ($scfg->{tn_debug} // 0) >= 1;\n"
     "    # API_DOWN_LOG_S is a CEILING: when the marker window itself is shorter, the\n"
     "    # throttle follows it. A fixed 60s against the default 30s backoff meant every\n"
     "    # other marker period logged nothing and the journal undercounted outages 2x.\n"
     "    my $win = _status_probe_backoff($scfg);\n"
     "    $win = API_DOWN_LOG_S if $win <= 0 || $win > API_DOWN_LOG_S;\n"
     "    return if !$verbose && ($now - $last) < $win;\n")
src = rep(A, N, "ventana del throttle")

# ---------- D3: helper de deadline con clamp ----------
A = ("    my $left = $down_until - time();\n"
     "    return $left > 0 ? $left : undef;\n"
     "}\n")
N = A + """
# The short probe deadline, clamped to any outer deadline already standing.
# _retry_with_backoff() takes the nearer of the outer and its own budget on
# entry, so handing it a LATER deadline than the one it inherited would extend
# what e.g. cluster_lock_storage already bounded - a cap must only ever shrink.
sub _capped_api_deadline {
    my $cap = time() + API_DOWN_PROBE_BUDGET_S;
    $cap = $_api_deadline if defined($_api_deadline) && $_api_deadline < $cap;
    return $cap;
}
"""
src = rep(A, N, "helper _capped_api_deadline")

# ---------- D4: activate_storage ----------
A = """            if (defined(my $left = _api_recently_down($scfg))) {
                _log_api_down_note($scfg, 'activate_storage', $storeid, $left,
                    'capping subsystem ensure at ' . API_DOWN_PROBE_BUDGET_S . 's');
                local $_api_deadline = time() + API_DOWN_PROBE_BUDGET_S;
                eval { _nvme_ensure_subsystem($scfg) };
            } else {
                eval { _nvme_ensure_subsystem($scfg) };
            }
            if ($@) {
                _log($scfg, 0, 'warning', "[TrueNAS] activate_storage: subsystem "
                    . "ensure failed for $storeid, still attempting connect: $@");
            }"""
N = """            my $marker_left = _api_recently_down($scfg);
            if (defined($marker_left)) {
                _log_api_down_note($scfg, 'activate_storage', $storeid, $marker_left,
                    'capping subsystem ensure at ' . API_DOWN_PROBE_BUDGET_S . 's');
                local $_api_deadline = _capped_api_deadline();
                eval { _nvme_ensure_subsystem($scfg) };
            } else {
                eval { _nvme_ensure_subsystem($scfg) };
            }
            if (my $ensure_err = $@) {
                # Two different facts used to share one warning, and only one is
                # news. A capped ensure running out of ITS OWN probe budget is
                # the marker doing its job - throttle it like the marker's other
                # notes, or a 10s-poll node emits a level-0 warning six times a
                # minute for the whole outage. Anything else (401, DHCHAP
                # mismatch, EINVAL...) is a real fault and keeps the loud path:
                # mixing the two is how real faults hide inside expected noise.
                if (defined($marker_left)
                    && $ensure_err =~ /Gave up on|timed?\\s?out|timeout|did not answer/i) {
                    _log_api_down_note($scfg, 'ensure-budget', $storeid, $marker_left,
                        'subsystem ensure hit the probe budget; will retry next poll');
                } else {
                    _log($scfg, 0, 'warning', "[TrueNAS] activate_storage: subsystem "
                        . "ensure failed for $storeid, still attempting connect: $ensure_err");
                }
            }"""
src = rep(A, N, "bloque v3 de activate_storage")

# ---------- D5: status() acota el repair ----------
A = """    if (($scfg->{tn_transport_mode} // '') eq 'nvme-tcp') {
        eval { _nvme_connect($scfg, repair => 1) };
        _log($scfg, 2, 'debug', "[TrueNAS] status: path reconcile failed: $@") if $@;
    }"""
N = """    if (($scfg->{tn_transport_mode} // '') eq 'nvme-tcp') {
        # Detection is sysfs, but repair mode has one API-capable branch: the
        # whitelist self-heal inside _nvme_connect() calls
        # _nvme_ensure_subsystem() when portals refused us. This runs BEFORE
        # the marker gate below, so without its own cap it was the second
        # uncapped API path on the poll - the very hole the gate closes.
        if (defined(_api_recently_down($scfg))) {
            local $_api_deadline = _capped_api_deadline();
            eval { _nvme_connect($scfg, repair => 1) };
        } else {
            eval { _nvme_connect($scfg, repair => 1) };
        }
        _log($scfg, 2, 'debug', "[TrueNAS] status: path reconcile failed: $@") if $@;
    }"""
src = rep(A, N, "repair en status()")

# ---------- D6: reserva de presupuesto en el reconcile de whitelist ----------
A = "    # Close first, authorize second. The kernel holds allow_any_host and an"
N = """    # Do not BEGIN a mutation the budget cannot plausibly finish. The order
    # below is close-first-authorize-second (the target refuses the reverse),
    # so dying between the two steps leaves the subsystem shut with an EMPTY
    # host list until a later ensure heals it. Better never to start: an open,
    # not-yet-tightened subsystem is degraded security for a while; a closed,
    # empty one refuses every host trying to (re)connect.
    # Paren-call form, not the bareword: this sub sits ABOVE the constants
    # block in the file, so the bareword does not exist yet when this compiles.
    my $left_budget = _api_budget_remaining();
    if (defined($left_budget) && $left_budget < WHITELIST_MIN_BUDGET_S()) {
        _log($scfg, 1, 'info', "[TrueNAS] nvme_reconcile_host_whitelist: deferring, "
            . "only ${left_budget}s left of the API budget (need "
            . WHITELIST_MIN_BUDGET_S() . "s)");
        return;
    }

""" + A
src = rep(A, N, "reserva whitelist")

open(out, "w", encoding="utf-8").write(src)
r = subprocess.run(["perl", "-c", out], capture_output=True, text=True)
tail = r.stderr.strip().splitlines()[-1] if r.stderr else "?"
print("perl -c:", tail)
sys.exit(0 if r.returncode == 0 else 1)
