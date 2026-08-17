#!/bin/bash
# Snapshot a guest that is running and writing, then roll it back.
#
# Every other test here wrote to a stopped VM's disk from the hypervisor. That
# is a different code path from the one production uses: a live snapshot has to
# freeze a disk that a guest is actively writing to, and with --vmstate it also
# has to capture and restore RAM. A stopped-VM snapshot passing says nothing
# about either.
#
# Two things are checked after the rollback, and both matter:
#
#   the disk   the guest must read back the pattern as it was at snapshot time,
#              not the one written afterwards
#   the RAM    a file created in tmpfs BEFORE the snapshot must still be there,
#              and one created AFTER it must be gone. Disk rollback alone would
#              satisfy the first and fail the second, so testing both is what
#              separates "the volume was restored" from "the VM was restored".
#
# The guest is driven over its serial console - no network, no guest agent. The
# verifier inside the guest is the same file the host uses, so both sides
# regenerate identical bytes from (seed, offset).
#
#   i32-livevm-test.sh <vmid>

set -uo pipefail

VMID="${1:-}"
[ -n "$VMID" ] || { echo "usage: $0 <vmid>" >&2; exit 2; }
case "$VMID" in
    999[0-9]) ;;
    *) echo "refusing: VMID $VMID is outside the scratch range" >&2; exit 2 ;;
esac

D=/root/i32/live
FIFO="$D/cmd.fifo"
LOG="$D/serial.log"
SOCK="/var/run/qemu-server/${VMID}.serial0"
SEED_A=$(( VMID * 100 + 11 ))
SEED_B=$(( VMID * 100 + 22 ))
PAT_MIB=1024
SUB_MIB=256

FAILURES=0
SUMMARY=()
say()  { echo ""; echo "=== $* ==="; }
note() { echo "    $*"; }
pass() { SUMMARY+=("PASS  $*"); note "PASS  $*"; }
fail() { SUMMARY+=("FALLO $*"); note "FALLO $*"; FAILURES=$(( FAILURES + 1 )); }
skip() { SUMMARY+=("--    $*"); note "--    $*"; }

# Stripping the ESC byte alone is not enough and is worse than doing nothing:
# it leaves the rest of the sequence behind as ordinary printable text, so a
# bracketed-paste marker turns into a literal "[?2004l" glued to whatever the
# command printed. Read a device name out of that and you get /dev/[?2004lsdb,
# which fails to open and looks exactly like a storage fault. The sequences have
# to go as sequences, before anything else touches the stream.
clean() {
    sed -E $'s/\x1b\\][^\x07]*\x07//g; s/\x1b\\[[0-9;?]*[a-zA-Z]//g; s/\x1b[()][A-Za-z0-9]//g' \
        | tr -d '\r' | tr -cd '\11\12\40-\176'
}

# ---------------------------------------------------------------------------
# the control channel
# ---------------------------------------------------------------------------

serial_up() { pgrep -f "socat.*${VMID}.serial0" >/dev/null 2>&1; }

attach() {
    rm -f "$FIFO" "$LOG"
    mkdir -p "$D"
    mkfifo "$FIFO"
    nohup bash -c "sleep 7200 > $FIFO" >/dev/null 2>&1 &
    sleep 0.5
    nohup socat "UNIX-CONNECT:$SOCK" - < "$FIFO" > "$LOG" 2>&1 &
    sleep 2
    serial_up
}

detach() {
    pkill -f "socat.*${VMID}.serial0" >/dev/null 2>&1
    pkill -f "sleep 7200" >/dev/null 2>&1
    rm -f "$FIFO"
}

SEQ=0
GOUT=""

# Run a command in the guest and wait for it to finish.
#
# The console is a stream with no framing, so the end of a command's output has
# to be marked explicitly - otherwise "no output yet" and "finished with no
# output" look the same and every read becomes a guess about timing.
#
# The console echoes back everything typed at it, so the sentinel arrives twice:
# once in the echo of the command, before it has run, and once in its output.
# Matching the first one reports the command finished the instant it was sent,
# with no output and no exit status. Two things stop that: the marker is written
# split so the echoed line never contains it contiguously, and the match
# requires a digit after rc= - the echo carries a literal $? instead.
gexec() {
    local cmd="$1" timeout="${2:-30}" mark i
    SEQ=$(( SEQ + 1 ))
    mark="I32DONE${SEQ}X"
    : > "$LOG"
    printf '%s\n' "$cmd; echo \"I32\"\"DONE${SEQ}Xrc=\$?\"" > "$FIFO"
    for ((i = 0; i < timeout * 2; i++)); do
        if grep -aqE "${mark}rc=[0-9]" "$LOG" 2>/dev/null; then
            # Drop the echoed command line, then everything from the real
            # sentinel onward, leaving just what the command printed.
            GOUT="$(clean < "$LOG" | sed "0,/DONE${SEQ}Xrc=/d" | sed "/${mark}rc=[0-9]/,\$d")"
            GRC="$(clean < "$LOG" | sed -n "s/.*${mark}rc=\([0-9][0-9]*\).*/\1/p" | head -1)"
            return 0
        fi
        sleep 0.5
    done
    GOUT="$(clean < "$LOG")"
    GRC=""
    return 1
}

# Wait for the guest to answer at all - used after a rollback, when the VM is
# restarted and the console comes back from nothing.
gwait() {
    local timeout="${1:-120}" i
    for ((i = 0; i < timeout; i++)); do
        if gexec 'true' 3 && [ "${GRC:-}" = 0 ]; then
            return 0
        fi
        sleep 1
    done
    return 1
}

# ---------------------------------------------------------------------------
# preflight
# ---------------------------------------------------------------------------

say "preflight"
note "vmid      : $VMID"
note "semillas  : A=$SEED_A  B=$SEED_B"
note "patron    : ${PAT_MIB} MiB, region reescrita ${SUB_MIB} MiB"

if ! qm status "$VMID" 2>/dev/null | grep -q running; then
    echo "refusing: VM $VMID is not running" >&2
    exit 2
fi
[ -S "$SOCK" ] || { echo "refusing: no serial socket at $SOCK" >&2; exit 2; }

serial_up || attach
serial_up || { echo "refusing: cannot attach to the serial console" >&2; exit 2; }
note "consola serie enganchada"

if ! gexec 'echo vivo' 20 || [ "${GRC:-}" != 0 ]; then
    echo "refusing: the guest does not answer on the console" >&2
    exit 2
fi
note "el invitado responde"

# Stop bash emitting bracketed-paste markers in the first place. The stream is
# also sanitised on the way out, but not generating the noise is cheaper than
# filtering it, and leaves the log readable.
gexec "bind 'set enable-bracketed-paste off' 2>/dev/null; true" 10

# The guest resolves its disks by serial, so ask it rather than guessing a name
# that changes with boot order.
gexec '. /usr/local/bin/i32-paths.sh; basename "$I32BLK"' 10
DATA="$(echo "$GOUT" | tr -d ' \t' | grep -E '^[a-z]+[0-9]*$' | tail -1)"
# A device name that came back with anything else glued to it would fail every
# open, and every one of those failures would read as a storage fault. Better to
# refuse here than to spend a run blaming the disk.
if [ -z "$DATA" ]; then
    echo "refusing: the guest did not report a usable data disk name" >&2
    echo "salida cruda: $GOUT" >&2
    exit 2
fi
gexec "test -b /dev/$DATA" 10
if [ "${GRC:-}" != 0 ]; then
    echo "refusing: /dev/$DATA is not a block device inside the guest" >&2
    exit 2
fi
note "disco de datos en el invitado: /dev/$DATA"

# ---------------------------------------------------------------------------
# V1 - the guest reads back what it wrote
# ---------------------------------------------------------------------------

say "V1 - el invitado relee su propio patron"
gexec "/root/i32-blockverify.pl verify /dev/$DATA $(( PAT_MIB * 1024 * 1024 )) $SEED_A" 300
echo "$GOUT" | tail -3 | sed 's/^/      /'
if [ "${GRC:-}" = 0 ]; then
    pass "V1: ${PAT_MIB} MiB escritos y releidos por el invitado, byte a byte"
else
    fail "V1: el invitado no relee su propio patron (rc=${GRC:-?})"
fi

# ---------------------------------------------------------------------------
# V2 - live snapshot while the guest is writing
# ---------------------------------------------------------------------------

say "V2 - snapshot en caliente con la VM escribiendo"

gexec 'pgrep -f i32-guest-load >/dev/null && echo CARGA-ACTIVA || echo CARGA-PARADA' 15
if echo "$GOUT" | grep -q CARGA-ACTIVA; then
    pass "V2: el invitado esta escribiendo cuando se toma el snapshot"
else
    gexec 'nohup /usr/local/bin/i32-guest-load.sh >/dev/null 2>&1 & sleep 2; pgrep -f i32-guest-load >/dev/null && echo CARGA-ACTIVA' 20
    if echo "$GOUT" | grep -q CARGA-ACTIVA; then
        pass "V2: carga de escritura reiniciada en el invitado"
    else
        fail "V2: no hay carga de escritura, el snapshot seria sobre un disco quieto"
    fi
fi

# Markers in tmpfs, which only survives if RAM is restored.
TOKEN="antes-$VMID-$$"
gexec "echo $TOKEN > /run/i32-marca-antes; sync; cat /run/i32-marca-antes" 15
if echo "$GOUT" | grep -q "$TOKEN"; then
    pass "V2: marca en RAM escrita antes del snapshot"
else
    fail "V2: no se pudo escribir la marca en RAM"
fi

note "tomando qm snapshot --vmstate con la VM corriendo..."
t0=$(date +%s)
if qm snapshot "$VMID" viva --vmstate 1 --description "i32 live" >/tmp/i32-livesnap.log 2>&1; then
    pass "V2: qm snapshot --vmstate completado en $(( $(date +%s) - t0 ))s sin parar la VM"
else
    fail "V2: qm snapshot --vmstate fallo"
    tail -5 /tmp/i32-livesnap.log | sed 's/^/      /'
fi

if qm status "$VMID" 2>/dev/null | grep -q running; then
    pass "V2: la VM sigue corriendo despues del snapshot"
else
    fail "V2: la VM NO sigue corriendo despues del snapshot"
fi

gexec 'echo sigo-viva' 30
if [ "${GRC:-}" = 0 ]; then
    pass "V2: el invitado sigue respondiendo despues del snapshot"
else
    fail "V2: el invitado dejo de responder tras el snapshot"
fi

# ---------------------------------------------------------------------------
# V3 - change everything after the snapshot
# ---------------------------------------------------------------------------

say "V3 - cambiar disco y RAM despues del snapshot"

# The exit status of "cmd; sync" is sync's, not cmd's, so a failed write would
# be reported as a successful one. The status has to be carried past the flush.
gexec "/root/i32-blockverify.pl write /dev/$DATA $(( SUB_MIB * 1024 * 1024 )) $SEED_B; R=\$?; sync; (exit \$R)" 300
if [ "${GRC:-}" = 0 ]; then
    pass "V3: el invitado sobrescribe ${SUB_MIB} MiB con la semilla $SEED_B"
else
    fail "V3: la sobrescritura desde el invitado fallo"
fi

gexec "/root/i32-blockverify.pl verify /dev/$DATA $(( SUB_MIB * 1024 * 1024 )) $SEED_B" 300
if [ "${GRC:-}" = 0 ]; then
    pass "V3: y lo relee, asi que el cambio es real"
else
    fail "V3: el invitado no relee lo que acaba de escribir"
fi

TOKEN2="despues-$VMID-$$"
gexec "echo $TOKEN2 > /run/i32-marca-despues; sync; ls /run/i32-marca-despues" 15
if [ "${GRC:-}" = 0 ]; then
    pass "V3: marca en RAM escrita despues del snapshot"
else
    fail "V3: no se pudo escribir la marca posterior"
fi

# ---------------------------------------------------------------------------
# V4 - roll back and see whether the VM came back, not just the volume
# ---------------------------------------------------------------------------

say "V4 - rollback en vivo"

note "haciendo qm rollback (la VM se reinicia desde el estado guardado)..."
t0=$(date +%s)
if qm rollback "$VMID" viva --start 1 >/tmp/i32-liveroll.log 2>&1; then
    pass "V4: qm rollback completado en $(( $(date +%s) - t0 ))s"
else
    fail "V4: qm rollback fallo"
    tail -5 /tmp/i32-liveroll.log | sed 's/^/      /'
fi

# The console socket dies with the old qemu process, so it has to be re-attached
# against the new one before anything can be asked of the guest.
detach
sleep 3
for i in 1 2 3 4 5 6 7 8 9 10; do
    [ -S "$SOCK" ] && break
    sleep 2
done
if attach && gwait 180; then
    pass "V4: el invitado vuelve a responder tras el rollback"
else
    fail "V4: el invitado no responde tras el rollback - no se puede comprobar nada mas"
    say "resumen"
    for line in "${SUMMARY[@]}"; do echo "  $line"; done
    exit "$FAILURES"
fi

gexec 'uptime -p; cat /proc/uptime | cut -d" " -f1' 20
note "uptime tras el rollback: $(echo "$GOUT" | tail -2 | tr '\n' ' ')"

say "V4a - el disco"
gexec "/root/i32-blockverify.pl verify /dev/$DATA $(( PAT_MIB * 1024 * 1024 )) $SEED_A" 300
echo "$GOUT" | tail -3 | sed 's/^/      /'
if [ "${GRC:-}" = 0 ]; then
    pass "V4a: el disco vuelve entero al patron del momento del snapshot"
else
    fail "V4a: el disco NO volvio al estado del snapshot"
fi

say "V4b - la RAM"
gexec 'cat /run/i32-marca-antes 2>/dev/null || echo AUSENTE' 15
if echo "$GOUT" | grep -q "$TOKEN"; then
    pass "V4b: la marca anterior al snapshot sigue en RAM - el estado se restauro"
else
    fail "V4b: la marca anterior al snapshot no esta - la RAM no se restauro"
fi

gexec 'test -e /run/i32-marca-despues && echo PRESENTE || echo AUSENTE' 15
if echo "$GOUT" | grep -q AUSENTE; then
    pass "V4b: la marca posterior al snapshot desaparecio, como debe"
else
    fail "V4b: la marca posterior al snapshot SIGUE ahi - no se restauro el estado guardado"
fi

# ---------------------------------------------------------------------------
# V5 - delete the snapshot with the VM still running
# ---------------------------------------------------------------------------

say "V5 - borrar el snapshot en caliente"
if qm delsnapshot "$VMID" viva >/tmp/i32-livedel.log 2>&1; then
    pass "V5: qm delsnapshot con la VM corriendo"
else
    fail "V5: qm delsnapshot fallo"
    tail -5 /tmp/i32-livedel.log | sed 's/^/      /'
fi

gexec "/root/i32-blockverify.pl verify /dev/$DATA $(( PAT_MIB * 1024 * 1024 )) $SEED_A" 300
if [ "${GRC:-}" = 0 ]; then
    pass "V5: los datos sobreviven al borrado del snapshot"
else
    fail "V5: borrar el snapshot daño los datos"
fi

if qm status "$VMID" 2>/dev/null | grep -q running; then
    pass "V5: la VM sigue corriendo al final"
else
    fail "V5: la VM no sobrevivio al borrado del snapshot"
fi

# ---------------------------------------------------------------------------

say "resumen"
SKIPPED=0
i=0
while [ "$i" -lt "${#SUMMARY[@]}" ]; do
    case "${SUMMARY[$i]}" in "--"*) SKIPPED=$(( SKIPPED + 1 )) ;; esac
    echo "  ${SUMMARY[$i]}"
    i=$(( i + 1 ))
done
echo ""
if [ "$FAILURES" = 0 ]; then
    echo "  Con la VM corriendo y escribiendo: el snapshot en caliente, el rollback"
    echo "  y el borrado conservan tanto el disco como el estado en memoria."
else
    echo "  $FAILURES comprobacion(es) fallidas - arriba esta cual."
fi
[ "$SKIPPED" != 0 ] && echo "  Ademas $SKIPPED comprobacion(es) no llegaron a ejecutarse."

if [ "$FAILURES" != 0 ]; then
    exit "$FAILURES"
elif [ "$SKIPPED" != 0 ]; then
    exit 77
fi
exit 0
