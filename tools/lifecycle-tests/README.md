# lifecycle-tests

Integration tests for plugin behavior around **lifecycle events** —
reboots, service restarts, package upgrades, process crashes, network
flaps, TrueNAS control-plane bounces, and wall-clock jumps.

GitHub #132 showed that the main
`tools/dev-truenas-plugin-full-function-test.sh` suite missed a whole
class of boot-time regressions because every phase assumed the broker
was already up. Lifecycle events (reboot, broker restart, broker crash)
create brief windows where the broker's Unix socket isn't listening or
its upstream WS isn't connected; without careful ordering the plugin's
fallback paths can trip TrueNAS's auth rate limit, pile up pvedaemon
worker forks, or leave the system wedged below `graphical.target`.

Each script in this directory drives one lifecycle event, then asserts
the same two "nothing stormed" counters:

- `journalctl -t truenasplugin` contains zero `broker socket missing`
  entries since the event.
- Same journal contains zero `rate limited` entries since the event.

Plus:

- `systemctl is-active truenas-plugin-broker` is `active`.
- All pre-staged test VMs are `running`.

## Scenarios

| # | Script                              | Lifecycle event                                |
|---|-------------------------------------|------------------------------------------------|
| 01 | `01-reboot.sh`                     | Full `systemctl reboot` of the target node.    |
| 02 | `02-broker-restart-under-load.sh`  | `systemctl restart truenas-plugin-broker` with N concurrent `pvesm status` loops in flight. |
| 03 | `03-broker-crash.sh`               | `kill -9` on the broker's MainPID; expect systemd `Restart=on-failure` to respawn. |
| 04 | `04-package-upgrade.sh`            | `dpkg -i truenas-proxmox-plugin_<ver>.deb` over the running install while VMs are up. |
| 05 | `05-pvestatd-restart.sh`           | `systemctl restart pvestatd` with the broker already up. |
| 06 | `06-network-flap.sh`               | `ip link set <storage-nic> down` for a few seconds, then back up. |
| 07 | `07-tn-controller-restart.sh`      | `systemctl restart middlewared` on the TrueNAS target. |
| 08 | `08-clock-jump.sh`                 | `date -s +1h`, then back `-1h`, with NTP paused during. |

Order matters a little: 01 (full reboot) is last in `run-all.sh`
because it kicks the whole node. 05 (pvestatd restart) is first because
it's the most contained.

## Usage

Pre-reqs on orchestrator (where you run this):

- SSH key access as root to the target PVE node.
- SSH access as `truenas_admin` to the TrueNAS (for 07).

Pre-reqs on target node:

- A `truenasplugin:` storage configured and `active` in
  `/etc/pve/storage.cfg`.
- VMID range for test VMs is unused (default 10100-10102).
- Enough storage headroom for 3 × 1 GB thin-provisioned zvols.
- `fuser` installed (for the gates the plugin ships).

Run one scenario:

    ./tools/lifecycle-tests/01-reboot.sh \
        --node 192.168.1.183 \
        --storage truenas-storage

Run them all against the same node:

    ./tools/lifecycle-tests/run-all.sh \
        --node 192.168.1.183 \
        --storage truenas-storage \
        --vmid-start 10100 --vm-count 3

Standard args every scenario accepts:

| arg              | default | meaning                                              |
|------------------|---------|------------------------------------------------------|
| `--node`         | *req*   | SSH target: hostname or IP of the DISPOSABLE PVE node |
| `--storage`      | *req*   | `truenasplugin:` storage id on that node             |
| `--vmid-start`   | 10100   | first VMID to use for test VMs                       |
| `--vm-count`     | 3       | how many test VMs to pre-stage                       |
| `--settle-s`     | 30      | seconds to wait after the event before scanning      |
| `--keep-vms`     | off     | don't destroy the test VMs on exit (debugging)       |

Scenario-specific args are documented in each script's header.

## Caveats

- Every scenario is destructive to the TARGET NODE in some way. Run
  against a disposable PVE member whose VMs can briefly go down. Don't
  run against the orchestrator host.
- Scenarios 06 (network flap) and 01 (reboot) interrupt SSH to the
  target. Scenarios 07 (middlewared restart) and 08 (clock jump)
  disturb other truenasplugin storages that point at the same TN /
  share the host clock.
- `04-package-upgrade.sh` installs whatever `.deb` is most recent in
  `/home/wmo/truenas-proxmox-plugin_*.deb` on the orchestrator unless
  you pass `--deb-path`. "Upgrade" in practice is often "reinstall the
  same version" if you just built it; that still exercises prerm +
  postinst, which is what we're testing.
- These tests complement, don't replace, the main
  `dev-truenas-plugin-full-function-test.sh` suite. That suite covers
  per-API-call correctness in steady state; this suite covers
  state transitions.

## Adding a new scenario

1. Copy an existing script as a template.
2. Keep the standard arg parsing (`EXTRAS=$(lt_init "$@"); set -- ${EXTRAS}`).
3. Call `lt_provision_vms` early.
4. Capture a `mark=$(lt_ssh 'date "+%Y-%m-%d %H:%M:%S"')` right before
   the event.
5. Trigger the event.
6. `sleep "${LT_SETTLE_S}"` to let callers settle.
7. Call `lt_assert_no_storm "${mark}" "<label>"`,
   `lt_assert_broker_active`, `lt_assert_vms_running "<label>"`.
8. Call `lt_cleanup_vms` then `lt_summary`.
9. Add to `run-all.sh`'s `ORDER` array.
10. Document the scenario-specific args in the script's header + here.
