# Despliegue de idk23 y vuelta atras (runbook)

Aplica a un cluster de 3 nodos que hoy corre `1:2.1.23~beta8+idk22` y recibe
`1:2.1.23+deb1+idk23`. Se hace **nodo a nodo**: canario pve2 durante 24 h, luego
pve3 y pve1. Nada de esto se ejecuta desde el repositorio: es el procedimiento
para el operador.

## 0. Antes de empezar

1. **Guardar el .deb de idk22 de CADA nodo** (el repo APT sirve una sola
   version por suite; en cuanto se publique idk23, idk22 ya no se puede bajar).

   ```bash
   mkdir -p /root/idk22-rollback && cd /root/idk22-rollback
   apt-get download truenas-proxmox-plugin=1:2.1.23~beta8+idk22 \
     || dpkg-repack truenas-proxmox-plugin      # si ya no esta en el repo
   sha256sum *.deb > SHA256SUMS
   ```

2. **Ventana**: sin migraciones HA en curso y sin `vzdump` ni restores
   (parar o aplazar los jobs de backup).
3. **`tn_force_delete_on_inuse` NO se activa.** Sigue sin estar endurecido (ver
   `wiki/Known-Limitations.md`).
4. Leer la entrada idk23 de `debian/changelog`.

## 1. Instalar en un nodo

**SOLO con `dpkg -i` del .deb, de uno en uno. Nunca dentro de un `apt` con mas
paquetes** (el trigger de pve-manager se difiere al final del apt y puede
coincidir con otras recargas).

```bash
sha256sum truenas-proxmox-plugin_2.1.23+deb1+idk23_all.deb   # contra el SHA256SUMS de la release
dpkg -i truenas-proxmox-plugin_2.1.23+deb1+idk23_all.deb
```

Por que: el postinst ya no recarga `pvedaemon`, `pvestatd`, `pvescheduler` ni
`pveproxy`; lo hace UNA vez el trigger de pve-manager (se dispara porque el
plugin vive bajo `/usr/share/perl5/PVE`). El postinst solo recarga
`pve-ha-crm`/`pve-ha-lrm` y el broker. **No usar `dpkg --no-triggers`**: los
demonios se quedarian con el plugin viejo (recargarlos a mano:
`systemctl reload-or-try-restart pvedaemon pvestatd pvescheduler pveproxy`).

## 2. Comprobar a +30 s

```bash
for u in pvedaemon pvestatd pvescheduler pveproxy spiceproxy pve-ha-crm pve-ha-lrm truenas-plugin-broker; do
  printf '%-24s %s\n' "$u" "$(systemctl is-active $u)"; done        # todos: active
dpkg -s pve-manager | grep '^Status:'                              # install ok installed
journalctl --since '-5min' -u pvedaemon -u pvestatd -u pveproxy --no-pager | grep -E 'server shutdown|starting server|restarting server'
```

En el journal debe verse **UN ciclo** "server shutdown (restart)" ->
"starting server"/"restarting server" por cada uno de `pvedaemon`, `pvestatd` y
`pveproxy`. Dos ciclos en `pvestatd` = la doble recarga sigue ahi: parar y
avisar. Si un demonio murio: `systemctl start <unidad>`.

## 3. Verificar QUE build quedo instalado

Varios builds comparten la version `1:2.1.23+deb1+idk23` y el mismo
`TrueNASPlugin.pm`: **el .pm no distingue los builds**. Comparar:

```bash
sha256sum truenas-proxmox-plugin_2.1.23+deb1+idk23_all.deb                  # contra la release
md5sum /var/lib/dpkg/info/truenas-proxmox-plugin.postinst                   # contra el postinst del .deb
dpkg-deb --ctrl-tarfile truenas-proxmox-plugin_*.deb | tar -xO ./postinst | md5sum
```

## 4. Vigilar durante 24 h (canario pve2)

```bash
journalctl -u pvestatd -u pvedaemon --since today --no-pager | grep -E 'could not delete the snapshot clone|refusing to destroy'
```

Esos dos mensajes son el comportamiento fail-closed nuevo: cada uno es una
operacion que se nego a continuar y hay que mirar por que, no silenciar. Si el
canario esta limpio a las 24 h, repetir 1-3 en pve3 y luego en pve1.

## 5. Vuelta atras

```bash
cd /root/idk22-rollback && sha256sum -c SHA256SUMS
dpkg -i truenas-proxmox-plugin_*.deb
```

**El postinst de idk22 hace la doble recarga** (la que mata a `pvestatd` en
~3 de 9 instalaciones). Tras el rollback repetir la comprobacion de la seccion 2
y arrancar a mano el que haya muerto: `systemctl start pvestatd`.
