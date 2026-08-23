#!/usr/bin/env python3
"""Parche idk7-v5: consolidado del dual review de la v4 (WARNING 1H/3M + 2P1/4P2).

Se aplica SOBRE la v4. Piezas (cada una prescrita por un revisor):
  E1  [HIGH r2 + P1 r1] D6 se estrecha: la reserva solo aplica si el CLOSE va a
      ejecutarse; el camino authorize-only (cur_allow_any_host=false, los dos call
      sites reales) nunca se difiere. + defer visible via nota throttled nivel 0.
  E2  [P1 r1 + MED r2] clasificador D4 por estructura: ancla a las DOS frases de
      muerte autogeneradas del retry engine, no substrings de payload ajeno; y la
      nota incluye un extracto del error (throttle recorta frecuencia, no contenido).
  E3  [P2 r1] el error nivel 0 de budget nombra el presupuesto EFECTIVO cuando un
      deadline externo lo recorto.
  E4  [P2 r1] eval de port_subsys.query deja su suposicion por escrito.
  E5  [LOW r2] D5 colapsado a `local $x = cond ? cap : $x` + un solo eval.

Uso: patch_idk7_v5.py <fichero_v4> <fichero_salida>
"""
import sys, subprocess

base, out = sys.argv[1], sys.argv[2]
src = open(base, encoding="utf-8").read()
assert "_capped_api_deadline" in src, "la base no tiene la v4"
assert "will_close" not in src, "la base ya tiene la v5"

def rep(old, new, what):
    assert src.count(old) == 1, f"ancla no unica o ausente: {what}"
    return src.replace(old, new, 1)

# ---------- E1: D6 estrechada + visible ----------
A = """    my $left_budget = _api_budget_remaining();
    if (defined($left_budget) && $left_budget < WHITELIST_MIN_BUDGET_S()) {
        _log($scfg, 1, 'info', "[TrueNAS] nvme_reconcile_host_whitelist: deferring, "
            . "only ${left_budget}s left of the API budget (need "
            . WHITELIST_MIN_BUDGET_S() . "s)");
        return;
    }
"""
N = """    # The reserve exists for the CLOSE step only: dying between closing and
    # authorizing is what leaves the subsystem shut with an empty host list.
    # When the subsystem is already closed ($cur_allow_any_host false - which
    # is what both real call sites pass in whitelist mode), the only work left
    # is the authorize, and deferring THAT is the opposite of protection: it
    # leaves the closed-and-empty state standing, and kills the repair-mode
    # self-heal in _nvme_connect() for as long as the marker keeps renewing.
    # An authorize that dies of budget mutates nothing; the next ensure retries.
    my $will_close = !defined($cur_allow_any_host) || $cur_allow_any_host;
    my $left_budget = _api_budget_remaining();
    if ($will_close && defined($left_budget) && $left_budget < WHITELIST_MIN_BUDGET_S()) {
        # Level 0 via the throttled note, not level 1: "I did not harden the
        # subsystem" is exactly the class of fact this file already paid a
        # debugging session (2026-08-23) to learn must not live at a level the
        # default config discards.
        _log_api_down_note($scfg, 'whitelist-defer', undef,
            _api_recently_down($scfg) // $left_budget,
            "deferring close-then-authorize on subsys $subsys_id, only "
            . "${left_budget}s of API budget left (need " . WHITELIST_MIN_BUDGET_S() . 's)');
        return;
    }
"""
src = rep(A, N, "reserva D6")

# ---------- E2: clasificador estructural + extracto ----------
A = """                if (defined($marker_left)
                    && $ensure_err =~ /Gave up on|timed?\\s?out|timeout|did not answer/i) {
                    _log_api_down_note($scfg, 'ensure-budget', $storeid, $marker_left,
                        'subsystem ensure hit the probe budget; will retry next poll');
                } else {"""
N = """                my $excerpt = $ensure_err;
                $excerpt =~ s/\\s+/ /g;
                $excerpt = substr($excerpt, 0, 160) . '...' if length($excerpt) > 160;
                # Classify by the retry engine's own two death sentences - both
                # self-generated, matched from the string START. Never by
                # substrings of a foreign payload: a constraint error towing a
                # Python traceback can contain the word "timeout", and that is
                # the one error class the engine logs only at debug level, so
                # misfiling it here erased its last visible trace. Wrapped or
                # nested deaths ("failed to authorize host: Gave up on...")
                # stay loud on purpose: they mean work beyond the probe died.
                if (defined($marker_left)
                    && $ensure_err =~ /^Gave up on |^Operation failed after \\d+ retries: /) {
                    _log_api_down_note($scfg, 'ensure-budget', $storeid, $marker_left,
                        "subsystem ensure hit the probe budget ($excerpt); will retry next poll");
                } else {"""
src = rep(A, N, "clasificador D4")

# ---------- E3: presupuesto efectivo en el error nivel 0 ----------
A = """            my $spent = time() - $started;
            _log($scfg, 0, 'err', "[TrueNAS] Budget of ${budget}s spent after $attempt "
                . "attempt(s) for $operation_name: $last_error");
            die "Gave up on $operation_name after ${spent}s (budget ${budget}s, \""""
N = """            my $spent = time() - $started;
            # Name the budget that actually governed. $budget is the configured
            # knob, but an outer deadline (the 2s marker cap, cluster_lock's
            # window) may have shrunk the effective one - and "Budget of 120s
            # spent" after two real seconds sends the diagnosis the wrong way,
            # 18 lines for every 1 of the note that explains the cap.
            my $granted = $deadline - $started;
            my $bnote = ($granted + 0.5 < $budget)
                ? sprintf('%ss, capped to %.0fs by an outer deadline', $budget, $granted)
                : "${budget}s";
            _log($scfg, 0, 'err', "[TrueNAS] Budget of $bnote spent after $attempt "
                . "attempt(s) for $operation_name: $last_error");
            die "Gave up on $operation_name after ${spent}s (budget $bnote, \""""
src = rep(A, N, "presupuesto efectivo")

# ---------- E4: la suposicion "no hay bindings" queda escrita ----------
A = """    my $existing_bindings = eval {
        _api_call($scfg, 'nvmet.port_subsys.query', []);
    } // [];
"""
N = """    my $existing_bindings = eval {
        _api_call($scfg, 'nvmet.port_subsys.query', []);
    } // [];
    # "Could not ask" must not impersonate "no bindings". The empty default is
    # survivable (sync only creates, and duplicate creates are handled), but
    # the assumption has to be on the record - under the 2s marker cap this
    # query now fails routinely during outages instead of almost never.
    _log($scfg, 1, 'warning', "[TrueNAS] sync_portals: port_subsys.query failed, "
        . "assuming no existing bindings: $@") if $@;
"""
src = rep(A, N, "eval sync_portals")

# ---------- E5: D5 en forma corta ----------
A = """        if (defined(_api_recently_down($scfg))) {
            local $_api_deadline = _capped_api_deadline();
            eval { _nvme_connect($scfg, repair => 1) };
        } else {
            eval { _nvme_connect($scfg, repair => 1) };
        }
        _log($scfg, 2, 'debug', "[TrueNAS] status: path reconcile failed: $@") if $@;"""
N = """        # RHS evaluates before localization, so `local $x = $x` is a no-op
        # rebind - verified against this exact call shape in review.
        local $_api_deadline = defined(_api_recently_down($scfg))
            ? _capped_api_deadline() : $_api_deadline;
        eval { _nvme_connect($scfg, repair => 1) };
        _log($scfg, 2, 'debug', "[TrueNAS] status: path reconcile failed: $@") if $@;"""
src = rep(A, N, "D5 shrink")

open(out, "w", encoding="utf-8").write(src)
r = subprocess.run(["perl", "-c", out], capture_output=True, text=True)
tail = r.stderr.strip().splitlines()[-1] if r.stderr else "?"
print("perl -c:", tail)
sys.exit(0 if r.returncode == 0 else 1)
