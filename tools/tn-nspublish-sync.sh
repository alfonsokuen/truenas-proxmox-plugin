#!/bin/bash
# Publish into the kernel the namespaces TrueNAS only wrote to its database.
#
# On TrueNAS SCALE 25.10.4, nvmet.namespace.create records a namespace and never
# writes it into /sys/kernel/config/nvmet. The API reports it enabled with the
# right device path, and the host never sees a block device. Restarting the
# nvmet service would re-render configfs from the database, but that drops every
# initiator on the box - including the subsystem serving all the VM storage -
# so it is not something to do for a pilot.
#
# Writing the entry by hand publishes it instantly: the initiator gets an AEN
# and the device appears without even a rescan. This does that on a loop, so a
# storage plugin creating volumes through the API gets working devices.
#
# It is a workaround for an evaluation, not a fix. Nothing here belongs in
# production: the real repair is in TrueNAS middleware.
#
# SAFETY. This runs as root on the box that serves every VM in the company, and
# a namespace removed from under a live initiator is an outage. Three rules,
# because the first two of them were not enough:
#
#   1. The subsystem is chosen by a whitelist on the CANONICAL path, not by a
#      denylist on the string. A trailing slash - which is exactly what tab
#      completion over the subsystems directory produces - made the old
#      "refuse anything ending in :VM" test miss, while [ -d ] still matched.
#   2. A failed query is not an empty database. If midclt or the JSON parse
#      fails, or the schema no longer looks like what we parse, this touches
#      nothing at all. The retirement loop used to read a transient middleware
#      hiccup as "the database has no namespaces" and unexport all of them.
#   3. An entry already in configfs is never silently trusted or rewritten. If
#      it disagrees with the database it is reported and left alone: rewriting
#      it would disconnect a live initiator, and trusting it lets a recycled
#      nsid keep serving the previous volume's zvol under the new name.
#
#   tn-nspublish-sync.sh <subsystem-nqn> [--watch [seconds]] [--once]

set -uo pipefail

NQN="${1:-}"
shift || true
MODE=once
INTERVAL=2
while [ $# -gt 0 ]; do
    case "$1" in
        --watch) MODE=watch; case "${2:-}" in [0-9]*) INTERVAL="$2"; shift ;; esac; shift ;;
        --once)  MODE=once; shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

[ -n "$NQN" ] || { echo "usage: $0 <subsystem-nqn> [--watch [seconds]]" >&2; exit 2; }
[ "$(id -u)" = 0 ] || { echo "must run as root" >&2; exit 2; }

refuse() { echo "refusing: $*" >&2; exit 2; }

ROOT=/sys/kernel/config/nvmet/subsystems

# A subsystem name is a name, not a path. Anything that could traverse or that
# carries whitespace is rejected before it is ever used to build a path.
case "$NQN" in
    */*)            refuse "the NQN contains '/': $NQN" ;;
    .|..)           refuse "not a subsystem name: $NQN" ;;
    *[[:space:]]*)  refuse "the NQN contains whitespace: $NQN" ;;
    *[![:print:]]*) refuse "the NQN contains control characters" ;;
esac

SUBDIR="$ROOT/$NQN"
[ -d "$SUBDIR" ] || refuse "no such subsystem in configfs: $NQN"

# Resolve it and check what we actually landed on, so no symlink or oddity can
# move the target out from under the name that was checked.
REAL="$(readlink -f "$SUBDIR" 2>/dev/null)" || refuse "cannot resolve $SUBDIR"
[ "$(dirname "$REAL")" = "$ROOT" ] || refuse "resolves outside $ROOT: $REAL"
BASE="$(basename "$REAL")"
[ "$BASE" = "$NQN" ] || refuse "resolves to a different subsystem: $BASE"

# Whitelist: the name has to say out loud that it is not production.
case "$BASE" in
    *pilot*|*lab*|*test*) ;;
    *) refuse "only subsystems named pilot/lab/test, got: $BASE" ;;
esac
# Denylist on top, case-insensitive, in case something is named "VM-lab".
case "$(printf '%s' "$BASE" | tr 'A-Z' 'a-z')" in
    *:vm|*:vms|*:vm-*|*:vm_*) refuse "$BASE looks like the production subsystem" ;;
esac

SUBDIR="$REAL"
log() { echo "[$(date +%H:%M:%S)] $*"; }

WARNED_MISMATCH=""

sync_once() {
    local want_ids=() nsid dev uuid nguid path created=0 removed=0
    local rows rc tmp

    tmp="$(mktemp)" || { log "no se pudo crear temporal"; return 1; }

    # A failed query must never look like an empty database, because the
    # retirement loop below would then unexport everything.
    if ! midclt call nvmet.namespace.query > "$tmp" 2>/dev/null; then
        log "midclt fallo: no se toca nada en este tick"
        rm -f "$tmp"; return 1
    fi

    rows="$(python3 -c "
import sys, json
nqn = ${NQN@Q}
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(3)                      # unparseable is a failure, not an empty list
if not isinstance(data, list):
    sys.exit(3)
# If the middleware ever renames the relation we parse, every row would silently
# stop matching and the caller would retire live namespaces. Refuse instead.
if data and not any(isinstance(n.get('subsys'), dict) for n in data):
    sys.exit(4)
for n in data:
    s = n.get('subsys') or {}
    if s.get('subnqn') != nqn:
        continue
    if not n.get('enabled'):
        continue
    p = n.get('device_path') or ''
    if not p.startswith('/'):
        p = '/dev/' + p          # the API stores zvol/..., configfs wants /dev/zvol/...
    print('%s\t%s\t%s\t%s' % (n.get('nsid'), p, n.get('device_uuid') or '', n.get('device_nguid') or ''))
" < "$tmp")"
    rc=$?
    rm -f "$tmp"
    case "$rc" in
        0) ;;
        3) log "la respuesta no se pudo interpretar: no se toca nada"; return 1 ;;
        4) log "el esquema de nvmet.namespace cambio: no se toca nada"; return 1 ;;
        *) log "la consulta fallo (rc=$rc): no se toca nada"; return 1 ;;
    esac

    while IFS=$'\t' read -r nsid dev uuid nguid; do
        [ -n "$nsid" ] || continue
        want_ids+=("$nsid")
        path="$SUBDIR/namespaces/$nsid"

        # An entry that is already there is never assumed to be the right one.
        # NSIDs get recycled: free a volume, create another, and the middleware
        # can hand the new one the number the old one had. Skipping it blindly
        # leaves the kernel exporting the previous zvol under the new name.
        if [ -d "$path" ]; then
            local cur_dev cur_uuid
            cur_dev="$(cat "$path/device_path" 2>/dev/null)"
            cur_uuid="$(cat "$path/device_uuid" 2>/dev/null)"
            if [ "$cur_dev" = "$dev" ] && { [ -z "$uuid" ] || [ "$cur_uuid" = "$uuid" ]; }; then
                continue
            fi
            # Rewriting it would yank the device from a live initiator, so this
            # reports and stops. A human decides.
            case "$WARNED_MISMATCH" in
                *" $nsid "*) ;;
                *) log "ns $nsid: DESAJUSTE kernel($cur_dev / ${cur_uuid:0:8}) vs base($dev / ${uuid:0:8}) - NO se toca, revisar a mano"
                   WARNED_MISMATCH="$WARNED_MISMATCH $nsid " ;;
            esac
            continue
        fi

        if [ ! -e "$dev" ]; then
            log "ns $nsid: el dispositivo $dev no existe todavia, se reintenta"
            continue
        fi
        mkdir -p "$path" 2>/dev/null || { log "ns $nsid: no se pudo crear"; continue; }
        if ! printf '%s' "$dev" > "$path/device_path" 2>/dev/null; then
            log "ns $nsid: no se pudo fijar device_path"; rmdir "$path" 2>/dev/null; continue
        fi
        # The identifiers are only writable while disabled, and the plugin finds
        # its volumes through /dev/disk/by-id/nvme-uuid.<uuid>. A namespace
        # enabled with the wrong uuid is worse than one that never appeared:
        # it is present, findable under someone else's name, and writable.
        printf '0' > "$path/enable" 2>/dev/null
        if [ -n "$uuid" ] && ! printf '%s' "$uuid" > "$path/device_uuid" 2>/dev/null; then
            log "ns $nsid: no se pudo fijar device_uuid, NO se habilita"
            rmdir "$path" 2>/dev/null; continue
        fi
        if [ -n "$nguid" ] && ! printf '%s' "$nguid" > "$path/device_nguid" 2>/dev/null; then
            log "ns $nsid: no se pudo fijar device_nguid, NO se habilita"
            rmdir "$path" 2>/dev/null; continue
        fi
        if printf '1' > "$path/enable" 2>/dev/null; then
            log "ns $nsid publicado -> $dev (uuid ${uuid:0:8})"
            created=$(( created + 1 ))
        else
            log "ns $nsid: no se pudo habilitar"
            rmdir "$path" 2>/dev/null
        fi
    done <<< "$rows"

    # And retire the ones the database no longer has, so a freed volume stops
    # being exported. Only within this subsystem, and only after a query that
    # actually succeeded - which is what every early return above protects.
    local d id keep
    for d in "$SUBDIR"/namespaces/*/; do
        [ -d "$d" ] || continue
        id="$(basename "$d")"
        keep=0
        for nsid in ${want_ids[@]+"${want_ids[@]}"}; do
            [ "$nsid" = "$id" ] && keep=1 && break
        done
        [ "$keep" = 1 ] && continue
        log "ns $id: ya no esta en la base de datos, retirando"
        printf '0' > "$d/enable" 2>/dev/null
        if rmdir "$d" 2>/dev/null; then
            log "ns $id retirado"
            removed=$(( removed + 1 ))
        else
            # Leaving it disabled-but-present would be invisible and permanent:
            # the publish loop above would see the directory and never re-enable
            # it, and the initiator would have lost the device for good.
            log "ns $id: rmdir fallo (ocupado?), se vuelve a habilitar"
            printf '1' > "$d/enable" 2>/dev/null
        fi
    done

    [ "$created" != 0 ] || [ "$removed" != 0 ]
}

if [ "$MODE" = once ]; then
    sync_once
    echo "namespaces en el kernel para este subsistema: $(ls -1 "$SUBDIR/namespaces" 2>/dev/null | wc -l)"
    exit 0
fi

log "vigilando $BASE cada ${INTERVAL}s (Ctrl-C para parar)"
while :; do
    # Once per tick. Calling it twice to filter the output would make the second
    # call find nothing left to do and report an idle loop as the truth.
    sync_once || true
    sleep "$INTERVAL"
done
