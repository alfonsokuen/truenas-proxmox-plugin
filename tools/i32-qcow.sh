#!/bin/bash
# Integrity of the qcow2 layer, not just the transport underneath it.
#
# The earlier runs wrote straight to the LV, which is the correct place to test
# the fabric but skips the format entirely. A VM disk on this storage is qcow2
# on an LV with snapshot-as-volume-chain, so between the guest and the wire
# there are L1/L2 tables, refcounts, cluster allocation and - when a snapshot
# exists - a backing chain. All of that can corrupt data while the transport
# underneath stays perfectly healthy.
#
# Phases:
#   Q1  the format itself: allocate, write a verifiable pattern through the
#       qcow2 layer, read it back, and check the metadata before and after
#   Q2  the snapshot chain: pattern A, snapshot, overwrite with B, roll back,
#       and confirm A comes back byte for byte
#   Q3  positive control: deliberately damage data and then metadata, and
#       confirm both are DETECTED. Without this, "intacto" only means the
#       verifier said nothing - which is also what a broken verifier says.
#   Q4  what the format costs: same device, qcow2 path vs raw path
#
#   i32-qcow.sh --storage <sid> --vmid <9990-9999> [--size GiB] [--phases Q1,Q2,Q3,Q4] --yes
#
# It creates and destroys a VM and its disk. VMIDs are restricted to the
# scratch range and every volume it touches must belong to that VMID.

set -uo pipefail

STORAGE=""; VMID=""; SIZE=8; PHASES="Q1,Q2,Q3,Q4"; YES=0
while [ $# -gt 0 ]; do
    case "$1" in
        --storage) STORAGE="$2"; shift 2 ;;
        --vmid)    VMID="$2";    shift 2 ;;
        --size)    SIZE="$2";    shift 2 ;;
        --phases)  PHASES="$2";  shift 2 ;;
        --yes)     YES=1;        shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

if [ -z "$STORAGE" ] || [ -z "$VMID" ]; then
    echo "usage: $0 --storage <sid> --vmid <9990-9999> [--size GiB] [--phases ...] --yes" >&2
    exit 2
fi
[ "$(id -u)" = 0 ] || { echo "must run as root" >&2; exit 2; }

# The whole safety story is this range plus the ownership checks below. Every
# destructive command in here names $VMID, and nothing else can be reached.
case "$VMID" in
    999[0-9]) ;;
    *) echo "refusing: VMID $VMID is outside the scratch range 9990-9999" >&2; exit 2 ;;
esac

BV="$(dirname "$0")/i32-blockverify.pl"
[ -x "$BV" ] || { echo "missing $BV" >&2; exit 2; }

SEED_A=$(( VMID * 100 + 11 ))
SEED_B=$(( VMID * 100 + 22 ))
PAT_MIB=$(( SIZE * 1024 / 2 ))          # half the disk, so a rollback has
if [ "$PAT_MIB" -gt 4096 ]; then        # untouched territory beyond it too
    PAT_MIB=4096
fi
SUB_MIB=1024                            # region rewritten after the snapshot
if [ "$SUB_MIB" -gt "$PAT_MIB" ]; then
    SUB_MIB=$(( PAT_MIB / 2 ))
fi

NBD=""
LOADED_NBD=0
FAILURES=0
SUMMARY=()

say()  { echo ""; echo "=== $* ==="; }
note() { echo "    $*"; }
pass() { SUMMARY+=("PASS  $*"); note "PASS  $*"; }
fail() { SUMMARY+=("FALLO $*"); note "FALLO $*"; FAILURES=$(( FAILURES + 1 )); }
skip() { SUMMARY+=("--    $*"); note "--    $*"; }

has_phase() { case ",$PHASES," in *",$1,"*) return 0 ;; *) return 1 ;; esac }

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

# Shared LVM logical volumes are only activated on the node that needs them,
# and PVE deactivates them again behind our back. Anything that opens the path
# directly has to ask for activation first or it gets ENOENT, and we would read
# that as damage.
activate_vol() {
    perl -e 'use PVE::Storage;
             my $cfg = PVE::Storage::config();
             eval { PVE::Storage::activate_volumes($cfg, [ $ARGV[0] ]) };' "$1" 2>/dev/null || true
}

cur_volid() {
    qm config "$VMID" 2>/dev/null | sed -n 's/^scsi0: \([^,]*\).*/\1/p'
}

cur_path() {
    local v
    v="$(cur_volid)"
    [ -n "$v" ] || return 1
    activate_vol "$v"
    pvesm path "$v" 2>/dev/null
}

nbd_attach() {
    local path="$1" i w
    for i in 0 1 2 3 4 5 6 7; do
        if [ ! -e "/sys/block/nbd$i/pid" ]; then
            if qemu-nbd --connect="/dev/nbd$i" --format=qcow2 --cache=none "$path" 2>/dev/null; then
                NBD="/dev/nbd$i"
                # The connect returns before the kernel has sized the device.
                for w in 1 2 3 4 5 6 7 8 9 10; do
                    if [ "$(blockdev --getsize64 "$NBD" 2>/dev/null || echo 0)" -gt 0 ]; then
                        return 0
                    fi
                    sleep 0.3
                done
                return 0
            fi
        fi
    done
    NBD=""
    return 1
}

nbd_detach() {
    [ -n "$NBD" ] || return 0
    sync
    qemu-nbd --disconnect "$NBD" >/dev/null 2>&1 || true
    NBD=""
}

# qemu-img check is the only thing here that reads the metadata as metadata.
# Its exit codes matter: 0 clean, 1 leaked clusters only, 2 corruption, 3 fixed.
img_check() {
    local path="$1" label="$2" out rc
    out="$(qemu-img check -f qcow2 "$path" 2>&1)"
    rc=$?
    echo "$out" | sed 's/^/      /' | head -10
    case "$rc" in
        0) pass "$label: metadatos qcow2 sin errores" ;;
        1) pass "$label: clusters filtrados pero sin corrupcion" ;;
        *) fail "$label: qemu-img check devuelve $rc" ;;
    esac
    return 0
}

cleanup() {
    nbd_detach
    if [ "$LOADED_NBD" = 1 ]; then
        modprobe -r nbd >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# preflight
# ---------------------------------------------------------------------------

say "preflight"
note "nodo      : $(hostname)"
note "kernel    : $(uname -r)"
note "storage   : $STORAGE"
note "vmid      : $VMID (rango scratch)"
note "disco     : ${SIZE} GiB, patron ${PAT_MIB} MiB, semillas ${SEED_A}/${SEED_B}"

if qm status "$VMID" >/dev/null 2>&1; then
    echo "refusing: VM $VMID already exists - resolve it by hand first" >&2
    exit 2
fi
if pvesh get /cluster/resources --type vm --output-format json 2>/dev/null | grep -q "\"vmid\":$VMID,"; then
    echo "refusing: VMID $VMID is in use somewhere in the cluster" >&2
    exit 2
fi

# Anything already carrying this VMID's name is a leftover we must not adopt.
stale="$(pvesm list "$STORAGE" 2>/dev/null | awk -v v="$VMID" '$1 ~ ("(vm|base)-" v "-")' | wc -l)"
if [ "$stale" -gt 0 ]; then
    echo "refusing: $stale leftover volume(s) for VMID $VMID on $STORAGE" >&2
    pvesm list "$STORAGE" | awk -v v="$VMID" '$1 ~ ("(vm|base)-" v "-")' >&2
    exit 2
fi
note "sin restos previos de $VMID"

# /sys/module/nbd is the kernel's own answer. Parsing lsmod for it is one more
# thing that can be wrong about a module that is actually there, and swallowing
# modprobe's stderr means a refusal that says nothing about why.
nbd_loaded() { [ -d /sys/module/nbd ]; }
mp_err=""
if ! nbd_loaded; then
    mp_err="$(modprobe nbd max_part=0 nbds_max=8 2>&1)" && LOADED_NBD=1
    for t in 1 2 3 4 5; do
        nbd_loaded && break
        sleep 0.4
    done
fi
if ! nbd_loaded; then
    echo "refusing: cannot load the nbd module: ${mp_err:-sin mensaje de error}" >&2
    exit 2
fi
if [ "$LOADED_NBD" = 1 ]; then
    note "nbd cargado por este script, se descarga al salir"
else
    note "nbd ya estaba cargado, no se toca"
fi

if [ "$YES" != 1 ]; then
    echo ""
    echo "Crea la VM $VMID con un disco de ${SIZE} GiB en $STORAGE y la destruye al terminar."
    echo "Relanza con --yes para ejecutar."
    exit 0
fi

# ---------------------------------------------------------------------------
# Q1 - the format itself
# ---------------------------------------------------------------------------

if has_phase Q1; then
    say "Q1 - integridad a traves de la capa qcow2"

    if ! qm create "$VMID" --name "i32-qcow-$VMID" --memory 512 --cores 1 \
                   --scsihw virtio-scsi-single --scsi0 "$STORAGE:$SIZE" >/dev/null 2>&1; then
        fail "Q1: qm create fallo"
    else
        pass "Q1: qm create asigna el disco"
        VOL="$(cur_volid)"
        note "volumen   : $VOL"
        DEVP="$(cur_path)"
        note "ruta      : $DEVP"

        # The JSON output carries two "format" keys: the protocol layer, which
        # for an LV is always host_device, and the image format. Grabbing the
        # first one reports host_device for a perfectly good qcow2. The plain
        # text output names the one we care about without ambiguity.
        fmt="$(qemu-img info "$DEVP" 2>/dev/null | sed -n 's/^file format: //p' | head -1)"
        note "formato   : ${fmt:-desconocido}"
        if [ "$fmt" = "qcow2" ]; then
            pass "Q1: el volumen es qcow2 de verdad, no raw"
        else
            fail "Q1: se esperaba qcow2 y es '${fmt:-desconocido}'"
        fi

        img_check "$DEVP" "Q1 base"

        if nbd_attach "$DEVP"; then
            note "nbd       : $NBD ($(blockdev --getsize64 "$NBD" 2>/dev/null) bytes)"
            note "escribiendo ${PAT_MIB} MiB de patron (semilla $SEED_A) a traves de qcow2..."
            if "$BV" write "$NBD" "$(( PAT_MIB * 1024 * 1024 ))" "$SEED_A" >/dev/null 2>&1; then
                pass "Q1: escritura del patron completada"
            else
                fail "Q1: la escritura del patron fallo"
            fi
            sync
            blockdev --flushbufs "$NBD" 2>/dev/null || true

            out="$("$BV" verify "$NBD" "$(( PAT_MIB * 1024 * 1024 ))" "$SEED_A" 2>&1)"
            rc=$?
            echo "$out" | sed 's/^/      /' | head -12
            if [ "$rc" = 0 ]; then
                pass "Q1: relectura a traves de qcow2 byte a byte identica"
            else
                fail "Q1: DAÑO leyendo a traves de la capa qcow2"
            fi

            nbd_detach
            img_check "$DEVP" "Q1 tras escribir"
        else
            fail "Q1: no se pudo conectar qemu-nbd"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Q2 - the snapshot chain
# ---------------------------------------------------------------------------

if has_phase Q2; then
    say "Q2 - integridad de la cadena de snapshots"

    if ! qm status "$VMID" >/dev/null 2>&1; then
        skip "Q2: no hay VM $VMID (Q1 no llego a crearla)"
    else
        if qm snapshot "$VMID" s1 --description "i32 qcow integrity" >/dev/null 2>&1; then
            pass "Q2: qm snapshot s1 creado"
        else
            fail "Q2: qm snapshot fallo"
        fi

        note "volumenes de $VMID tras el snapshot:"
        lvs --noheadings -o lv_name,lv_size,lv_attr vg_nvmeof 2>/dev/null | grep -- "-$VMID-" | sed 's/^/      /' || true
        VOL2="$(cur_volid)"
        note "volumen actual: $VOL2"
        PATH2="$(cur_path)"
        note "ruta actual   : $PATH2"
        qemu-img info --backing-chain "$PATH2" 2>/dev/null | grep -E '^(image|backing file|file format):' | sed 's/^/      /' || true

        # Overwrite the head of the disk with a different pattern. On a volume
        # chain this is where a wrong backing-file reference shows up: the write
        # lands in the new layer and the old data has to stay reachable in the
        # layer underneath.
        if nbd_attach "$PATH2"; then
            note "sobrescribiendo los primeros ${SUB_MIB} MiB con la semilla $SEED_B..."
            "$BV" write "$NBD" "$(( SUB_MIB * 1024 * 1024 ))" "$SEED_B" >/dev/null 2>&1
            sync
            blockdev --flushbufs "$NBD" 2>/dev/null || true

            out="$("$BV" verify "$NBD" "$(( SUB_MIB * 1024 * 1024 ))" "$SEED_B" 2>&1)"
            rc=$?
            if [ "$rc" = 0 ]; then
                pass "Q2: la capa nueva devuelve el patron nuevo"
            else
                fail "Q2: la capa nueva no devuelve lo que se le escribio"
            fi

            # Everything past SUB_MIB was never rewritten, so it must still read
            # through the backing file untouched.
            # "Some blocks differ" is too weak an answer here. If the chain is
            # wired up correctly, exactly the rewritten region differs and not
            # one block more - a backing file that leaked into the wrong range
            # would still satisfy a mere "rc != 0".
            EXPECT_DIFF=$(( SUB_MIB * 256 ))
            out="$("$BV" verify "$NBD" "$(( PAT_MIB * 1024 * 1024 ))" "$SEED_A" 2>&1)"
            rc=$?
            got="$(echo "$out" | sed -n 's/^MISMATCH: \([0-9][0-9]*\) of .*/\1/p' | head -1)"
            note "bloques distintos: ${got:-0} (esperados exactamente $EXPECT_DIFF)"
            if [ "$rc" = 0 ]; then
                fail "Q2: tras sobrescribir, el disco sigue leyendo el patron viejo - la escritura no llego"
            elif [ "${got:-0}" = "$EXPECT_DIFF" ]; then
                pass "Q2: difiere exactamente la region reescrita, ni un bloque mas"
            else
                echo "$out" | sed 's/^/      /' | head -10
                fail "Q2: difieren ${got:-?} bloques y deberian ser $EXPECT_DIFF - la cadena no delimita bien las capas"
            fi
            nbd_detach
        else
            fail "Q2: no se pudo conectar qemu-nbd a la cabeza de la cadena"
        fi

        # The real test. Everything above is setup.
        if qm rollback "$VMID" s1 >/dev/null 2>&1; then
            pass "Q2: qm rollback s1 completado"
        else
            fail "Q2: qm rollback fallo"
        fi

        PATH3="$(cur_path)"
        note "ruta tras rollback: $PATH3"
        if nbd_attach "$PATH3"; then
            out="$("$BV" verify "$NBD" "$(( PAT_MIB * 1024 * 1024 ))" "$SEED_A" 2>&1)"
            rc=$?
            echo "$out" | sed 's/^/      /' | head -12
            if [ "$rc" = 0 ]; then
                pass "Q2: tras el rollback los ${PAT_MIB} MiB vuelven al patron original byte a byte"
            else
                fail "Q2: el rollback NO restauro los datos originales"
            fi
            nbd_detach
        else
            fail "Q2: no se pudo conectar qemu-nbd tras el rollback"
        fi

        if qm delsnapshot "$VMID" s1 >/dev/null 2>&1; then
            pass "Q2: qm delsnapshot s1 completado"
        else
            fail "Q2: qm delsnapshot fallo"
        fi

        PATH4="$(cur_path)"
        img_check "$PATH4" "Q2 tras borrar el snapshot"

        # Deleting a snapshot commits or discards a layer. If that went wrong,
        # the data says so - the metadata check would not.
        if nbd_attach "$PATH4"; then
            out="$("$BV" verify "$NBD" "$(( PAT_MIB * 1024 * 1024 ))" "$SEED_A" 2>&1)"
            rc=$?
            if [ "$rc" = 0 ]; then
                pass "Q2: los datos sobreviven al borrado del snapshot"
            else
                echo "$out" | sed 's/^/      /' | head -12
                fail "Q2: borrar el snapshot daño los datos"
            fi
            nbd_detach
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Q3 - positive control
# ---------------------------------------------------------------------------

if has_phase Q3; then
    say "Q3 - control positivo: el daño se detecta"
    note "Sin esta fase, 'intacto' solo significa que el verificador no dijo nada,"
    note "que es exactamente lo que diria un verificador roto."

    if ! qm status "$VMID" >/dev/null 2>&1; then
        skip "Q3: no hay VM $VMID"
    else
        PATH5="$(cur_path)"
        if nbd_attach "$PATH5"; then
            OFF_MIB=100
            note "corrompiendo 8 KiB a proposito en el offset ${OFF_MIB} MiB..."
            dd if=/dev/urandom of="$NBD" bs=4096 seek=$(( OFF_MIB * 256 )) count=2 \
               conv=notrunc oflag=direct status=none 2>/dev/null
            sync
            blockdev --flushbufs "$NBD" 2>/dev/null || true

            out="$("$BV" verify "$NBD" "$(( PAT_MIB * 1024 * 1024 ))" "$SEED_A" 2>&1)"
            rc=$?
            echo "$out" | sed 's/^/      /' | head -14
            if [ "$rc" != 0 ]; then
                if echo "$out" | grep -q "104857600"; then
                    pass "Q3: el daño se detecta Y se localiza en el offset correcto"
                else
                    pass "Q3: el daño se detecta"
                fi
            else
                fail "Q3: 8 KiB corrompidos y el verificador dice intacto - EL VERIFICADOR NO SIRVE"
            fi
            nbd_detach
        else
            fail "Q3: no se pudo conectar qemu-nbd para el control positivo"
        fi

        # Metadata corruption, on a volume of its own so nothing else is at risk.
        say "Q3b - corrupcion de metadatos qcow2"
        if pvesm alloc "$STORAGE" "$VMID" "vm-$VMID-disk-9" 1G --format qcow2 >/dev/null 2>&1; then
            pass "Q3b: pvesm alloc de un volumen de 1 GiB"
            MVOL="$STORAGE:vm-$VMID-disk-9"
            activate_vol "$MVOL"
            MPATH="$(pvesm path "$MVOL" 2>/dev/null)"
            note "ruta      : $MPATH"

            qemu-img check -f qcow2 "$MPATH" >/dev/null 2>&1
            rc=$?
            if [ "$rc" -le 1 ]; then
                pass "Q3b: recien creado, los metadatos estan limpios"
            else
                fail "Q3b: un volumen recien creado ya da error $rc"
            fi

            # The L1 table sits just past the header cluster. Filling it with
            # garbage makes every L2 pointer invalid, which is precisely what
            # qemu-img check exists to notice.
            note "destruyendo la tabla L1 a proposito..."
            dd if=/dev/urandom of="$MPATH" bs=512 seek=128 count=8 conv=notrunc status=none 2>/dev/null
            sync

            out="$(qemu-img check -f qcow2 "$MPATH" 2>&1)"
            rc=$?
            echo "$out" | sed 's/^/      /' | head -10
            # rc 2 is "completed, image is corrupt"; rc 1 is "could not complete",
            # which is what happens when the tables are too broken to walk. Both
            # are detection. The only failure would be rc 0 - saying it is fine.
            nerr="$(echo "$out" | grep -c 'ERROR' || true)"
            if [ "$rc" != 0 ] && [ "$nerr" -gt 0 ]; then
                case "$rc" in
                    2) pass "Q3b: qemu-img check declara la imagen corrupta ($nerr errores)" ;;
                    *) pass "Q3b: qemu-img check no puede completar y reporta $nerr errores (rc=$rc)" ;;
                esac
            else
                fail "Q3b: metadatos destrozados y qemu-img check devuelve $rc con $nerr errores"
            fi

            # And the block layer must not hand a guest silently wrong clusters.
            if nbd_attach "$MPATH"; then
                bad="$(dd if="$NBD" bs=4096 count=16 2>/dev/null | wc -c)"
                note "lectura tras la corrupcion: $bad bytes devueltos"
                nbd_detach
                if [ "$bad" -lt 65536 ]; then
                    pass "Q3b: la capa de bloque corta la lectura de la imagen dañada"
                else
                    pass "Q3b: la imagen dañada se abre pero qemu-img check ya la marca"
                fi
            else
                pass "Q3b: la capa de bloque se NIEGA a abrir la imagen dañada"
            fi

            if pvesm free "$MVOL" >/dev/null 2>&1; then
                pass "Q3b: pvesm free libera el volumen dañado"
            else
                fail "Q3b: pvesm free no pudo liberar $MVOL"
            fi
        else
            fail "Q3b: pvesm alloc fallo"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Q4 - what the format costs
# ---------------------------------------------------------------------------

if has_phase Q4; then
    say "Q4 - coste del formato: qcow2 frente al LV en crudo"

    if ! qm status "$VMID" >/dev/null 2>&1; then
        skip "Q4: no hay VM $VMID"
    else
        PATH6="$(cur_path)"
        SRC=/dev/shm/i32-qcow-src
        dd if=/dev/urandom of="$SRC" bs=1M count=256 status=none
        MIB=1024

        bench() {
            local dev="$1" bs="$2" bsb="$3" mode="$4" t0 t1 i loops
            loops=$(( MIB / 256 ))
            blockdev --flushbufs "$dev" 2>/dev/null || true
            t0=$(date +%s.%N)
            for ((i = 0; i < loops; i++)); do
                if [ "$mode" = w ]; then
                    dd if="$SRC" of="$dev" bs="$bs" seek=$(( i * 256 * 1048576 / bsb )) \
                       count=$(( 256 * 1048576 / bsb )) oflag=direct status=none 2>/dev/null
                else
                    dd if="$dev" of=/dev/null bs="$bs" skip=$(( i * 256 * 1048576 / bsb )) \
                       count=$(( 256 * 1048576 / bsb )) iflag=direct status=none 2>/dev/null
                fi
            done
            t1=$(date +%s.%N)
            awk -v a="$t0" -v b="$t1" -v m="$MIB" 'BEGIN { d = b - a; if (d <= 0) d = 0.001; printf "%.0f", m / d }'
        }

        Q1M_W=""; Q1M_R=""; Q4M_W=""; Q4M_R=""
        if nbd_attach "$PATH6"; then
            Q1M_W="$(bench "$NBD" 1M 1048576 w)"
            Q1M_R="$(bench "$NBD" 1M 1048576 r)"
            Q4M_W="$(bench "$NBD" 4M 4194304 w)"
            Q4M_R="$(bench "$NBD" 4M 4194304 r)"
            nbd_detach
            pass "Q4: medido a traves de qcow2 sobre nbd"
        else
            fail "Q4: no se pudo conectar qemu-nbd"
        fi

        # The nbd figures above are a floor, not the format's real cost: a guest
        # opens the qcow2 inside its own qemu, while nbd adds a userspace server
        # and a kernel client round trip that no VM ever pays. qemu-img bench
        # opens the image the same way a VM does, so the gap between its two
        # rows is the format overhead and nothing else.
        qbench() {
            local path="$1" fmt="$2" bsz="$3" cnt="$4" mode="$5" out secs extra=""
            [ "$mode" = w ] && extra="-w"
            out="$(qemu-img bench -f "$fmt" -t none -n $extra --pattern=0x5a \
                   -s "$bsz" -c "$cnt" -d 16 "$path" 2>&1)"
            secs="$(echo "$out" | sed -n 's/^Run completed in \([0-9.]*\) seconds.*/\1/p' | head -1)"
            if [ -z "$secs" ]; then echo "n/a"; return; fi
            awk -v s="$secs" -v b="$bsz" -v c="$cnt" \
                'BEGIN { if (s <= 0) s = 0.001; printf "%.0f", (b * c) / 1048576 / s }'
        }
        DQ1_R=""; DQ1_W=""; DR1_R=""; DR1_W=""
        DQ1_R="$(qbench "$PATH6" qcow2 1048576 1024 r)"
        DQ1_W="$(qbench "$PATH6" qcow2 1048576 1024 w)"
        DR1_R="$(qbench "$PATH6" raw   1048576 1024 r)"
        DR1_W="$(qbench "$PATH6" raw   1048576 1024 w)"
        pass "Q4: medido tambien sin nbd, con qemu-img bench"

        # The same LV, opened raw. The difference between the two rows is what
        # the format costs - anything else would be comparing two devices.
        R1M_W=""; R1M_R=""; R4M_W=""; R4M_R=""
        if [ -b "$PATH6" ]; then
            R1M_W="$(bench "$PATH6" 1M 1048576 w)"
            R1M_R="$(bench "$PATH6" 1M 1048576 r)"
            R4M_W="$(bench "$PATH6" 4M 4194304 w)"
            R4M_R="$(bench "$PATH6" 4M 4194304 r)"
            pass "Q4: medido en crudo sobre el mismo LV (la imagen queda inservible, se destruye despues)"
        else
            fail "Q4: $PATH6 no es un dispositivo de bloque"
        fi

        echo ""
        echo "      dd con datos incompresibles, qcow2 servido por nbd (suelo, no el caso real):"
        printf "      %-8s %-12s %-12s %-12s %-12s\n" "bloque" "qcow2 esc" "qcow2 lec" "raw esc" "raw lec"
        printf "      %-8s %-12s %-12s %-12s %-12s\n" "------" "---------" "---------" "-------" "-------"
        printf "      %-8s %-12s %-12s %-12s %-12s\n" "1M" "$Q1M_W" "$Q1M_R" "$R1M_W" "$R1M_R"
        printf "      %-8s %-12s %-12s %-12s %-12s\n" "4M" "$Q4M_W" "$Q4M_R" "$R4M_W" "$R4M_R"
        echo ""
        echo "      qemu-img bench, misma ruta que abre una VM, sin nbd de por medio:"
        printf "      %-8s %-12s %-12s %-12s %-12s\n" "bloque" "qcow2 esc" "qcow2 lec" "raw esc" "raw lec"
        printf "      %-8s %-12s %-12s %-12s %-12s\n" "------" "---------" "---------" "-------" "-------"
        printf "      %-8s %-12s %-12s %-12s %-12s\n" "1M" "$DQ1_W" "$DQ1_R" "$DR1_W" "$DR1_R"
        echo ""
        echo "      (MB/s) qemu-img bench escribe un patron constante, que ZFS comprime al"
        echo "      otro lado del cable: sus cifras absolutas estan infladas y solo sirven"
        echo "      para comparar qcow2 contra raw. Las absolutas buenas son las de dd."
        rm -f "$SRC"
    fi
fi

# ---------------------------------------------------------------------------
# teardown
# ---------------------------------------------------------------------------

say "limpieza"
nbd_detach
if qm status "$VMID" >/dev/null 2>&1; then
    if qm destroy "$VMID" --purge --destroy-unreferenced-disks 1 >/dev/null 2>&1; then
        pass "limpieza: VM $VMID y su disco destruidos"
    else
        fail "limpieza: qm destroy fallo - QUEDA BASURA para VMID $VMID"
    fi
fi
left="$(pvesm list "$STORAGE" 2>/dev/null | awk -v v="$VMID" '$1 ~ ("(vm|base)-" v "-")' | wc -l)"
if [ "$left" = 0 ]; then
    pass "limpieza: no queda ningun volumen de $VMID en $STORAGE"
else
    fail "limpieza: quedan $left volumen(es) de $VMID"
    pvesm list "$STORAGE" | awk -v v="$VMID" '$1 ~ ("(vm|base)-" v "-")' | sed 's/^/      /'
fi

say "resumen"
i=0
while [ "$i" -lt "${#SUMMARY[@]}" ]; do
    echo "  ${SUMMARY[$i]}"
    i=$(( i + 1 ))
done
echo ""
if [ "$FAILURES" = 0 ]; then
    echo "  Todo limpio: la capa qcow2, la cadena de snapshots y el rollback"
    echo "  conservan los datos, y el daño provocado a proposito SI se detecta."
else
    echo "  $FAILURES comprobacion(es) fallidas - arriba esta cual."
fi
exit "$FAILURES"
