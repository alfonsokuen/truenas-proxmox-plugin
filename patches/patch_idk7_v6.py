#!/usr/bin/env python3
"""Parche idk7-v6: consolidado del dual review de la v5 (WARNING 3M/2L + 4P1/5P2, 0 P0/HIGH).

El patron dominante de la ronda: SEVERIDAD — hechos correctamente identificados como
visibles, escritos donde no se ven. Piezas:
  F1  _log_api_down_note acepta severidad opcional (default 'info')
  F2  activate_storage: fallo real REPETIDO bajo marcador -> nota 'ensure-fault'
      (warning, throttled, con extracto) en vez de warning sin throttle cada poll;
      la nota 'ensure-budget' sube a severidad warning
  F3  nvmet.subsys.create envuelta como sus hermanas (era la unica mutacion que
      propagaba cruda hasta el clasificador: "outcome is unknown" archivado como rutina)
  F4  defer de whitelist: clave por subsistema (no por host), y sin marcador NO usa la
      plantilla "array marked down" (culparia a una cabina sana) sino warning directo
  F5  $will_close es la UNICA fuente del predicado del close (mata el mutante M2)
  F6  E4 sube de nivel 1 (invisible por default) a: nota throttled bajo marcador /
      warning nivel 0 sin el
  F7  fallo del repair de status() bajo marcador: nota 'repair-fail' (perder
      redundancia de camino no puede ser un hecho solo-debug)
  F8  $granted se clampa a 0 (no mas "capped to -3s") + comentario de E1 corregido
      (host.create/update SI pueden mutar antes de morir)

Uso: patch_idk7_v6.py <fichero_v5> <fichero_salida>
"""
import sys, subprocess

base, out = sys.argv[1], sys.argv[2]
src = open(base, encoding="utf-8").read()
assert "will_close" in src, "la base no tiene la v5"
assert "ensure-fault" not in src, "la base ya tiene la v6"

def rep(old, new, what):
    assert src.count(old) == 1, f"ancla no unica o ausente: {what}"
    return src.replace(old, new, 1)

# ---------- F1: severidad opcional en la nota ----------
A = "    my ($scfg, $tag, $storeid, $left, $what) = @_;\n"
N = "    my ($scfg, $tag, $storeid, $left, $what, $sev) = @_;\n"
src = rep(A, N, "firma de _log_api_down_note")

A = """    _log($scfg, 0, 'info', "[TrueNAS] $tag: '" . ($storeid // '-') . "' $what; "
        . "array marked down for another " . int($left) . "s");"""
N = """    # Severity per tag: chatter ('status', 'activate_storage') stays info, but a
    # note that CARRIES A CAUSE ('ensure-budget', 'ensure-fault', ...) must
    # survive a >=warning syslog filter, or nobody who filters ever reads it.
    _log($scfg, 0, $sev // 'info', "[TrueNAS] $tag: '" . ($storeid // '-') . "' $what; "
        . "array marked down for another " . int($left) . "s");"""
src = rep(A, N, "cuerpo de _log_api_down_note")

# ---------- F2: ensure-budget a warning + fallo real repetido throttled ----------
A = """                    _log_api_down_note($scfg, 'ensure-budget', $storeid, $marker_left,
                        "subsystem ensure hit the probe budget ($excerpt); will retry next poll");
                } else {
                    _log($scfg, 0, 'warning', "[TrueNAS] activate_storage: subsystem "
                        . "ensure failed for $storeid, still attempting connect: $ensure_err");
                }"""
N = """                    _log_api_down_note($scfg, 'ensure-budget', $storeid, $marker_left,
                        "subsystem ensure hit the probe budget ($excerpt); will retry next poll",
                        'warning');
                } elsif (defined($marker_left)) {
                    # A real fault (wrapped death, auth failure, DHCHAP...) that
                    # REPEATS while the marker stands: still a warning - the cause
                    # rides in the excerpt - but throttled. Unthrottled, a 10s-poll
                    # node re-prints it 6x/min for the whole outage (measured on
                    # the self-heal path the narrowed reserve re-enabled), which
                    # buries anything new. First occurrence still logs at once.
                    _log_api_down_note($scfg, 'ensure-fault', $storeid, $marker_left,
                        "subsystem ensure failed ($excerpt), still attempting connect",
                        'warning');
                } else {
                    _log($scfg, 0, 'warning', "[TrueNAS] activate_storage: subsystem "
                        . "ensure failed for $storeid, still attempting connect: $ensure_err");
                }"""
src = rep(A, N, "clasificador de activate_storage")

# ---------- F3: subsys.create envuelta ----------
A = """    my $subsys = _api_call_mutate($scfg, 'nvmet.subsys.create', [{
        name => $name,
        subnqn => $nqn,
        # Open by default (back-compat); whitelist when tn_nvme_allow_any_host=0.
        allow_any_host => _nvme_allow_any_host_json($scfg),
    }]);"""
N = """    my $subsys = eval { _api_call_mutate($scfg, 'nvmet.subsys.create', [{
        name => $name,
        subnqn => $nqn,
        # Open by default (back-compat); whitelist when tn_nvme_allow_any_host=0.
        allow_any_host => _nvme_allow_any_host_json($scfg),
    }]) };
    # Wrapped like its sibling mutations. This was the one mutation that still
    # propagated a bare "Gave up on ... outcome is unknown" to the marker
    # classifier, which filed it as routine probe noise - a CREATE whose outcome
    # is unknown is news, not noise.
    die "nvme_ensure_subsystem: failed to create subsystem $nqn: $@" if $@;"""
src = rep(A, N, "subsys.create")

# ---------- F4: defer con clave por subsistema y sin plantilla enganosa ----------
A = """        _log_api_down_note($scfg, 'whitelist-defer', undef,
            _api_recently_down($scfg) // $left_budget,
            "deferring close-then-authorize on subsys $subsys_id, only "
            . "${left_budget}s of API budget left (need " . WHITELIST_MIN_BUDGET_S() . 's)');
        return;"""
N = """        if (defined(my $marker_s = _api_recently_down($scfg))) {
            # Keyed per SUBSYSTEM - the unit of work. A per-host bucket let one
            # storage's defer swallow its sibling's for good (proven in review).
            _log_api_down_note($scfg, 'whitelist-defer', "subsys$subsys_id", $marker_s,
                "deferring close-then-authorize, only ${left_budget}s of API "
                . 'budget left (need ' . WHITELIST_MIN_BUDGET_S() . 's)', 'warning');
        } else {
            # No marker: something else shrank the budget (cluster lock, an op
            # budget). The note's fixed "array marked down" suffix would blame a
            # healthy array and send the diagnosis chasing a dead cabinet that
            # does not exist - say what actually happened instead.
            _log($scfg, 0, 'warning', "[TrueNAS] nvme_reconcile_host_whitelist: "
                . "deferring close-then-authorize on subsys $subsys_id, only "
                . "${left_budget}s of API budget left (need "
                . WHITELIST_MIN_BUDGET_S() . 's) under an outer deadline');
        }
        return;"""
src = rep(A, N, "defer whitelist")

# ---------- F5: una sola fuente del predicado del close ----------
A = "    if (!defined($cur_allow_any_host) || $cur_allow_any_host) {\n"
N = """    # $will_close above IS this predicate - single source. They drifting apart
    # re-opens the original HIGH: undef + short budget skipping the reserve and
    # then executing the close it had no budget to finish.
    if ($will_close) {
"""
src = rep(A, N, "gate del close")

# ---------- F6: E4 visible ----------
A = """    _log($scfg, 1, 'warning', "[TrueNAS] sync_portals: port_subsys.query failed, "
        . "assuming no existing bindings: $@") if $@;"""
N = """    if (my $q_err = $@) {
        # Level 0, not level 1: with tn_debug=0 (the default) level 1 never
        # prints, and "the assumption has to be on the record" was not - the
        # exact silence this file already paid a debugging session to learn.
        if (defined(my $marker_s = _api_recently_down($scfg))) {
            _log_api_down_note($scfg, 'portal-query', "subsys$subsys_id", $marker_s,
                'port_subsys.query failed, assuming no existing bindings', 'warning');
        } else {
            _log($scfg, 0, 'warning', "[TrueNAS] sync_portals: port_subsys.query "
                . "failed, assuming no existing bindings: $q_err");
        }
    }"""
src = rep(A, N, "eval sync_portals")

# ---------- F7: el repair que falla deja rastro ----------
A = """        eval { _nvme_connect($scfg, repair => 1) };
        _log($scfg, 2, 'debug', "[TrueNAS] status: path reconcile failed: $@") if $@;"""
N = """        eval { _nvme_connect($scfg, repair => 1) };
        if (my $rep_err = $@) {
            if (defined(my $marker_s = _api_recently_down($scfg))) {
                # Routine under the 2s cap, but losing NVMe path redundancy must
                # not be a debug-only fact: one throttled warning per window.
                _log_api_down_note($scfg, 'repair-fail', $storeid, $marker_s,
                    'path reconcile failed', 'warning');
            } else {
                _log($scfg, 2, 'debug', "[TrueNAS] status: path reconcile failed: $rep_err");
            }
        }"""
src = rep(A, N, "repair de status()")

# ---------- F8: clamp de granted + comentario honesto ----------
A = "            my $granted = $deadline - $started;\n"
N = ("            my $granted = $deadline - $started;\n"
     "            $granted = 0 if $granted < 0;   # an already-expired outer deadline\n")
src = rep(A, N, "clamp granted")

A = "    # An authorize that dies of budget mutates nothing; the next ensure retries.\n"
N = ("    # An authorize that dies of budget at most leaves a reusable host record\n"
     "    # behind (host.create/update can land before the death); the next ensure\n"
     "    # picks it up idempotently.\n")
src = rep(A, N, "comentario E1")

open(out, "w", encoding="utf-8").write(src)
r = subprocess.run(["perl", "-c", out], capture_output=True, text=True)
tail = r.stderr.strip().splitlines()[-1] if r.stderr else "?"
print("perl -c:", tail)
sys.exit(0 if r.returncode == 0 else 1)
