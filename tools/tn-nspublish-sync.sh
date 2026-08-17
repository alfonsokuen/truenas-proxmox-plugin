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
# SAFETY: it will only ever touch ONE subsystem, named on the command line, and
# it refuses any NQN it was not given. The production subsystem is one typo away
# otherwise, and a namespace removed from under a live initiator is an outage.
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

# The one subsystem that must never be touched by a tool like this.
case "$NQN" in
    *:VM) echo "refusing: $NQN is the production subsystem" >&2; exit 2 ;;
esac

SUBDIR="/sys/kernel/config/nvmet/subsystems/$NQN"
[ -d "$SUBDIR" ] || { echo "refusing: no such subsystem in configfs: $NQN" >&2; exit 2; }

log() { echo "[$(date +%H:%M:%S)] $*"; }

sync_once() {
    local want_ids=() nsid dev uuid nguid path created=0 removed=0

    # What the database thinks exists, for this subsystem only.
    local rows
    rows="$(midclt call nvmet.namespace.query 2>/dev/null | python3 -c "
import sys, json
nqn = ${NQN@Q}
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
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
" 2>/dev/null)"

    while IFS=$'\t' read -r nsid dev uuid nguid; do
        [ -n "$nsid" ] || continue
        want_ids+=("$nsid")
        path="$SUBDIR/namespaces/$nsid"
        [ -d "$path" ] && continue
        if [ ! -e "$dev" ]; then
            log "ns $nsid: el dispositivo $dev no existe todavia, se reintenta"
            continue
        fi
        mkdir -p "$path" 2>/dev/null || { log "ns $nsid: no se pudo crear"; continue; }
        printf '%s' "$dev" > "$path/device_path" 2>/dev/null
        # The identifiers are only writable while disabled, and the plugin finds
        # its volumes through /dev/disk/by-id/nvme-uuid.<uuid>, so getting the
        # uuid right is what makes the device findable rather than merely present.
        printf '0' > "$path/enable" 2>/dev/null
        [ -n "$uuid" ]  && printf '%s' "$uuid"  > "$path/device_uuid"  2>/dev/null
        [ -n "$nguid" ] && printf '%s' "$nguid" > "$path/device_nguid" 2>/dev/null
        if printf '1' > "$path/enable" 2>/dev/null; then
            log "ns $nsid publicado -> $dev (uuid ${uuid:0:8})"
            created=$(( created + 1 ))
        else
            log "ns $nsid: no se pudo habilitar"
            rmdir "$path" 2>/dev/null
        fi
    done <<< "$rows"

    # And retire the ones the database no longer has, so a freed volume stops
    # being exported. Only within this subsystem, and only entries this tool
    # could have created.
    local d id keep
    for d in "$SUBDIR"/namespaces/*/; do
        [ -d "$d" ] || continue
        id="$(basename "$d")"
        keep=0
        for nsid in ${want_ids[@]+"${want_ids[@]}"}; do
            [ "$nsid" = "$id" ] && keep=1 && break
        done
        [ "$keep" = 1 ] && continue
        printf '0' > "$d/enable" 2>/dev/null
        if rmdir "$d" 2>/dev/null; then
            log "ns $id retirado (ya no esta en la base de datos)"
            removed=$(( removed + 1 ))
        fi
    done

    [ "$created" != 0 ] || [ "$removed" != 0 ]
}

if [ "$MODE" = once ]; then
    sync_once
    echo "namespaces en el kernel para este subsistema: $(ls -1 "$SUBDIR/namespaces" 2>/dev/null | wc -l)"
    exit 0
fi

log "vigilando $NQN cada ${INTERVAL}s (Ctrl-C para parar)"
while :; do
    # Once per tick. Calling it twice to filter the output would make the second
    # call find nothing left to do and report an idle loop as the truth.
    sync_once 2>/dev/null || true
    sleep "$INTERVAL"
done
