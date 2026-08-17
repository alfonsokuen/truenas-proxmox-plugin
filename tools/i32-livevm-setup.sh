#!/bin/bash
# Build a small guest that can be driven without a network.
#
# Everything measured so far was written to a stopped VM's disk from the host.
# That skips the only path that matters in production: a guest issuing I/O
# through virtio-scsi while the disk is live, and a snapshot taken underneath
# it while it does. Those are different code paths in qemu and in PVE, and a
# stopped-VM snapshot passing says nothing about a running one.
#
# The guest needs no network and no qemu-guest-agent. Ubuntu's cloud image puts
# a console on ttyS0, PVE can expose that as a unix socket, and cloud-init can
# turn it into an autologin root shell. That is a full control channel that
# touches no production network and leaves no DHCP lease behind.
#
# The verifier that runs inside the guest is the same file the host uses, so
# both sides regenerate identical bytes from (seed, offset) and a disagreement
# means the storage disagreed - not that two implementations drifted.
#
#   i32-livevm-setup.sh <vmid> <storage> [os-gib] [data-gib]

set -uo pipefail

VMID="${1:-}"
STORAGE="${2:-}"
OSGIB="${3:-8}"
DATAGIB="${4:-4}"
IMG=/var/lib/vz/template/iso/ubuntu-24.04-cloudimg-amd64.img
BV=/root/i32/i32-blockverify.pl
SNIP=/var/lib/vz/snippets/i32-live-${VMID}.yaml

[ -n "$VMID" ] && [ -n "$STORAGE" ] || { echo "usage: $0 <vmid> <storage> [os-gib] [data-gib]" >&2; exit 2; }
case "$VMID" in
    999[0-9]) ;;
    *) echo "refusing: VMID $VMID is outside the scratch range 9990-9999" >&2; exit 2 ;;
esac
[ -r "$IMG" ] || { echo "missing $IMG" >&2; exit 2; }
[ -r "$BV" ]  || { echo "missing $BV" >&2; exit 2; }
qm status "$VMID" >/dev/null 2>&1 && { echo "refusing: VM $VMID already exists" >&2; exit 2; }

SEED_A=$(( VMID * 100 + 11 ))
PAT_MIB=1024

echo "=== preparando la semilla y el verificador para el invitado ==="
mkdir -p /var/lib/vz/snippets

# The verifier goes in as base64 so no quoting inside the YAML can corrupt it.
BV_B64="$(base64 -w 76 "$BV" | sed 's/^/      /')"

cat > "$SNIP" <<YAML
#cloud-config
hostname: i32-live-${VMID}

# No password login is wanted anywhere; the control channel is the serial
# console, and it is reachable only from the hypervisor's own filesystem.
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

  - path: /usr/local/bin/i32-guest-init.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      # Prepare the data disk and announce readiness on the console.
      set -u
      exec >>/var/log/i32-guest.log 2>&1
      base64 -d /root/i32-blockverify.pl.b64 > /root/i32-blockverify.pl
      chmod +x /root/i32-blockverify.pl

      # The OS disk is whichever one carries the root filesystem; the data disk
      # is the other one. Guessing /dev/sdb would be wrong the day the boot
      # order changes, so it is derived rather than assumed.
      ROOTDEV=\$(findmnt -no SOURCE / | sed 's/[0-9]*\$//; s#/dev/##')
      for d in /sys/block/sd*; do
          b=\$(basename "\$d")
          [ "\$b" = "\$ROOTDEV" ] && continue
          echo "\$b" > /run/i32-datadisk
          break
      done
      DATA=\$(cat /run/i32-datadisk 2>/dev/null)
      echo "I32: disco raiz=\$ROOTDEV  disco de datos=\$DATA"
      [ -n "\$DATA" ] || { echo "I32-ERROR: no encuentro el disco de datos"; exit 1; }

      /root/i32-blockverify.pl write "/dev/\$DATA" \$(( ${PAT_MIB} * 1024 * 1024 )) ${SEED_A}
      sync
      echo "I32-PATRON-ESCRITO ${PAT_MIB}MiB semilla ${SEED_A} en /dev/\$DATA"

      # A trickle of writes so the guest is genuinely doing I/O when the
      # snapshot lands, rather than idle with a quiesced disk.
      nohup /usr/local/bin/i32-guest-load.sh >/dev/null 2>&1 &
      echo "I32-LISTO"

  - path: /usr/local/bin/i32-guest-load.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      # Rewrite a scratch region near the end of the disk, over and over. It is
      # deliberately outside the verified range so the live load never collides
      # with the pattern the tests compare.
      set -u
      DATA=\$(cat /run/i32-datadisk)
      OFF=\$(( ${PAT_MIB} + 64 ))
      while :; do
          dd if=/dev/urandom of="/dev/\$DATA" bs=1M seek=\$OFF count=8 \\
             oflag=direct conv=notrunc status=none 2>/dev/null
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
    --serial0 socket --vga serial0 \
    --agent 0 || { echo "qm create fallo" >&2; exit 1; }

# link_down keeps cloud-init from waiting on a network that is not there, and
# guarantees this guest cannot reach the production LAN even by accident.
qm set "$VMID" --net0 "virtio,bridge=vmbr0,link_down=1" >/dev/null

echo "  importando la imagen cloud a $STORAGE (puede tardar)..."
qm set "$VMID" --scsi0 "$STORAGE:0,import-from=$IMG" >/dev/null || {
    echo "la importacion fallo" >&2; exit 1; }
qm resize "$VMID" scsi0 "${OSGIB}G" >/dev/null 2>&1

echo "  añadiendo el disco de datos de ${DATAGIB} GiB..."
qm set "$VMID" --scsi1 "$STORAGE:${DATAGIB}" >/dev/null

qm set "$VMID" --ide2 "$STORAGE:cloudinit" >/dev/null
qm set "$VMID" --cicustom "user=local:snippets/$(basename "$SNIP")" >/dev/null
qm set "$VMID" --boot "order=scsi0" >/dev/null

echo ""
echo "=== configuracion final ==="
qm config "$VMID" | grep -vE 'sshkeys|cipassword' | sed 's/^/  /'

echo ""
echo "=== formatos de los discos ==="
for d in scsi0 scsi1; do
    v="$(qm config "$VMID" | sed -n "s/^$d: \([^,]*\).*/\1/p")"
    [ -n "$v" ] || continue
    printf "  %-6s %-42s %s\n" "$d" "$v" "$(qm status "$VMID" >/dev/null && echo "")"
done

echo ""
echo "=== arrancando ==="
qm start "$VMID" && echo "  arrancada" || { echo "  el arranque fallo" >&2; exit 1; }
echo "  socket serie: /var/run/qemu-server/${VMID}.serial0"
