#!/usr/bin/env bash
#
# tn-attr-model-fix.sh -- detect and repair NAS-140266 on a TrueNAS 25.10.x array.
#
# On a chassis whose DMI reports an empty system-product-name, the middleware
# wants to write attr_model='TrueNAS ' (trailing space) but reads the current
# value back stripped, so the two never compare equal. Every render therefore
# retries the write, the kernel refuses it once a host has discovered the
# subsystem, and the exception aborts the rest of the render -- namespaces and
# allowed_hosts never reach configfs. See the .patch alongside this script.
#
# Run this ON the array, as root:
#
#     ./tn-attr-model-fix.sh --check       what state is this box in
#     ./tn-attr-model-fix.sh --apply       patch it (idempotent, keeps a backup)
#     ./tn-attr-model-fix.sh --revert      restore the packaged file
#     ./tn-attr-model-fix.sh --self-test   prove --check can actually say AT RISK
#
# --check exit codes, so it can be wired into monitoring:
#     0  OK       patched, or this box does not have the condition
#     1  AT RISK  the condition is present and the patch is not
#     2  UNKNOWN  could not determine -- treat as at risk
#
# The patch edits a file owned by the TrueNAS package manager. A system update
# WILL silently revert it, which is exactly why --check exists: run it after
# every upgrade.

set -uo pipefail

# TN_ATTR_MODEL_TARGET exists so the AT RISK verdict can be exercised against a
# throwaway copy. Without it that branch would never run anywhere, which is the
# same as not having tested it. --apply and --revert refuse to use it.
TARGET="${TN_ATTR_MODEL_TARGET:-/usr/lib/python3/dist-packages/middlewared/plugins/nvmet/kernel.py}"
OLD_LINE="result['attr_model'] = render_ctx['nvmet.subsys.model']"
NEW_LINE="result['attr_model'] = render_ctx['nvmet.subsys.model'].strip()"

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; RST=$'\033[0m'
if [ ! -t 1 ]; then RED=; GRN=; YEL=; RST=; fi

ok()   { printf '%s  OK %s %s\n' "$GRN" "$RST" "$*"; }
bad()  { printf '%s FAIL%s %s\n' "$RED" "$RST" "$*"; }
warn() { printf '%s WARN%s %s\n' "$YEL" "$RST" "$*"; }
info() { printf '      %s\n' "$*"; }

need_root() {
    if [ "$(id -u)" -ne 0 ]; then
        bad "must run as root (the target lives on a read-only /usr)"
        exit 2
    fi
    if [ -n "${TN_ATTR_MODEL_TARGET:-}" ]; then
        bad "TN_ATTR_MODEL_TARGET is set -- that override is for --check only"
        info "refusing to write to a target chosen by an environment variable"
        exit 2
    fi
}

# Replace one exact literal line with another, without regex escaping.
# Prints the rewritten file on stdout.
swap_line() {
    awk -v from="$2" -v to="$3" '
        index($0, from) && !done { sub(/[^ \t].*/, ""); print $0 to; done = 1; next }
        { print }
    ' "$1"
}

has_trailing_space() {
    case "$1" in
        *[!\ \	]) return 1 ;;   # last char is not a space or tab
        "")          return 1 ;;
        *)           return 0 ;;
    esac
}

# ---------------------------------------------------------------- detection --

# Does this box build a model string with trailing whitespace? This is the
# condition itself, independent of whether the patch is installed.
# Prints the raw value on stdout. rc 0 = condition present, 1 = absent,
# 2 = could not measure.
probe_model() {
    local raw
    raw="$(midclt call nvmet.subsys.model 2>/dev/null)" || return 2
    [ -n "$raw" ] || return 2
    printf '%s' "$raw"
    has_trailing_space "$raw" && return 0
    return 1
}

# Is the patch present in a given file? Reads the file, not a stored hash, so a
# package update that rewrites the file around our line is still detected.
patch_present_in() {
    grep -qF -- "$NEW_LINE" "$1"
}

do_check() {
    local raw rc_condition patched=1 exit_rc=0 s

    if [ ! -r "$TARGET" ]; then
        bad "cannot read $TARGET"
        info "run as root, and check that this is a TrueNAS 25.10.x array"
        return 2
    fi

    patch_present_in "$TARGET" && patched=0

    raw="$(probe_model)"; rc_condition=$?
    if [ $rc_condition -eq 2 ]; then
        bad "could not ask the middleware for the model string (midclt failed)"
        info "refusing to report OK on a measurement that did not happen"
        return 2
    fi

    info "middleware model string: [${raw}]"
    if [ $patched -eq 0 ]; then
        info "patch in kernel.py:       present"
    else
        info "patch in kernel.py:       ABSENT"
    fi

    # What configfs is actually holding, for context. Not a verdict on its own:
    # the kernel refuses to change attr_model after discovery, so a stale value
    # here is expected and harmless once the patch is in.
    for s in /sys/kernel/config/nvmet/subsystems/*/; do
        [ -e "$s/attr_model" ] || continue
        info "configfs $(basename "$s" | sed 's/.*://'): [$(cat "$s/attr_model" 2>/dev/null)]"
    done

    if [ $rc_condition -eq 0 ]; then
        if [ $patched -eq 0 ]; then
            ok "condition present, patch applied -- renders will not retry the write"
        else
            bad "AT RISK: the model string has trailing whitespace and the patch is absent"
            info "every render will retry attr_model; the kernel refuses it once a host"
            info "has discovered the subsystem, and the render aborts before publishing"
            info "namespaces. New namespaces will land in the database and never appear"
            info "on the wire. Run --apply."
            exit_rc=1
        fi
    else
        if [ $patched -eq 0 ]; then
            ok "condition absent (model string is clean); patch present but harmless"
        else
            ok "condition absent -- this chassis reports a usable system-product-name"
        fi
    fi
    return $exit_rc
}

# ------------------------------------------------------------- positive ctl --

# The whole point of this script is a check that can fail. Prove it: build a
# copy of the target with the patch removed and require the detector to say so,
# then put it back and require the detector to agree.
do_self_test() {
    local tmp fails=0

    if [ ! -r "$TARGET" ]; then bad "cannot read $TARGET"; return 2; fi
    tmp="$(mktemp -d)" || { bad "mktemp failed"; return 2; }
    trap 'rm -rf "$tmp"' RETURN

    if patch_present_in "$TARGET"; then
        swap_line "$TARGET" "$NEW_LINE" "$OLD_LINE" > "$tmp/unpatched.py"
    else
        cp "$TARGET" "$tmp/unpatched.py"
    fi
    if grep -qF -- "$NEW_LINE" "$tmp/unpatched.py"; then
        bad "self-test setup failed: could not build an unpatched copy"
        return 2
    fi

    if patch_present_in "$tmp/unpatched.py"; then
        bad "detector said PRESENT on a file with the patch removed"; fails=$((fails+1))
    else
        ok  "detector reports ABSENT on an unpatched copy"
    fi

    swap_line "$tmp/unpatched.py" "$OLD_LINE" "$NEW_LINE" > "$tmp/patched.py"
    if patch_present_in "$tmp/patched.py"; then
        ok  "detector reports PRESENT on a patched copy"
    else
        bad "detector said ABSENT on a file that carries the patch"; fails=$((fails+1))
    fi

    # The whitespace test has to separate the broken value from a clean one.
    if has_trailing_space "TrueNAS "; then
        ok  "whitespace test flags 'TrueNAS ' (the broken value)"
    else
        bad "whitespace test did NOT flag 'TrueNAS '"; fails=$((fails+1))
    fi
    if has_trailing_space "TrueNAS-MINI-3.0-X"; then
        bad "whitespace test flagged a clean value"; fails=$((fails+1))
    else
        ok  "whitespace test passes a clean value"
    fi

    if [ $fails -eq 0 ]; then ok "self-test clean"; return 0; fi
    bad "$fails self-test failure(s) -- do not trust --check on this box"
    return 2
}

# ------------------------------------------------------------------ apply ----

USR_WAS_RO=0
restore_usr_ro() {
    if [ "$USR_WAS_RO" -eq 1 ]; then
        sync
        if mount -o remount,ro /usr 2>/dev/null; then
            info "/usr returned to ro"
        else
            warn "could not return /usr to ro -- do it by hand: mount -o remount,ro /usr"
        fi
    fi
}

usr_is_ro() {
    findmnt -no OPTIONS /usr 2>/dev/null | cut -d, -f1 | grep -qx ro
}

do_apply() {
    need_root
    [ -f "$TARGET" ] || { bad "$TARGET not found"; return 2; }

    if patch_present_in "$TARGET"; then
        ok "already patched -- nothing to do"
        return 0
    fi
    if ! grep -qF -- "$OLD_LINE" "$TARGET"; then
        bad "the line this patch replaces is not in $TARGET"
        info "this TrueNAS version is not the one the patch was written against."
        info "Re-read nvmet-attr-model-NAS-140266.patch before forcing anything."
        return 2
    fi

    local backup tmp before after
    backup="${TARGET}.orig-$(date +%Y%m%d)"
    tmp="$(mktemp)" || { bad "mktemp failed"; return 2; }

    # Build the patched file in /tmp first, so a failure never leaves a
    # half-written middleware plugin behind on the appliance.
    awk -v old="$OLD_LINE" -v new="$NEW_LINE" '
        index($0, old) && !done {
            match($0, /^[ \t]*/); indent = substr($0, 1, RLENGTH)
            print indent "# IDK: strip before comparing and writing -- NAS-140266. dmidecode"
            print indent "# reports an empty system-product-name on this chassis, so the model"
            print indent "# string carries a trailing space, configfs reads it back stripped,"
            print indent "# the comparison never matches, and the retried write aborts the"
            print indent "# whole render before namespaces reach the kernel."
            print indent new
            done = 1
            next
        }
        { print }
    ' "$TARGET" > "$tmp"

    if ! grep -qF -- "$NEW_LINE" "$tmp"; then
        bad "the rewrite did not produce the patched line"; rm -f "$tmp"; return 2
    fi
    # Exactly one line replaced by six. Nothing else may have moved.
    before="$(wc -l < "$TARGET")"; after="$(wc -l < "$tmp")"
    if [ "$after" -ne "$((before + 5))" ]; then
        bad "unexpected line-count change ($before -> $after) -- refusing to install"
        rm -f "$tmp"; return 2
    fi
    # It has to be valid Python before it goes anywhere near /usr. stdin comes
    # from /dev/null: a password prompt upstream of us must never be able to
    # feed this interpreter (that exact collapse cost us a run once already).
    if ! python3 -m py_compile "$tmp" < /dev/null; then
        bad "the patched file does not compile -- refusing to install"; rm -f "$tmp"; return 2
    fi
    ok "patched file compiles"

    if usr_is_ro; then
        USR_WAS_RO=1
        trap restore_usr_ro EXIT
        if ! mount -o remount,rw /usr; then
            bad "could not remount /usr rw"; rm -f "$tmp"; return 2
        fi
        info "/usr remounted rw"
    fi

    # Keep the first backup we ever take. Running --apply twice must not
    # overwrite the pristine original with an already-patched copy.
    if [ -e "$backup" ]; then
        info "backup already exists, keeping it: $backup"
    else
        if ! cp -a "$TARGET" "$backup"; then
            bad "backup failed -- not touching the original"; rm -f "$tmp"; return 2
        fi
        ok "backup: $backup"
    fi

    if ! cat "$tmp" > "$TARGET"; then
        bad "write failed"; rm -f "$tmp"; return 2
    fi
    rm -f "$tmp"
    ok "patch installed"

    restore_usr_ro; trap - EXIT; USR_WAS_RO=0

    warn "restart the middleware for this to take effect:  systemctl restart middlewared"
    warn "that briefly interrupts the API and the web UI. It does NOT touch running"
    warn "NVMe-oF sessions: configfs and the kernel target are left alone by it."
    return 0
}

do_revert() {
    need_root
    local backup
    backup="$(ls -1t "${TARGET}".orig-* 2>/dev/null | head -1)"
    [ -n "$backup" ] || { bad "no backup found next to $TARGET"; return 2; }
    if patch_present_in "$backup"; then
        bad "$backup already carries the patch -- it is not a pristine original"
        return 2
    fi

    if usr_is_ro; then
        USR_WAS_RO=1
        trap restore_usr_ro EXIT
        if ! mount -o remount,rw /usr; then bad "could not remount /usr rw"; return 2; fi
    fi
    if ! cp -a "$backup" "$TARGET"; then bad "restore failed"; return 2; fi
    ok "restored from $backup"
    restore_usr_ro; trap - EXIT; USR_WAS_RO=0
    warn "systemctl restart middlewared to make it take effect"
    warn "this box will go back to failing renders if it has the condition"
    return 0
}

case "${1:---check}" in
    --check)     do_check ;;
    --apply)     do_apply ;;
    --revert)    do_revert ;;
    --self-test) do_self_test ;;
    -h|--help)   sed -n '2,26p' "$0" | sed 's/^#\{0,1\} \{0,1\}//' ;;
    *)           bad "unknown option: $1"; exit 2 ;;
esac
