#!/bin/bash
# Drive a guest over its serial console, from the hypervisor, with no network
# and no guest agent.
#
# Sourced by the live-VM harnesses. It lives in its own file because the two
# traps below are subtle enough that two copies would drift, and both of them
# produce failures that look exactly like storage faults.
#
# Requires: I32_VMID set by the caller. Provides: attach, detach, gexec, gwait,
# and the variables GOUT (what the command printed) and GRC (its exit status).

I32_DIR="${I32_DIR:-/root/i32/live}"
I32_FIFO="$I32_DIR/cmd.fifo"
I32_LOG="$I32_DIR/serial.log"
I32_SOCK=""
I32_SEQ=0
GOUT=""
GRC=""

con_sock() { echo "/var/run/qemu-server/${I32_VMID}.serial0"; }

# TRAP 1 of 2: stripping the ESC byte on its own is worse than not filtering at
# all. tr -cd removes \x1b and leaves the rest of the sequence behind as
# ordinary printable text, so a device name read out of the output becomes
# /dev/[?2004lsdb - which fails to open and reads as a storage fault. The
# sequences have to go as sequences, before anything else touches the stream.
con_clean() {
    sed -E $'s/\x1b\\][^\x07]*\x07//g; s/\x1b\\[[0-9;?]*[a-zA-Z]//g; s/\x1b[()][A-Za-z0-9]//g' \
        | tr -d '\r' | tr -cd '\11\12\40-\176'
}

con_up() { pgrep -f "socat.*${I32_VMID}.serial0" >/dev/null 2>&1; }

attach() {
    I32_SOCK="$(con_sock)"
    [ -S "$I32_SOCK" ] || return 1
    detach
    mkdir -p "$I32_DIR"
    rm -f "$I32_FIFO" "$I32_LOG"
    mkfifo "$I32_FIFO" || return 1
    # A holder keeps the fifo open, or socat sees EOF after the first write.
    nohup bash -c "sleep 7200 > $I32_FIFO" >/dev/null 2>&1 &
    sleep 0.5
    nohup socat "UNIX-CONNECT:$I32_SOCK" - < "$I32_FIFO" > "$I32_LOG" 2>&1 &
    sleep 2
    con_up
}

detach() {
    pkill -f "socat.*${I32_VMID}.serial0" >/dev/null 2>&1
    pkill -f "sleep 7200 > $I32_FIFO" >/dev/null 2>&1
    rm -f "$I32_FIFO"
    return 0
}

# TRAP 2 of 2: the console echoes back whatever is typed at it, so the sentinel
# marking the end of a command arrives twice - once in the echo, before the
# command has run, and once in its output. Matching the echo reports every
# command as finished the instant it was sent, with no output and no exit
# status. Two things prevent it: the marker is emitted split, so the echoed
# line never contains it contiguously, and the match demands a digit after
# rc= - the echo carries a literal $? there instead.
gexec() {
    local cmd="$1" timeout="${2:-30}" mark i
    I32_SEQ=$(( I32_SEQ + 1 ))
    mark="I32DONE${I32_SEQ}X"
    : > "$I32_LOG"
    printf '%s\n' "$cmd; echo \"I32\"\"DONE${I32_SEQ}Xrc=\$?\"" > "$I32_FIFO"
    for ((i = 0; i < timeout * 2; i++)); do
        if grep -aqE "${mark}rc=[0-9]" "$I32_LOG" 2>/dev/null; then
            GOUT="$(con_clean < "$I32_LOG" | sed "0,/DONE${I32_SEQ}Xrc=/d" | sed "/${mark}rc=[0-9]/,\$d")"
            GRC="$(con_clean < "$I32_LOG" | sed -n "s/.*${mark}rc=\([0-9][0-9]*\).*/\1/p" | head -1)"
            return 0
        fi
        sleep 0.5
    done
    GOUT="$(con_clean < "$I32_LOG")"
    GRC=""
    return 1
}

# Wait for a guest to answer at all - after a rollback or a migration the
# console comes back from nothing and there is no point asking until it does.
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

# Re-attach after the qemu process has been replaced (rollback, migration).
reattach() {
    local timeout="${1:-180}" i
    detach
    sleep 2
    for ((i = 0; i < 30; i++)); do
        [ -S "$(con_sock)" ] && break
        sleep 2
    done
    attach || return 1
    gwait "$timeout"
}

# Stop bash emitting bracketed-paste markers in the first place. The stream is
# sanitised anyway, but not generating the noise keeps the log readable.
gquiet() { gexec "bind 'set enable-bracketed-paste off' 2>/dev/null; true" 10; }
