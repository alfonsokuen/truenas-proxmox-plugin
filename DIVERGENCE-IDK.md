# Divergencia del fork IDK respecto a upstream (github.com/truenas/truenas-proxmox-plugin)

Version instalada en pve1/pve2/pve3: `2.1.24~alpha1+idk6` + campana idk7 (v3..v6, 2026-08-23).
Protegida con pin de APT (`/etc/apt/preferences.d/truenas-proxmox-plugin`, Pin-Priority -1).

## Serie idk6 (previa, ya en este arbol)
- Hot-publish de namespaces en TrueNAS 25.10.4 (el bloqueo que upstream resolvia "esperar a 26.04").

## Serie idk7 — resiliencia ante caida de la API (este arbol = v6)
`patches/idk7-full.diff` es la serie completa contra la base limpia; v4/v5 los deltas intermedios;
`patch_idk7_v*.py` los generadores anclados por texto exacto.

1. Recent-failure marker compartido: `activate_storage()` corre ANTES de `status()` en cada sweep
   de pvestatd, asi que el breaker de status() solo no ahorra nada. El marcador ACOTA (nunca salta)
   `_nvme_ensure_subsystem` a `API_DOWN_PROBE_BUDGET_S` (2s).
2. El camino repair de `status()` (self-heal de whitelist) se acota igual.
3. Clasificacion del error del ensure por las frases autogeneradas del retry engine, ancladas al
   inicio (`^Gave up on |^Operation failed after \d+ retries: `) — nunca substrings de payload.
4. Reserva de presupuesto en el reconcile de whitelist SOLO cuando el close va a ejecutarse
   (`$will_close`); authorize-only jamas se difiere.
5. Notas throttled con severidad por tag, ventana derivada del backoff, clave por unidad de trabajo.
6. Mensaje de presupuesto honesto ("Budget of 10s, capped to 2s by an outer deadline").

Tests: `t/nvme/13..15` (los nuevos), suite completa 332/332. Mutation testing: los mutantes de las
3 rondas de review mueren. Validado en vivo: apagones controlados de la API, whitelist+DHCHAP,
failover de portal con I/O, migracion en vivo entre 3 nodos, LXC snapshot-backup.

## Borrador de PR upstream
Titulo: "storage poll resilience: bounded API probes while the array is unreachable"
Cuerpo: pvestatd pays a full broker timeout per storage per poll while a TrueNAS array is down,
because activate_storage()'s subsystem ensure runs before status()'s breaker can help. This series
adds a shared recent-failure marker that CAPS (never skips) the periodic ensure at 2s, classifies
expected-vs-real ensure failures by the retry engine's own death sentences, and keeps whitelist
reconciliation safe under short budgets. Measured: 15/15 polls at ~10s each -> 3 slow cycles per
outage; pvestatd never starves. 332 tests, mutation-hardened.

## Serie idk8 (2026-08-23, tarde) — iSCSI CHAP contra TrueNAS 25.10
Dos hallazgos upstream, ambos verificados en vivo:
1. **idk8**: 25.10 impone CHAP de discovery IMPLICITO en cuanto existe cualquier grupo
   `iscsi/auth` (el knob `discovery_authmethod` ya no existe en la API). El plugin solo
   configuraba `node.session.auth.*`, asi que su propio discovery moria con "initiator
   failed authorization". Fix: helper `_iscsi_discover` que alimenta el discoverydb con
   las mismas credenciales antes de descubrir.
2. **idk8b**: el bucle principal de `_iscsi_login_all` era CODIGO MUERTO — `iscsiadm -m
   node -T <iqn>` imprime el record completo, no la lista "portal,tpgt iqn" que el parser
   esperaba, asi que @nodes siempre quedaba vacio y toda sesion entraba por el fallback
   sin auth (que ademas resetea el discoverydb). En claro colaba; con CHAP no habia sesion
   posible. Fix: listar todos los nodos y filtrar, tolerar el sufijo `,tpgt`, y fallback
   CHAP-aware.
Validado: login CHAP autonomo desde estado cliente limpio, VM+I/O end-to-end, negativo
(login sin credenciales RECHAZADO por el target), suite 332/332 sin regresiones.

## Empaquetado — `tools/build-deb.sh` (2026-08-23, al publicar el fork)
La verificacion final del build derivaba la version esperada del plugin con
`plugin_version="${deb_version%%+*}"`: upstream trata el sufijo tras `+` como revision de
EMPAQUETADO, de modo que el `.pm` declara solo la parte anterior. Este fork usa `+idk6` como parte
de la IDENTIDAD del plugin y el `.pm` la declara entera, asi que la comprobacion moria con
"Version injection verification failed" y **el paquete no se podia construir desde este arbol**.
Ahora se aceptan las DOS convenciones (`${deb_version}` o `${deb_version%%+*}`) y se compara de
forma literal, no por ERE — la version lleva `~` y `+`, que en una expresion regular significan
otra cosa y dejaban pasar cadenas que no eran la esperada. Lo destapo el workflow heredado de
upstream al publicar el repo.

## Capas base NO contabilizadas como serie (descubiertas 2026-08-26 al portar idk7 a upstream)
El arbol del fork lleva, ademas de idk6/7/8, TRES capas previas sin serie propia que upstream
(main v2.1.5) no tiene: (1) motor de reintentos con presupuesto wall-clock (`tn_api_budget_s`,
`$_api_deadline`, mensaje "Gave up on..."); (2) whitelist NVMe + DH-HMAC-CHAP
(`tn_nvme_allow_any_host`, `_nvme_reconcile_host_whitelist`, ~200 lineas); (3) reconciliacion
de portales desde status() (`_nvme_connect(repair=>1)` en cada poll). El "2.1.24~alpha1" base
fue bump PROPIO (la alpha upstream mas nueva es 2.1.23-alpha34) — estas capas son nuestras.

## PRs/issues upstream (estado 2026-08-26)
- PR #95 (OPEN): fixes CHAP iSCSI (idk8+idk8b).
- Issue #96: bug del target nvmet (sc 0x6 en I/O 6-32MB bajo carga) + mitigacion max_sectors_kb.
- PR #97 (OPEN): resiliencia con budget opt-in — port de idk7 piezas 1/3/5/6 + prerrequisitos
  (motor budget behavior-neutral + marker). Piezas 2 y 4 fuera de alcance (dependen de las capas
  self-heal y whitelist; candidatas a PRs futuros propios).
