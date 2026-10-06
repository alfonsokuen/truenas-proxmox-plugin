# Despliegue de idk22 y vuelta atras (runbook)

Aplica a un cluster de 3 nodos que hoy corre `1:2.1.23~alpha1+idk21` y recibe
`1:2.1.23~beta8+idk22`. Se hace **nodo a nodo**, sin prisa. Nada de esto se
ejecuta desde el repositorio: es el procedimiento para el operador.

## 0. Antes de empezar (una sola vez)

1. **Guardar el .deb de idk21 de CADA nodo.** `reprepro` sirve una sola
   version por suite: en cuanto publiquemos idk22, idk21 ya no se puede bajar
   del repositorio, y es lo unico que permite volver atras.

   ```bash
   # en cada nodo
   mkdir -p /root/idk21-rollback && cd /root/idk21-rollback
   apt-get download truenas-proxmox-plugin=1:2.1.23~alpha1+idk21 \
     || dpkg-repack truenas-proxmox-plugin      # si ya no esta en el repo
   sha256sum *.deb > SHA256SUMS
   ```

   Copiar tambien el `.deb` a un sitio fuera de los nodos.
2. **Ventana**: sin `vzdump` programado y sin migraciones HA en curso mientras
   dura el despliegue (parar o aplazar los jobs de backup; poner el
   `ha-manager` en modo de mantenimiento si hay recursos HA en el nodo).
3. **No escribir claves nuevas de storage.cfg** (`tn_use_cluster_lock`,
   `tn_device_ready_retries`, un `tn_api_host` con corchetes IPv6 o formato
   portal-dns) **hasta que los 3 nodos esten en idk22.** Medido: idk21 no
   descarta la seccion, descarta esa clave con un warning, y un `pvesm set`
   hecho desde un nodo idk21 la borra del stanza para todo el cluster.
4. Leer `debian/changelog` (entrada idk22): cambios de comportamiento y known
   issues. En especial: **no borrar** ningun `unusedN` que aparezca tras un
   `qm rescan` global sobre clones enlazados.

## 1. Comprobaciones previas en cada nodo (solo lectura)

Objetivo: saber que usa el almacenamiento NVMe/iSCSI antes de recargar los
demonios.

```bash
# dispositivos NVMe del subsistema y quien los usa
ls /sys/block | grep -E '^nvme'
for d in /sys/block/nvme*n*; do echo "$d holders: $(ls $d/holders 2>/dev/null | tr '\n' ' ')"; done
grep -E 'nvme|/dev/mapper' /proc/self/mountinfo
fuser -v -m /dev/nvme*n* 2>&1 | head     # rc=1 sin salida = nadie los tiene abiertos
pvs; lvs                                  # LVM del host sobre namespaces (p. ej. vg_nvmeof)
```

CTs con rootfs en `tn-prod` (no reiniciarlos ni migrarlos durante el despliegue):

| Nodo | CTs |
|---|---|
| pve1 | 100, 116, 119, 132 |
| pve2 | 108 |
| pve3 | 121 |

Si hay un FS montado desde un namespace o un holder dm/LVM, **es normal que no
haya procesos**: el plugin idk22 lo cuenta como "en uso" y por eso NO reconectara
el subsistema; no hace falta (ni se debe) desconectarlo a mano.

## 2. Instalar en un nodo

```bash
# un nodo cada vez; esperar a que quede sano antes del siguiente
apt-get update
apt-get install --only-upgrade truenas-proxmox-plugin      # o install-idk.sh
```

El postinst recarga (`reload-or-try-restart`) pvedaemon, pvestatd, pvescheduler,
pve-ha-crm y pve-ha-lrm, programa pveproxy a ~10 s y recarga las reglas udev.
No re-dispara los namespaces ya conectados.

## 3. Verificar tras CADA nodo

- [ ] `systemctl is-active truenas-plugin-broker` = `active`, con el pool de
      conexiones previsto (N=4): `journalctl -u truenas-plugin-broker -n 50`.
- [ ] Sin `ENOTAUTHENTICATED` en el journal del broker ni de pvedaemon.
- [ ] `max_sectors_kb` = **1024** en todos los `nvme*n*` del subsistema:
      `for d in /sys/block/nvme*n*/queue/max_sectors_kb; do echo "$d $(cat $d)"; done`
      (conviven la regla del paquete y, si existe,
      `/etc/udev/rules.d/99-nvmeof-maxio.rules`; las dos valen 1024).
- [ ] `pvesm status` lista `tn-prod` activo y con capacidad.
- [ ] La primera `qm destroy` de una VM de prueba genera una tarea **imgdel** en
      verde en la lista de tareas (el borrado del dataset vive ahi, fuera del lock).
- [ ] Sin lineas `reconnect` ni `EMERGENCY` en el journal desde la instalacion:
      `journalctl -u pvedaemon -u pvestatd --since "<hora de instalacion>" | grep -Ei 'reconnect|EMERGENCY'`
      (si aparece "SKIPPED (subsystem devices are in use)" es la guarda
      funcionando: investigar por que no aparecia el namespace, no forzar).

Solo con el nodo sano pasar al siguiente. Cuando **los 3** estan en idk22 se
pueden empezar a usar las claves nuevas del punto 0.3.

## 4. Vuelta atras (por nodo)

```bash
dpkg -i /root/idk21-rollback/truenas-proxmox-plugin_*idk21*_all.deb
# el postinst de idk21 solo recarga pvedaemon/pvestatd/pveproxy:
systemctl restart pvescheduler pve-ha-crm pve-ha-lrm
udevadm control --reload-rules      # la regla de idk22 queda fuera del paquete
```

Despues repetir las comprobaciones del punto 3 adaptadas (broker activo,
`pvesm status`). Si se habian escrito claves nuevas en `storage.cfg`, quitarlas
a mano: idk21 las ignora con un warning pero un `pvesm set` desde idk21 las
borra para todo el cluster.

## 5. No se corrige en este despliegue (pendientes anotados)

- `qm rescan` global registra el disco de un clon enlazado como `unusedN`
  (preexistente de idk21); borrarlo liberaria el disco que usa el clon.
- `pvesm free` imprime "Removed volume" aunque el borrado diferido (tarea imgdel)
  falle despues.
- El reaper de namespaces frente a un `create_base` en otro nodo (hipotesis).
- La clave API pasada por argv en `install.sh` (preexistente).
- 4Kn e IPv6 sin validar.
