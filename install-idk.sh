#!/usr/bin/env bash
#
# install-idk.sh - one-line installer for the IDKMANAGER fork of
# truenas-proxmox-plugin (github.com/alfonsokuen/truenas-proxmox-plugin).
#
#   curl -sSL https://raw.githubusercontent.com/alfonsokuen/truenas-proxmox-plugin/idk-fork/install-idk.sh | bash
#   bash install-idk.sh [--apt] [--version idkNN] [--wizard] [--dry-run]
#
# Two install paths:
#   --apt   configure the fork's signed APT repository and install from it
#           (recommended: `apt-get upgrade` keeps the node current afterwards)
#   default download the release .deb from GitHub, verify its SHA256 and install
#
# Exit codes:
#   0  success (or --dry-run completed all checks)
#   1  usage error (unknown flag, bad --version argument)
#   2  precondition failure (not root, not a Proxmox VE node, missing tool)
#   3  checksum verification failed - nothing was installed
#   4  release discovery or download failure
#   5  installation failure (apt-get/dpkg returned non-zero)
#
# Environment overrides (used by the offline test suite, t/installer):
#   IDK_GH_API_BASE   GitHub API base            (default https://api.github.com)
#   IDK_GH_REPO       owner/repo to install from (default alfonsokuen/truenas-proxmox-plugin)
#   IDK_DOWNLOAD_BASE if set, release assets are fetched from this base URL
#                     instead of the browser_download_url returned by the API
#   IDK_APT_BASE_URL  APT repository base        (default the fork's GitHub Pages site)
#
set -euo pipefail

PKG_NAME='truenas-proxmox-plugin'
BASE_VERSION='2.1.23-alpha1'
GH_API_BASE="${IDK_GH_API_BASE:-https://api.github.com}"
GH_REPO="${IDK_GH_REPO:-alfonsokuen/truenas-proxmox-plugin}"
DOWNLOAD_BASE="${IDK_DOWNLOAD_BASE:-}"
APT_BASE_URL="${IDK_APT_BASE_URL:-https://alfonsokuen.github.io/truenas-proxmox-plugin/apt}"
APT_SOURCES_FILE='/etc/apt/sources.list.d/truenas-proxmox-plugin-idk.sources'
APT_KEYRING_FILE='/usr/share/keyrings/truenas-proxmox-plugin-idk.gpg'
SERVICES='truenas-plugin-broker pvedaemon pvestatd pveproxy'

opt_version=''
opt_wizard=0
opt_dry_run=0
opt_apt=0
workdir=''

log()  { printf '[install-idk] %s\n' "$*"; }
warn() { printf '[install-idk] WARNING: %s\n' "$*" >&2; }
die()  { printf '[install-idk] ERROR: %s\n' "$2" >&2; exit "$1"; }

usage() {
    cat <<'EOF'
Usage: install-idk.sh [OPTIONS]

  --apt              Configure the fork's signed APT repository and install from
                     it. Recommended: later upgrades come with `apt-get upgrade`.
  --version idkNN    Install a specific fork revision (for example --version idk18).
                     Default: the latest published release.
  --wizard           Run `truenas-proxmox-manage` when the install finishes.
  --dry-run          Perform every check and download, but do not install.
  -h, --help         Show this help.

Exit codes: 0 ok, 1 usage, 2 precondition, 3 bad checksum, 4 download, 5 install.
EOF
}

cleanup() {
    if [ -n "$workdir" ] && [ -d "$workdir" ]; then
        rm -rf -- "$workdir"
    fi
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --apt)      opt_apt=1 ;;
            --wizard)   opt_wizard=1 ;;
            --dry-run)  opt_dry_run=1 ;;
            --version)
                [ $# -ge 2 ] || die 1 '--version needs an argument, e.g. --version idk18'
                opt_version="$2"
                shift
                ;;
            --version=*) opt_version="${1#--version=}" ;;
            -h|--help)  usage; exit 0 ;;
            *)          usage >&2; die 1 "unknown option: $1" ;;
        esac
        shift
    done

    if [ -n "$opt_version" ]; then
        case "$opt_version" in
            idk[0-9]|idk[0-9][0-9]|idk[0-9][0-9][0-9]) : ;;
            *) die 1 "--version expects idkNN (got '$opt_version')" ;;
        esac
    fi
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        die 2 'this installer must run as root (try: sudo bash install-idk.sh)'
    fi
}

require_proxmox() {
    if ! command -v dpkg-query >/dev/null 2>&1; then
        die 2 'dpkg-query not found: this is not a Debian-based system'
    fi
    if ! dpkg-query -W -f='${Status}' pve-manager 2>/dev/null | grep -q 'install ok installed'; then
        die 2 'pve-manager is not installed: this installer only runs on a Proxmox VE node'
    fi
}

require_tools() {
    local tool
    for tool in apt-get curl sha256sum; do
        command -v "$tool" >/dev/null 2>&1 || die 2 "required tool not found: $tool"
    done
}

warn_upstream_repo() {
    local found=0 f
    for f in /etc/apt/sources.list.d/*truenas*; do
        [ -f "$f" ] || continue
        if grep -qs 'truenas\.github\.io' "$f"; then
            warn "upstream APT repository found in $f"
            found=1
        fi
    done
    if [ "$found" -eq 1 ]; then
        warn "the fork's package carries epoch '1:' so it wins over upstream's;"
        warn 'leaving the upstream source in place and continuing.'
    fi
}

installed_version() {
    dpkg-query -W -f='${Version}' "$PKG_NAME" 2>/dev/null || true
}

http_get() {
    # $1 url, $2 destination file
    curl -fsSL --retry 2 --connect-timeout 20 -o "$2" -- "$1"
}

release_json() {
    local url
    if [ -n "$opt_version" ]; then
        # GitHub's tag endpoint needs the '+' of the tag percent-encoded.
        url="${GH_API_BASE}/repos/${GH_REPO}/releases/tags/v${BASE_VERSION}%2B${opt_version}"
    else
        url="${GH_API_BASE}/repos/${GH_REPO}/releases/latest"
    fi
    log "querying release: $url"
    http_get "$url" "$workdir/release.json" ||
        die 4 "could not fetch release metadata from $url"
}

json_strings() {
    # $1 key, $2 file. Emits one value per line. GitHub never puts a comma
    # inside these values, so splitting on commas is enough and avoids jq
    # (which Proxmox nodes do not ship).
    tr ',' '\n' <"$2" |
        sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}

asset_url() {
    # $1 = basename pattern to match at the end of the URL
    json_strings browser_download_url "$workdir/release.json" | grep -- "$1" | head -n1
}

rebase_url() {
    # Honour IDK_DOWNLOAD_BASE by keeping only the asset's file name.
    local url="$1"
    if [ -n "$DOWNLOAD_BASE" ]; then
        printf '%s/%s\n' "${DOWNLOAD_BASE%/}" "${url##*/}"
    else
        printf '%s\n' "$url"
    fi
}

show_state() {
    local svc state
    log "installed package: $(dpkg-query -W "$PKG_NAME" 2>/dev/null || echo 'not installed')"
    for svc in $SERVICES; do
        state="$(systemctl is-active "$svc" 2>/dev/null || true)"
        log "service ${svc}: ${state:-unknown}"
    done
}

run_wizard() {
    if [ "$opt_wizard" -ne 1 ]; then
        return 0
    fi
    if [ "$opt_dry_run" -eq 1 ]; then
        log '--dry-run: skipping the storage wizard'
        return 0
    fi
    if ! command -v truenas-proxmox-manage >/dev/null 2>&1; then
        warn 'truenas-proxmox-manage not found; skipping the wizard'
        return 0
    fi
    log 'launching truenas-proxmox-manage'
    truenas-proxmox-manage
}

apt_suite() {
    local major codename
    major="$(dpkg-query -W -f='${Version}' pve-manager 2>/dev/null | sed -n 's/^\([0-9]*\).*/\1/p')"
    case "$major" in
        8) printf 'bookworm\n'; return 0 ;;
        9) printf 'trixie\n';   return 0 ;;
    esac
    # shellcheck source=/dev/null
    codename="$(. /etc/os-release 2>/dev/null && printf '%s' "${VERSION_CODENAME:-}" || true)"
    case "$codename" in
        bookworm|trixie) printf '%s\n' "$codename" ;;
        *) printf 'trixie\n' ;;
    esac
}

install_from_apt() {
    local suite installed candidate
    suite="$(apt_suite)"
    log "APT mode: suite ${suite}, base ${APT_BASE_URL}"

    if [ "$opt_dry_run" -eq 1 ]; then
        log "--dry-run: would write $APT_KEYRING_FILE from ${APT_BASE_URL}/KEY.gpg"
        log "--dry-run: would write $APT_SOURCES_FILE (Suites: ${suite})"
        log '--dry-run: would run apt-get update and install the package'
        show_state
        return 0
    fi

    http_get "${APT_BASE_URL}/KEY.gpg" "$workdir/KEY.gpg" ||
        die 4 "could not download the repository key from ${APT_BASE_URL}/KEY.gpg"
    [ -s "$workdir/KEY.gpg" ] || die 4 'the downloaded repository key is empty'
    install -D -m 0644 "$workdir/KEY.gpg" "$APT_KEYRING_FILE"
    log "repository key installed at $APT_KEYRING_FILE"

    mkdir -p /etc/apt/sources.list.d
    cat >"$APT_SOURCES_FILE" <<EOF
# IDKMANAGER fork of truenas-proxmox-plugin - written by install-idk.sh
Types: deb
URIs: ${APT_BASE_URL}/
Suites: ${suite}
Components: main
Architectures: amd64
Signed-By: ${APT_KEYRING_FILE}
EOF
    log "APT source written to $APT_SOURCES_FILE"

    apt-get update || die 5 'apt-get update failed'

    # A negative pin makes apt report "has no installation candidate", which
    # says nothing about why. Nodes running this fork often carry exactly such
    # a pin, put there to stop a routine upgrade from pulling upstream's build.
    if command -v apt-cache >/dev/null 2>&1; then
        candidate="$(apt-cache policy "$PKG_NAME" 2>/dev/null | sed -n 's/^ *Candidate: *//p')"
        if [ -z "$candidate" ] || [ "$candidate" = '(none)' ]; then
            warn "APT has no installation candidate for $PKG_NAME."
            warn 'A negative pin is the usual cause: look in /etc/apt/preferences.d/'
            warn "for a 'Pin: release *' entry with Pin-Priority below 0 on this"
            warn "package, and narrow it to upstream's origin (truenas.github.io)."
            die 5 'the repository is configured but the package is pinned out'
        fi
        log "repository candidate: $candidate"
    fi

    installed="$(installed_version)"
    if [ -n "$installed" ]; then
        log "package already installed ($installed): reinstalling from the repository"
        apt-get install --reinstall -y "$PKG_NAME" || die 5 'apt-get install --reinstall failed'
    else
        apt-get install -y "$PKG_NAME" || die 5 'apt-get install failed'
    fi

    show_state
    run_wizard
}

install_from_release() {
    local sums_url deb_url deb_name installed deb_version

    release_json

    sums_url="$(asset_url 'SHA256SUMS')"
    [ -n "$sums_url" ] || die 4 'the release has no SHA256SUMS asset'
    deb_url="$(asset_url '_all.deb')"
    [ -n "$deb_url" ] || die 4 'the release has no .deb asset'

    http_get "$(rebase_url "$sums_url")" "$workdir/SHA256SUMS" ||
        die 4 'could not download SHA256SUMS'

    # GitHub rewrites '~' to '.' in asset names, so the served file name does
    # not match SHA256SUMS. The checksum file holds the authoritative name.
    deb_name="$(awk 'NF >= 2 && $2 ~ /\.deb$/ { print $2; exit }' "$workdir/SHA256SUMS")"
    [ -n "$deb_name" ] || die 4 'SHA256SUMS does not list a .deb file'
    log "release asset: ${deb_url##*/}"
    log "verified name: $deb_name"

    http_get "$(rebase_url "$deb_url")" "$workdir/$deb_name" ||
        die 4 'could not download the package'

    log 'verifying SHA256'
    if ! ( cd "$workdir" && sha256sum -c --ignore-missing SHA256SUMS ); then
        die 3 'checksum verification FAILED - the package was NOT installed'
    fi

    if [ "$opt_dry_run" -eq 1 ]; then
        log '--dry-run: checksum OK, skipping the installation'
        show_state
        return 0
    fi

    installed="$(installed_version)"
    deb_version="$(dpkg-deb -f "$workdir/$deb_name" Version 2>/dev/null || true)"
    if [ -n "$installed" ] && [ -n "$deb_version" ] && [ "$installed" = "$deb_version" ]; then
        log "version $installed already installed: reinstalling"
        apt-get install --reinstall -y "$workdir/$deb_name" || die 5 'apt-get reinstall failed'
    else
        apt-get install -y "$workdir/$deb_name" || die 5 'apt-get install failed'
    fi

    show_state
    run_wizard
}

main() {
    parse_args "$@"
    require_root
    require_proxmox
    require_tools
    warn_upstream_repo

    workdir="$(mktemp -d)"
    trap cleanup EXIT INT TERM

    if [ "$opt_apt" -eq 1 ]; then
        install_from_apt
    else
        install_from_release
    fi

    if [ "$opt_dry_run" -eq 1 ]; then
        log 'dry run complete: nothing was installed.'
    else
        log 'done.'
    fi
}

main "$@"
