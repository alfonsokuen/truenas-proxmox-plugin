<h1 align="center">TrueNAS Proxmox VE Storage Plugin</h1>

<p align="center">A high-performance storage plugin for Proxmox VE that integrates TrueNAS SCALE via iSCSI or NVMe/TCP, featuring live snapshots, LXC container storage, ZFS integration, and cluster compatibility.</p>


> ### This is a modified fork
>
> Fork of [truenas/truenas-proxmox-plugin](https://github.com/truenas/truenas-proxmox-plugin),
> modified by **IDK MANAGER** in August 2026 (patch series `idk6`, `idk7` and `idk8`).
> What differs from upstream, and why, is documented in [DIVERGENCE-IDK.md](DIVERGENCE-IDK.md).
>
> Two of the fixes in this fork are proposed back upstream in
> [PR #95](https://github.com/truenas/truenas-proxmox-plugin/pull/95): iSCSI CHAP could not
> work against TrueNAS SCALE 25.10 because discovery-CHAP became implicit and the main login
> loop in `_iscsi_login_all` was dead code, so every session silently fell through to an
> unauthenticated fallback.
>
> **Upstream does not support this copy.** Report anything you find here against this
> repository, not against the TrueNAS project. Links to `truenas/...` further down this README
> are upstream's own install instructions and are left as they are on purpose — installing
> from them gives you upstream's build, not this one.

## Features

- **Dual Transport Support** - iSCSI (traditional) or NVMe/TCP (lower latency) block storage
- **iSCSI Block Storage** - Direct integration with TrueNAS SCALE via iSCSI targets
- **NVMe/TCP Support** - Modern NVMe over TCP for reduced latency and CPU overhead (TrueNAS SCALE 25.10+)
- **LXC Container Storage** - Block-backed container rootfs support alongside VM disk storage
- **ZFS Snapshots** - Instant, space-efficient snapshots via TrueNAS ZFS
- **Live Snapshots** - Full VM state snapshots including RAM (vmstate)
- **Cluster Compatible** - Full support for Proxmox VE clusters with shared storage
- **Automatic Volume Management** - Dynamic zvol creation and iSCSI extent mapping
- **Configuration Validation** - Pre-flight checks and validation prevent misconfigurations
- **Rate Limiting Protection** - Automatic retry with exponential backoff for TrueNAS API limits
- **Storage Efficiency** - Thin provisioning and ZFS compression support
- **Multi-path Support** - Native support for iSCSI multipathing
- **CHAP Authentication** - Optional CHAP security for iSCSI connections
- **Volume Resize** - Grow-only resize with preflight space checks
- **Error Recovery** - Comprehensive error handling with actionable error messages
- **Performance Optimization** - Configurable block sizes and sparse volumes

## Feature Comparison

| Feature | TrueNAS Plugin | Standard iSCSI | NFS |
|---------|:--------------:|:--------------:|:---:|
| **Snapshots** | ✅ | ⚠️ | ⚠️ |
| **VM State Snapshots (vmstate)** | ✅ | ✅ | ✅ |
| **Clones** | ✅ | ⚠️ | ⚠️ |
| **Thin Provisioning** | ✅ | ⚠️ | ⚠️ |
| **Block-Level Performance** | ✅ | ✅ | ❌ |
| **Shared Storage** | ✅ | ✅ | ✅ |
| **Automatic Volume Management** | ✅ | ❌ | ❌ |
| **Automatic Resize** | ✅ | ❌ | ❌ |
| **Pre-flight Checks** | ✅ | ❌ | ❌ |
| **Multi-path I/O** | ✅ | ✅ | ❌ |
| **ZFS Compression** | ✅ | ❌ | ❌ |
| **Container Storage** | ✅ | ⚠️ | ✅ |
| **Backup Storage** | ❌ | ❌ | ✅ |
| **ISO Storage** | ❌ | ❌ | ✅ |
| **Raw Image Format** | ✅ | ✅ | ✅ |

**Legend**: ✅ Native Support | ⚠️ Via Additional Layer | ❌ Not Supported

**Notes**:
- **Standard iSCSI**: Raw iSCSI lacks native snapshots/clones. Use LVM-thin on iSCSI for full snapshot/clone/thin-provisioning support, or volume chains (Proxmox VE 9+). Container storage available via LVM on iSCSI.
- **NFS**: Snapshots/clones require qcow2 format (performance overhead vs raw). Supports backups, ISOs, and containers natively.
- **TrueNAS Plugin**: Native ZFS features with raw image performance and automated zvol/iSCSI extent management via TrueNAS API. Container (LXC) rootfs stored as ext4-formatted block devices.
- **VM State Snapshots**: All storage types supporting the 'images' content type can store vmstate files for live snapshots with RAM.

## Quick Start

### Installation

**IDK fork, option 1 (recommended): one line**

```bash
curl -sSL https://github.com/alfonsokuen/truenas-proxmox-plugin/releases/latest/download/install-idk.sh | bash -s -- --apt
```

That URL is a **release asset**, on purpose. `raw.githubusercontent.com` keeps
serving a cached copy of a branch file for a long while - long enough that a
node here ran the previous revision of the installer without anyone noticing,
`Cache-Control: no-cache` included. Release assets are not behind that cache.
The installer prints its own version on the first line, so you can always see
which one ran.

`install-idk.sh --apt` configures the fork's signed APT repository
(`https://alfonsokuen.github.io/truenas-proxmox-plugin/apt`, suite `bookworm`
for PVE 8 and `trixie` for PVE 9) and installs from it, so later revisions
arrive with a plain `apt-get upgrade`. Drop `--apt` to install the release
`.deb` directly instead; add `--dry-run` to see what it would do, `--version
idkNN` to pin a revision, or `--wizard` to run `truenas-proxmox-manage` at the
end.

It refuses to run off a Proxmox node; requires the repository keyring to hold
exactly one key and that key to be the fingerprint it pins; compares the
package's SHA256 against the exact line `SHA256SUMS` gives for it; and refuses
to install unless the APT candidate carries the epoch `1:` and is served by
exactly the host it configured. A failed check installs nothing.

The fork's package carries the epoch `1:`, so it outranks upstream's package on
a node that has both APT sources configured. Nothing has to be removed. A node
carrying `Pin: release *` at priority -1 blocks the fork's repository too - see
the pinning policy in the [Installation Guide](wiki/Installation.md).

Manual repository setup, and the signing key
(`1B44 8824 62A1 200E FFCF AEFC 79E6 7ECF B42E E1CC`), are in the
[Installation Guide](wiki/Installation.md).

**IDK fork, option 2: prebuilt .deb from GitHub Releases**

This fork publishes its builds as release assets on
`github.com/alfonsokuen/truenas-proxmox-plugin`. GitHub rewrites `~` in asset
names (a `.deb` whose version has a `~`, such as idk22's, is served as
`…_2.1.23.beta8+idk22_all.deb`). From idk23 on the version is
`2.1.23+deb1+idk23` - no `~` - so the asset keeps its name and the download
needs no renaming:

```bash
V=2.1.23+deb1+idk23
B=https://github.com/alfonsokuen/truenas-proxmox-plugin/releases/download/v2.1.23-deb1+idk23
wget "$B/truenas-proxmox-plugin_${V}_all.deb"
wget "$B/SHA256SUMS"
sha256sum -c SHA256SUMS
apt install "./truenas-proxmox-plugin_${V}_all.deb"
```

idk23 is built on upstream's stable `2.1.23+deb1`. Upstream also names its
release `2.1.23+deb1`, but the fork's package carries the epoch `1:`
(`1:2.1.23+deb1+idk23`), which is what keeps it above upstream's: without the
epoch, `+deb1` would sort above idk22's `~beta8`. Keep the `Pin-Priority -1`
on upstream's origin described in the [Installation Guide](wiki/Installation.md)
anyway.

> **Rolling upgrade to idk22 (still applies when coming from idk21):** do not write the new `storage.cfg` keys
> (`tn_use_cluster_lock`, `tn_device_ready_retries`, or a `tn_api_host` in
> bracketed-IPv6 / portal-dns form) until all three nodes run idk22. Measured
> in the lab: idk21 does NOT drop the section; it discards that one unknown key
> with a warning, and a `pvesm set` run from an idk21 node DELETES it from the
> stanza for the whole cluster. See `docs/idk22-rollout-runbook.md`.

If the same version is already installed, `apt install` is a no-op: use
`apt reinstall ./<file>.deb` or `dpkg -i`. The options below are upstream's.

**No GUI dialog:** Datacenter > Storage > Add does not list TrueNAS — those
forms live in `pve-manager` and an out-of-tree plugin cannot add one. Create the
storage with `pvesm add truenasplugin <id> --tn_api_host ... --tn_api_key ...
--tn_dataset ... --tn_target_iqn ...`, or with the wizard below.

**Storage wizard:** run `truenas-proxmox-manage` (the installer shipped in this
package). Do not pipe upstream's `main` `install.sh` from the options below over
this package: that script still uses the pre-2.1.23 `api_host`/`api_key` field
names, the plugin expects `tn_api_*`, and the wizard fails with
`broker: scfg missing api_host/api_key` even though network and key are fine.

**Option 1 (Recommended): APT Repository**

Install from the official APT repository with the installer:

```bash
bash <(curl -sSL https://raw.githubusercontent.com/truenas/truenas-proxmox-plugin/main/install.sh) --non-interactive --apt-install
```

Optional suite override (for scripted installs):

```bash
bash <(curl -sSL https://raw.githubusercontent.com/truenas/truenas-proxmox-plugin/main/install.sh) --non-interactive --apt-install --apt-suite trixie
```

Suite mapping:
- Proxmox VE 8 -> `bookworm`
- Proxmox VE 9 -> `trixie`

Manual deb822 source setup:

```bash
cat >/etc/apt/sources.list.d/truenas-proxmox-plugin.sources <<'EOF'
Types: deb
URIs: https://truenas.github.io/truenas-proxmox-plugin/apt/
Suites: <bookworm|trixie>
Components: main
Architectures: amd64
Signed-By: /etc/apt/keyrings/truenas-proxmox-plugin.gpg
EOF

mkdir -p /etc/apt/keyrings
curl -fsSL https://truenas.github.io/truenas-proxmox-plugin/apt/pubkey.gpg -o /etc/apt/keyrings/truenas-proxmox-plugin.gpg
apt-get update
apt-get install -y truenas-proxmox-plugin
```

> **Note:** The APT repository only serves **stable releases**.
> Pre-release builds (`-alpha*`, `-beta*`, `-rc*`) are intentionally
> excluded so that `apt upgrade` on a production cluster never pulls in
> an unstable build. To install a beta — or any version newer than what
> APT currently serves — use **Option 2** below with the matching tag,
> or run `install.sh` interactively and choose **"Install specific
> version"** from the menu.

**Option 2: Direct .deb Installation**

Download a release package and install it directly:

```bash
wget https://github.com/truenas/truenas-proxmox-plugin/releases/download/v<RELEASE_TAG>/truenas-proxmox-plugin_<DEB_VERSION>_all.deb
dpkg -i truenas-proxmox-plugin_<DEB_VERSION>_all.deb
apt-get -f install -y
```

The release page lists every build (stable and pre-release); the tag
to use is the one shown in that release's title. Verify against the
attached `SHA256SUMS` before installing. When a beta is later promoted
to a stable release and published to the APT repo, `apt upgrade` will
catch up to it on its own.

**Option 3: Interactive Installer (Existing Workflow)**

Download and run the installer interactively:

```bash
bash <(curl -sSL https://raw.githubusercontent.com/truenas/truenas-proxmox-plugin/main/install.sh)
```

Or download first, then run:
```bash
wget -O install.sh https://raw.githubusercontent.com/truenas/truenas-proxmox-plugin/main/install.sh
chmod +x install.sh
./install.sh
```

The installer provides:
- ✅ Interactive menu-driven setup
- ✅ Automatic version detection and updates
- ✅ Built-in configuration wizard (supports iSCSI and NVMe/TCP)
- ✅ Health check validation
- ✅ Plugin function testing with graceful interrupt handling (Ctrl+C)
- ✅ Backup and rollback support
- ✅ Cluster-wide installation (install/update on all nodes simultaneously)

For expanded installation instructions, see the [Installation Guide](wiki/Installation.md).

**Alternative: Manual Plugin File Installation**

If you prefer manual plugin file installation:

```bash
# Download the plugin
wget -O TrueNASPlugin.pm https://raw.githubusercontent.com/truenas/truenas-proxmox-plugin/main/TrueNASPlugin.pm

# Copy to plugin directory
cp TrueNASPlugin.pm /usr/share/perl5/PVE/Storage/Custom/

# Set permissions
chmod 644 /usr/share/perl5/PVE/Storage/Custom/TrueNASPlugin.pm

# Restart Proxmox services
systemctl restart pvedaemon pveproxy
```

### Configuration

#### Configure Storage
Add to `/etc/pve/storage.cfg`:

```ini
truenasplugin: truenas-storage
    tn_api_host 192.168.1.100
    tn_api_key 1-your-truenas-api-key-here
    tn_api_insecure 1
    tn_target_iqn iqn.2005-10.org.freenas.ctl:proxmox
    tn_dataset tank/proxmox
    tn_discovery_portal 192.168.1.100:3260
    content images,rootdir
    shared 1
```

Replace:
- `192.168.1.100` with your TrueNAS IP
- `1-your-truenas-api-key-here` with your TrueNAS API key
- `tank/proxmox` with your ZFS dataset path

`content images,rootdir` enables both VM disks and LXC container rootfs on this
storage. Drop `rootdir` if you only need VM disks; see
[wiki/LXC-Setup.md](wiki/LXC-Setup.md) for the container-side details.

If your TrueNAS API listens on a port other than 443 (or 80 for `tn_api_scheme=ws`),
add `tn_api_port <port>` — e.g. `tn_api_port 8443`. Otherwise the plugin defaults
to 443 and the broker will fail to connect with a TLS-connect error.

#### NVMe/TCP Configuration (Alternative)

For lower latency and reduced CPU overhead, use NVMe/TCP instead of iSCSI:

```ini
truenasplugin: truenas-nvme
    tn_api_host 192.168.1.100
    tn_api_key 1-your-truenas-api-key-here
    tn_transport_mode nvme-tcp
    tn_subsystem_nqn nqn.2005-10.org.freenas.ctl:proxmox-nvme
    tn_dataset tank/proxmox
    tn_discovery_portal 192.168.1.100:4420
    tn_api_insecure 1
    content images,rootdir
    shared 1
```

`tn_api_insecure 1` is needed when TrueNAS is still using its
default self-signed HTTPS certificate — the plugin's WebSocket
transport verifies the server cert otherwise and the connection
fails before activation. Omit this line once you've replaced the
TrueNAS cert with one your Proxmox hosts trust.

**NVMe/TCP Requirements**:
- TrueNAS SCALE 25.10.0 or later
- Proxmox VE 9.x or later
- Install `nvme-cli` on Proxmox: `apt-get install nvme-cli`
- Enable **NVMe-oF Target** service in TrueNAS

**See [wiki/NVMe-Setup.md](wiki/NVMe-Setup.md) for complete NVMe/TCP setup guide.**

### TrueNAS SCALE Setup

Minimum TrueNAS SCALE version: **25.10** (Goldeye). Both iSCSI and
NVMe/TCP share this floor.

#### 1. Create a dataset

Navigate to **Datasets** → **Add Dataset**:
- **Name**: `proxmox`
- **Parent**: your storage pool (e.g. `tank`)
- **Dataset Preset**: Generic

#### 2. Set up iSCSI — TrueNAS SCALE 25.10 (Goldeye)

**(a) Enable the iSCSI service.** Nav: **System** → **Services**.
In the iSCSI row, click the play button under **Status**, and
toggle **Start Automatically** on.

**(b) Set the iSCSI Base Name.** Nav: **System** → **Services** →
**iSCSI** row → **pencil** (edit) icon on the right end of the row.
The right-side drawer **iSCSI Global Configuration** opens.

- **Base Name**: must start with `iqn.`. The TN default
  `iqn.2005-10.org.freenas.ctl` is fine. Any string that doesn't
  start with `iqn.` (e.g. `TrueNAS`) produces invalid IQNs and no
  initiator will connect — this is the symptom in issue #117.

Note the value; it goes into `tn_target_iqn` in `storage.cfg`
combined with the Target Name you'll pick next, as
`<Base Name>:<Target Name>`.

**(c) Create target, extent, and portal in one flow.** Nav:
**Shares** → **Block (iSCSI) Shares Targets** card → **Wizard**
button on the card. The right-side drawer **iSCSI Wizard** opens
with three steps.

- **Step 1 — Target**: leave the Target dropdown on **Create New**
  (TN will prompt for the Target Name after Save). Click **Next**.
- **Step 2 — Extent**:
  - **Name**: the extent name on TN (any string).
  - **Extent Type**: Device.
  - **Device**: pick the zvol path TN should publish.
  - **Sharing Platform**: pick a modern-OS-style preset. The
    VMware-tuned default sets block-size optimizations that aren't
    what Proxmox wants.
  - Click **Next**.
- **Step 3 — Protocol Options**:
  - **Portal**: `Create New` to spin up a portal on
    `0.0.0.0:3260`, or pick an existing one.
  - **Initiators**: leave empty to allow all Proxmox nodes, or
    paste the initiator IQNs if you want to lock access down.
  - Click **Save**.

> **Both Portal and Initiators on step 3 are what expose the
> target on the network.** If either is blank, `iscsiadm --mode
> discovery` from Proxmox returns empty and the plugin can only
> get as far as allocating zvols on TN. That's the most common
> first-install symptom (issue #117).

The manual per-tab flow (Targets / Extents / Initiators / Portals /
Authorized Access) still exists at `/ui/sharing/iscsi/targets`
with a **Global Target Configuration** button that opens the same
Base Name drawer as (b). Use it only if you need per-field control.

**(d) Create an API key for root.** Top-right **user menu** (person
icon labeled "root") → **My API Keys** → **Add**. Copy the key
value immediately — TN shows it only once. Paste it into
`tn_api_key` in `storage.cfg`.

For a least-privilege API user instead of root, see
[API Permissions](wiki/API-Permissions.md).

#### 3. Set up iSCSI — TrueNAS SCALE 26.0 and later

Nearly identical to 25.10. Follow (a) through (d) above, with
these cosmetic deltas:

- **Shares page** has an extra **WebShare** card — unrelated to
  this plugin, ignore.
- **iSCSI Wizard → Extent step** has an extra **Read-only**
  checkbox — leave it unchecked for Proxmox.
- **Top-right user menu** has an extra **Preferences** item;
  **My API Keys** is in the same place.

#### 4. Optional: CHAP

If you want CHAP on the target: at step 3 (Protocol Options) of
the Wizard, pick a portal whose **Discovery Auth Method** is set
to CHAP, and configure an entry under the manual flow's
**Authorized Access** tab (user + 12-16 character secret). In
Proxmox, add `tn_chap_user` and `tn_chap_password` to the
`storage.cfg` entry.

#### 5. Verify configuration

The plugin takes it from here. On the first VM disk allocation
it will:
- Create zvols under your dataset (e.g.
  `tank/proxmox/vm-100-disk-0`).
- Create an iSCSI extent for each zvol.
- Associate each extent with your target under a per-disk LUN.
- Manage iSCSI session setup/teardown on each Proxmox node.

## Basic Usage

### Create VM with TrueNAS Storage
```bash
# Create VM
qm create 100 --name "test-vm" --memory 2048 --cores 2

# Add disk from TrueNAS storage
qm set 100 --scsi0 truenas-storage:32

# Start VM
qm start 100
```

### Snapshot Operations
```bash
# Create snapshot
qm snapshot 100 backup1 --description "Before updates"

# Create live snapshot (with RAM state)
qm snapshot 100 live1 --vmstate 1

# List snapshots
qm listsnapshot 100

# Rollback to snapshot
qm rollback 100 backup1

# Delete snapshot
qm delsnapshot 100 backup1

# Import snapshots that already exist on TrueNAS into the guest configuration
truenas-proxmox-manage import-snapshots 100 --dry-run
```

### Storage Management
```bash
# Check storage status
pvesm status truenas-storage

# List all volumes
pvesm list truenas-storage

# Check available space
pvesm status
```

### Advanced Installation Options

The installer supports additional features:
- **Version management** - Install, update, or rollback to specific versions
- **Configuration wizard** - Interactive guided setup with validation
- **Health checks** - 13-point system validation supporting both iSCSI and NVMe/TCP with consistent 30-character label formatting
- **Plugin testing** - Integrated 8-test validation of core plugin operations with graceful interrupt handling and health-check style output
- **Cluster support** - Automatic cluster detection and warnings
- **Backup management** - Automatic backups with rollback capability

For detailed installation instructions and troubleshooting, see the [Installation Guide](wiki/Installation.md).

## Documentation

Comprehensive documentation is available in the [Wiki](wiki/):

- **[Installation Guide](wiki/Installation.md)** - Detailed installation steps for both Proxmox and TrueNAS
- **[Packaging Guide](wiki/Packaging.md)** - PACKAGING maintainer workflow for Debian builds, lintian, signing, and APT publishing
- **[Configuration Reference](wiki/Configuration.md)** - Complete parameter reference and examples
- **[Tools and Utilities](wiki/Tools.md)** - Test suite and cluster deployment scripts
- **[Troubleshooting Guide](wiki/Troubleshooting.md)** - Common issues and solutions
- **[Advanced Features](wiki/Advanced-Features.md)** - Performance tuning, clustering, security
- **[API Reference](wiki/API-Reference.md)** - Technical details on TrueNAS API integration
- **[Minimum API Permissions](wiki/API-Permissions.md)** - Least-privilege TrueNAS role set for the API user
- **[NVMe Setup Guide](wiki/NVMe-Setup.md)** - NVMe/TCP transport setup and authentication
- **[Multi-Tenancy](wiki/Multi-Tenancy.md)** - Sharing TrueNAS across multiple Proxmox clusters
- **[Testing Guide](wiki/Testing.md)** - Automated test suite for plugin validation
- **[Known Limitations](wiki/Known-Limitations.md)** - Important limitations and workarounds
- **[Ideas and Roadmap](wiki/Ideas.md)** - Feature ideas and development roadmap
- **[Changelog](wiki/Changelog.md)** - Version history and release notes

## Important: TrueNAS API Changes

**TrueNAS SCALE 25.10+ Required**: This plugin requires TrueNAS SCALE 25.10 or later. WebSocket API is the only supported transport method.

## Requirements

- **Proxmox VE** 8.x or later (9.x recommended)
- **TrueNAS SCALE** 25.10 or later
- Network connectivity between Proxmox nodes and TrueNAS (iSCSI on port 3260, WebSocket API on port 443)

## Support

For issues, questions, or contributions:
- Review the [Troubleshooting Guide](wiki/Troubleshooting.md)
- Check [Known Limitations](wiki/Known-Limitations.md)
- Report bugs or request features at <https://github.com/truenas/truenas-proxmox-plugin/issues>

## License

This project is provided as-is for use with Proxmox VE and TrueNAS SCALE.

---

**Version**: 2.1.23
**Last Updated**: August 5, 2026
**Compatibility**: Proxmox VE 8.x+, TrueNAS SCALE 25.10+
