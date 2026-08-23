#!/bin/bash
# Build a small guest that can be driven without a network, with two kinds of
# data on it.
#
# Blocks and files are not the same claim. A block-level pattern proves the
# storage returned the bytes it was given; it says nothing about whether a
# filesystem sitting on those bytes is still coherent. A live snapshot of a
# mounted filesystem is crash-consistent at best, and the interesting question
# is whether it replays its journal cleanly and whether every file still hashes
# to what it hashed before. So the guest carries both:
#
#   scsi1  serial i32blk  raw pattern, verified block by block from (seed,offset)
#   scsi2  serial i32fs   ext4 with a few hundred files and a sha256 manifest
#
# The disks are found by serial rather than by name. Deriving "the data disk"
# from lsblk output works right up until the boot order changes, and then the
# test writes to the wrong disk and reports it as damage.
#
# The guest needs no network and no qemu-guest-agent: Ubuntu's cloud image puts
# a console on ttyS0, PVE exposes that as a unix socket, and cloud-init turns it
# into an autologin root shell.
#
#   i32-livevm-setup.sh <vmid> <storage> [os-gib] [blk-gib] [fs-gib]

set -uo pipefail

VMID="${1:-}"
STORAGE="${2:-}"
OSGIB="${3:-8}"
BLKGIB="${4:-2}"
FSGIB="${5:-2}"
IMG=/var/lib/vz/template/iso/ubuntu-24.04-cloudimg-amd64.img
BV=/root/i32/i32-blockverify.pl
SNIP=/var/lib/vz/snippets/i32-live-${VMID}.yaml

[ -n "$VMID" ] && [ -n "$STORAGE" ] || { echo "usage: $0 <vmid> <storage> [os-gib] [blk-gib] [fs-gib]" >&2; exit 2; }
case "$VMID" in
    999[0-9]) ;;
    *) echo "refusing: VMID $VMID is outside the scratch range 9990-9999" >&2; exit 2 ;;
esac
[ -r "$IMG" ] || { echo "missing $IMG" >&2; exit 2; }
[ -r "$BV" ]  || { echo "missing $BV" >&2; exit 2; }
qm status "$VMID" >/dev/null 2>&1 && { echo "refusing: VM $VMID already exists" >&2; exit 2; }

SEED_A=$(( VMID * 100 + 11 ))
PAT_MIB=1024
SMALL_FILES=200
BIG_FILES=3

echo "=== preparando el snippet de cloud-init ==="
mkdir -p /var/lib/vz/snippets
BV_B64="$(base64 -w 76 "$BV" | sed 's/^/      /')"

cat > "$SNIP" <<YAML
#cloud-config
hostname: i32-live-${VMID}
ssh_pwauth: false
disable_root: false

write_files:
  - path: /etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf
    permissions: '0644'
    content: |
      [Service]
      ExecStart=
      ExecStart=-/sbin/agetty --autologin root --noclear %I 115200 linux

  - path: /root/i32-blockverify.pl.b64
    permissions: '0644'
    content: |
${BV_B64}

  - path: /usr/local/bin/i32-paths.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      # Resolve the two data disks by their serial, once, for everyone else.
      I32BLK=\$(readlink -f /dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_i32blk 2>/dev/null)
      I32FS=\$(readlink -f /dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_i32fs 2>/dev/null)
      [ -b "\$I32BLK" ] || I32BLK=\$(readlink -f /dev/disk/by-id/*i32blk 2>/dev/null | head -1)
      [ -b "\$I32FS" ]  || I32FS=\$(readlink -f /dev/disk/by-id/*i32fs 2>/dev/null | head -1)
      export I32BLK I32FS
      I32MNT=/mnt/i32
      export I32MNT

  - path: /usr/local/bin/i32-fs-populate.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      # Lay down a filesystem with files whose contents are known, and record
      # the manifest on the OS disk so it travels with the VM through whatever
      # is done to it next.
      set -u
      . /usr/local/bin/i32-paths.sh
      [ -b "\$I32FS" ] || { echo "I32-ERROR: no encuentro el disco de ficheros"; exit 1; }
      umount "\$I32MNT" 2>/dev/null
      mkfs.ext4 -q -F -L i32fs "\$I32FS" || exit 1
      mkdir -p "\$I32MNT"
      mount "\$I32FS" "\$I32MNT" || exit 1
      mkdir -p "\$I32MNT/d" "\$I32MNT/scratch"
      # Assorted sizes, incompressible, so neither ZFS underneath nor the backup
      # compressor can turn the write into metadata and skip the storage.
      for i in \$(seq 1 ${SMALL_FILES}); do
          sz=\$(( (i % 20 + 1) * 64 ))
          dd if=/dev/urandom of="\$I32MNT/d/f\$i" bs=1K count=\$sz status=none
      done
      for i in \$(seq 1 ${BIG_FILES}); do
          dd if=/dev/urandom of="\$I32MNT/d/big\$i" bs=1M count=64 status=none
      done
      sync
      # -print0 / sort -z / xargs -0r on both sides: the hypervisor recomputes
      # this exact command over the restored disk and compares the hash, so the
      # two have to agree byte for byte. A plain sort would agree only as long
      # as every filename stays ASCII and the two machines share a locale, and
      # a bare xargs would sit reading stdin if the list ever came back empty.
      ( cd "\$I32MNT" && find d -type f -print0 | LC_ALL=C sort -z | xargs -0r sha256sum ) > /root/i32-manifest.sha256
      sync
      n=\$(wc -l < /root/i32-manifest.sha256)
      h=\$(sha256sum /root/i32-manifest.sha256 | cut -c1-16)
      echo "I32-MANIFIESTO ficheros=\$n hash=\$h"

  - path: /usr/local/bin/i32-fs-verify.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      # Three separate questions, reported separately: does every file still
      # hash the same, is the filesystem structurally sound, and is the manifest
      # itself the one we think it is. A run that answers only the first would
      # miss a filesystem that verifies its files while quietly corrupt.
      set -u
      . /usr/local/bin/i32-paths.sh
      rc=0
      mountpoint -q "\$I32MNT" || mount "\$I32FS" "\$I32MNT" 2>/dev/null
      if ! mountpoint -q "\$I32MNT"; then
          echo "I32-FS: NO SE PUEDE MONTAR"
          exit 3
      fi
      n=\$(wc -l < /root/i32-manifest.sha256 2>/dev/null || echo 0)
      h=\$(sha256sum /root/i32-manifest.sha256 2>/dev/null | cut -c1-16)
      bad=\$( cd "\$I32MNT" && sha256sum -c /root/i32-manifest.sha256 2>/dev/null | grep -c ': FALLO\|: FAILED' )
      have=\$( cd "\$I32MNT" && find d -type f | wc -l )
      echo "I32-FS ficheros=\$n presentes=\$have malos=\$bad hash=\$h"
      [ "\$bad" = 0 ] || rc=1
      [ "\$have" = "\$n" ] || rc=1
      # fsck needs the filesystem unmounted to say anything trustworthy. On a
      # mounted device e2fsck answers "no" to its own "continue?" prompt, prints
      # "check aborted" and exits 0 - a clean-looking result that checked
      # nothing at all. The background load writes here every second, so the
      # umount has to be retried and, if it never wins, reported as a failure
      # rather than quietly skipped.
      # Stop the background load first rather than race it. The load writes on
      # a one-second cycle and a one-second retry loop locks in phase with it,
      # so every attempt lands mid-write and the umount never wins. The load is
      # there to make the storage OPERATIONS hard, not to make verification
      # impossible - so it is stopped for the check and started again after.
      pkill -f i32-guest-load.sh 2>/dev/null
      for t in 1 2 3 4 5 6 7 8 9 10; do
          pgrep -f i32-guest-load.sh >/dev/null 2>&1 || break
          sleep 1
      done
      um=0
      for t in 1 2 3 4 5 6 7 8 9 10; do
          umount "\$I32MNT" 2>/dev/null && { um=1; break; }
          sleep 0.7
      done
      if [ "\$um" = 0 ]; then
          echo "I32-FSCK rc=SIN-DESMONTAR el fs sigue montado, no se comprobo"
          rc=1
      else
          out=\$(fsck.ext4 -fn "\$I32FS" 2>&1)
          frc=\$?
          echo "I32-FSCK rc=\$frc \$(echo "\$out" | tail -2 | tr '\\n' ' ')"
          # With -n nothing is repaired, so rc=1 means errors are present and
          # were left alone - not that they were fixed. Only 0 is clean.
          [ "\$frc" = 0 ] || rc=1
          echo "\$out" | grep -qiE 'check aborted|is mounted' && rc=1
      fi
      mount "\$I32FS" "\$I32MNT" 2>/dev/null
      pgrep -f i32-guest-load.sh >/dev/null 2>&1 || \\
          nohup /usr/local/bin/i32-guest-load.sh >/dev/null 2>&1 &
      echo "I32-FS-RC=\$rc"
      exit \$rc

  - path: /usr/local/bin/i32-guest-init.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      set -u
      exec > >(tee -a /var/log/i32-guest.log > /dev/console) 2>&1
      base64 -d /root/i32-blockverify.pl.b64 > /root/i32-blockverify.pl
      chmod +x /root/i32-blockverify.pl
      . /usr/local/bin/i32-paths.sh
      echo "I32: bloque=\$I32BLK ficheros=\$I32FS"
      [ -b "\$I32BLK" ] && [ -b "\$I32FS" ] || { echo "I32-ERROR: faltan discos"; exit 1; }

      /root/i32-blockverify.pl write "\$I32BLK" \$(( ${PAT_MIB} * 1024 * 1024 )) ${SEED_A}
      sync
      echo "I32-PATRON-ESCRITO ${PAT_MIB}MiB semilla ${SEED_A}"

      /usr/local/bin/i32-fs-populate.sh
      nohup /usr/local/bin/i32-guest-load.sh >/dev/null 2>&1 &
      echo "I32-LISTO"

  - path: /usr/local/bin/i32-guest-load.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      # Keep both disks genuinely busy while snapshots and migrations happen.
      # The bulk churn is outside the verified pattern and outside the manifest,
      # so a crash-consistent copy still contains intact data - that load is
      # there to make the operation hard, not to make it ambiguous.
      #
      # But load that is never verified proves nothing about the data that was
      # in flight, which is the only data a snapshot can actually get wrong.
      # So it also keeps an append-only journal: one line per tick, a counter
      # that only ever goes up, each line made durable before the next is
      # written. Losing the tail of that file is normal and expected - a copy
      # taken at an instant simply ends somewhere. A HOLE in the middle is not:
      # it means a write that was acknowledged and durable was dropped or
      # reordered by the snapshot path. That is the failure worth catching.
      set -u
      . /usr/local/bin/i32-paths.sh
      OFF=\$(( ${PAT_MIB} + 64 ))
      # Resume the counter where the file left off. The verify stops and
      # restarts this loop, and a counter that restarted at zero would put a
      # step backwards in the middle of the journal - which the restore check
      # would read as the very data loss it is looking for.
      SEQ=\$(tail -1 "\$I32MNT/journal" 2>/dev/null | tr -dc '0-9' | sed 's/^0*//')
      [ -n "\$SEQ" ] || SEQ=0
      while :; do
          dd if=/dev/urandom of="\$I32BLK" bs=1M seek=\$OFF count=8 \\
             oflag=direct conv=notrunc status=none 2>/dev/null
          if mountpoint -q "\$I32MNT"; then
              dd if=/dev/urandom of="\$I32MNT/scratch/churn" bs=1M count=8 status=none 2>/dev/null
              SEQ=\$(( SEQ + 1 ))
              printf '%08d\\n' "\$SEQ" >> "\$I32MNT/journal"
              sync
          fi
          sleep 1
      done

runcmd:
  - [ systemctl, daemon-reload ]
  - [ systemctl, restart, "serial-getty@ttyS0.service" ]
  - [ /usr/local/bin/i32-guest-init.sh ]

final_message: "I32-CLOUDINIT-FIN tras \$UPTIME segundos"
YAML

echo "  snippet: $SNIP ($(wc -c < "$SNIP") bytes)"

echo ""
echo "=== creando la VM $VMID ==="
qm create "$VMID" --name "i32-live-$VMID" --memory 2048 --cores 2 \
    --scsihw virtio-scsi-single --ostype l26 \
    --serial0 socket --vga serial0 --agent 0 || { echo "qm create fallo" >&2; exit 1; }

# link_down keeps cloud-init from waiting on a network that is not there, and
# guarantees this guest cannot reach the production LAN even by accident.
qm set "$VMID" --net0 "virtio,bridge=vmbr0,link_down=1" >/dev/null

echo "  importando la imagen cloud (puede tardar)..."
qm set "$VMID" --scsi0 "$STORAGE:0,import-from=$IMG" >/dev/null || { echo "importacion fallo" >&2; exit 1; }
qm resize "$VMID" scsi0 "${OSGIB}G" >/dev/null 2>&1

echo "  disco de patron (${BLKGIB} GiB, serial i32blk)..."
qm set "$VMID" --scsi1 "$STORAGE:${BLKGIB},serial=i32blk" >/dev/null
echo "  disco de ficheros (${FSGIB} GiB, serial i32fs)..."
qm set "$VMID" --scsi2 "$STORAGE:${FSGIB},serial=i32fs" >/dev/null

qm set "$VMID" --ide2 "$STORAGE:cloudinit" >/dev/null
qm set "$VMID" --cicustom "user=local:snippets/$(basename "$SNIP")" >/dev/null
qm set "$VMID" --boot "order=scsi0" >/dev/null

echo ""
echo "=== configuracion ==="
qm config "$VMID" | grep -E '^(scsi|ide2|net0|memory|cores|serial|boot|name)' | sed 's/^/  /'

echo ""
echo "=== arrancando ==="
qm start "$VMID" && echo "  arrancada" || { echo "  el arranque fallo" >&2; exit 1; }
echo "  socket serie: /var/run/qemu-server/${VMID}.serial0"
