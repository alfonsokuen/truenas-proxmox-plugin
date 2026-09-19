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
#   0    success (or --dry-run completed all checks)
#   1    usage error (unknown flag, bad --version argument)
#   2    precondition failure (not root, not a Proxmox VE node, missing tool)
#   3    verification failed (checksum, asset name, repository key) - nothing
#        was installed
#   4    release discovery or download failure
#   5    installation failure (apt-get/dpkg, or a repository that does not
#        offer the fork's package)
#   130  interrupted (SIGINT)
#   143  terminated (SIGTERM)
#
# Environment overrides (used by the offline test suite, t/installer):
#   IDK_GH_API_BASE   GitHub API base            (default https://api.github.com)
#   IDK_GH_REPO       owner/repo to install from (default alfonsokuen/truenas-proxmox-plugin)
#   IDK_DOWNLOAD_BASE if set, release assets are fetched from this base URL
#                     instead of the browser_download_url returned by the API
#   IDK_APT_BASE_URL  APT repository base        (default the fork's GitHub Pages site)
#   IDK_APT_KEY_FPR   expected fingerprint of the repository signing key
#   IDK_APT_EXPECTED_HOST  origin apt must report for the candidate
#   IDK_APT_SOURCES_FILE / IDK_APT_KEYRING_FILE  where --apt writes
#
set -euo pipefail

PKG_NAME='truenas-proxmox-plugin'
BASE_VERSION='2.1.23-alpha1'
GH_API_BASE="${IDK_GH_API_BASE:-https://api.github.com}"
GH_REPO="${IDK_GH_REPO:-alfonsokuen/truenas-proxmox-plugin}"
DOWNLOAD_BASE="${IDK_DOWNLOAD_BASE:-}"
APT_BASE_URL="${IDK_APT_BASE_URL:-https://alfonsokuen.github.io/truenas-proxmox-plugin/apt}"
APT_KEY_FPR="${IDK_APT_KEY_FPR:-1B44882462A1200EFFCFAEFC79E67ECFB42EE1CC}"
APT_SOURCES_FILE="${IDK_APT_SOURCES_FILE:-/etc/apt/sources.list.d/truenas-proxmox-plugin-idk.sources}"
APT_KEYRING_FILE="${IDK_APT_KEYRING_FILE:-/usr/share/keyrings/truenas-proxmox-plugin-idk.gpg}"
SERVICES='truenas-plugin-broker pvedaemon pvestatd pveproxy'

# The only package name this installer will ever write to disk or hand to apt.
# The name comes out of a downloaded SHA256SUMS, so it is attacker-controlled
# input to a path used as root: '../../something.deb' passes a naive parse.
DEB_NAME_RE='^truenas-proxmox-plugin_[A-Za-z0-9.~+]+_all\.deb$'

opt_version=''
opt_wizard=0
opt_dry_run=0
opt_apt=0
opt_allow_downgrade=0
workdir=''

log()  { printf '[install-idk] %s\n' "$*"; }
warn() { printf '[install-idk] WARNING: %s\n' "$*" >&2; }
die()  { printf '[install-idk] ERROR: %s\n' "$2" >&2; exit "$1"; }

usage() {
    cat <<'EOF'
Usage: install-idk.sh [OPTIONS]

  --apt               Configure the fork's signed APT repository and install
                      from it. Recommended: later upgrades come with
                      `apt-get upgrade`. Always installs the newest revision.
  --version idkNN     Install a specific fork revision (e.g. --version idk18).
                      Default: the latest release. Not valid with --apt.
  --allow-downgrade   Permit installing a revision older than the installed one.
  --wizard            Run `truenas-proxmox-manage` when the install finishes.
  --dry-run           Perform every check and download, but install nothing.
  -h, --help          Show this help.

Exit codes: 0 ok, 1 usage, 2 precondition, 3 verification failed, 4 download,
5 install, 130/143 interrupted.
EOF
}

cleanup() {
    if [ -n "$workdir" ] && [ -d "$workdir" ]; then
        rm -rf -- "$workdir"
    fi
    workdir=''
}
on_int()  { cleanup; exit 130; }
on_term() { cleanup; exit 143; }

parse_args() {
    local version_given=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --apt)             opt_apt=1 ;;
            --wizard)          opt_wizard=1 ;;
            --dry-run)         opt_dry_run=1 ;;
            --allow-downgrade) opt_allow_downgrade=1 ;;
            --version)
                [ $# -ge 2 ] || die 1 '--version needs an argument, e.g. --version idk18'
                opt_version="$2"
                version_given=1
                shift
                ;;
            --version=*) opt_version="${1#--version=}"; version_given=1 ;;
            -h|--help)   usage; exit 0 ;;
            *)           usage >&2; die 1 "unknown option: $1" ;;
        esac
        shift
    done

    # An empty --version is a typo, not "use the default": quietly installing
    # something other than what was asked for is how the wrong build ships.
    if [ "$version_given" -eq 1 ] && [ -z "$opt_version" ]; then
        die 1 '--version is empty; pass a revision, e.g. --version idk18'
    fi
    if [ -n "$opt_version" ]; then
        case "$opt_version" in
            idk[0-9]|idk[0-9][0-9]|idk[0-9][0-9][0-9]) : ;;
            *) die 1 "--version expects idkNN (got '$opt_version')" ;;
        esac
    fi
}

check_option_combination() {
    if [ "$opt_apt" -eq 1 ] && [ -n "$opt_version" ]; then
        die 1 "--apt and --version are mutually exclusive: the APT repository serves only the newest revision (reprepro keeps one version per suite). Install idkNN with '--version $opt_version' alone, or take the newest with --apt."
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
    if [ "$opt_apt" -eq 1 ]; then
        for tool in gpg apt-cache; do
            command -v "$tool" >/dev/null 2>&1 ||
                die 2 "required tool not found: $tool (needed to verify the repository key)"
        done
    fi
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

apt_host() {
    # The host apt will report as the origin of the candidate. An empty
    # value would turn the origin check into a no-op that happily accepts
    # upstream's package, so refuse rather than guess.
    local h
    if [ -n "${IDK_APT_EXPECTED_HOST:-}" ]; then
        printf '%s\n' "$IDK_APT_EXPECTED_HOST"
        return 0
    fi
    h="${APT_BASE_URL#*://}"
    h="${h%%/*}"
    [ -n "$h" ] ||
        die 2 'IDK_APT_BASE_URL carries no host; set IDK_APT_EXPECTED_HOST to the origin apt will report'
    printf '%s\n' "$h"
}

# --- release metadata ----------------------------------------------------

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

parse_assets() {
    # Writes "<asset name><TAB><url>" lines to $workdir/assets.tsv.
    #
    # The API can answer with something that is not a release: an HTML error
    # page served with 200, a rate-limit body, a proxy's login form. A grep
    # for browser_download_url finds nothing there, and under `set -e` a
    # pipeline ending in a failed grep kills the script with no message at
    # all - the `die 4` below would never run. So: refuse a payload that is
    # not a JSON object outright, parse it with python3 when there is a
    # working one (every Proxmox node has it), and keep a grep fallback that
    # cannot abort the shell.
    local first
    first="$(head -c 512 "$workdir/release.json" | tr -d '[:space:]' | cut -c1)"
    if [ "$first" != '{' ]; then
        die 4 "the release endpoint did not return a release (an HTML error page or a rate-limit body?): $GH_API_BASE"
    fi

    : >"$workdir/assets.tsv"
    rm -f "$workdir/py.status"
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$workdir/release.json" "$workdir/assets.tsv" "$workdir/py.status" <<'PY' || true
import json, sys

src, dest, status = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(src, 'rb') as fh:
        data = json.load(fh)
    if not isinstance(data, dict):
        raise ValueError('not a release object')
except Exception as exc:
    with open(status, 'w') as fh:
        fh.write('bad: %s\n' % exc)
    raise SystemExit(0)
with open(dest, 'w') as out:
    for asset in data.get('assets') or []:
        name = asset.get('name')
        url = asset.get('browser_download_url')
        if name and url:
            out.write('%s\t%s\n' % (name, url))
with open(status, 'w') as fh:
    fh.write('ok\n')
PY
    fi

    # No status file means python3 was not usable at all (a Windows Store
    # stub, a broken interpreter): fall back rather than guess.
    if [ -f "$workdir/py.status" ]; then
        grep -q '^ok$' "$workdir/py.status" ||
            die 4 "the release endpoint did not return a release (an HTML error page or a rate-limit body?): $GH_API_BASE"
    else
        tr ',' '\n' <"$workdir/release.json" |
            sed -n 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' |
            while IFS= read -r url; do
                printf '%s\t%s\n' "${url##*/}" "$url"
            done >"$workdir/assets.tsv" || true
    fi

    [ -s "$workdir/assets.tsv" ] ||
        die 4 'the release carries no downloadable assets'
}

asset_url_exact() {
    awk -F'\t' -v n="$1" '$1 == n { print $2; exit }' "$workdir/assets.tsv"
}

asset_url_deb() {
    # GitHub rewrites '~' to '.' in asset names, so match on the suffix.
    awk -F'\t' '$1 ~ /_all\.deb$/ { print $2; exit }' "$workdir/assets.tsv"
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

# --- verification --------------------------------------------------------

sums_line_for() {
    # $1 = expected basename. Prints "<hash> <name>" for the line whose file
    # name is EXACTLY that basename, and nothing otherwise.
    awk -v want="$1" '
        NF >= 2 && $2 == want { print $1 " " $2; found = 1; exit }
        END { if (!found) exit 0 }
    ' "$workdir/SHA256SUMS"
}

deb_name_from_sums() {
    awk '
        NF >= 2 && $2 ~ /\.deb$/ { print $2; exit }
    ' "$workdir/SHA256SUMS"
}

valid_deb_name() {
    printf '%s' "$1" | grep -qE "$DEB_NAME_RE"
}

verify_sha256() {
    # $1 = file inside $workdir, $2 = expected hash. No --ignore-missing:
    # `sha256sum -c --ignore-missing` exits 0 when the manifest happens not to
    # list the file at all, which turns "unverified" into "verified".
    local actual
    actual="$(sha256sum "$workdir/$1" | awk '{ print $1 }')"
    if [ "$actual" != "$2" ]; then
        warn "expected $2"
        warn "computed $actual"
        return 1
    fi
    log "sha256 OK: $1"
    return 0
}

# --- shared tail ---------------------------------------------------------

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

# --- APT path ------------------------------------------------------------

fetch_and_verify_key() {
    # $1 = destination file for the dearmored key
    local fprs
    http_get "${APT_BASE_URL}/KEY.gpg" "$1" ||
        die 4 "could not download the repository key from ${APT_BASE_URL}/KEY.gpg"
    [ -s "$1" ] || die 3 'the downloaded repository key is empty'

    # "Not empty" is not a check. Anything that can replace the key file can
    # also make it non-empty, and apt would then trust whatever signed the
    # indices. Pin the fingerprint this script was shipped with.
    # gpg refuses to start when GNUPGHOME does not exist, so create it: a
    # throwaway home keeps this out of root's real keyring.
    mkdir -p "$workdir/gnupg"
    chmod 700 "$workdir/gnupg"
    fprs="$(GNUPGHOME="$workdir/gnupg" gpg --show-keys --with-colons "$1" 2>/dev/null |
        awk -F: '$1 == "fpr" { print $10 }' || true)"
    if ! printf '%s\n' "$fprs" | grep -qx "$APT_KEY_FPR"; then
        warn "expected fingerprint $APT_KEY_FPR"
        warn "key file offers: ${fprs:-<none: not an OpenPGP key>}"
        die 3 'the repository key does not match the fingerprint this installer pins'
    fi
    log "repository key fingerprint verified: $APT_KEY_FPR"
}

write_sources_file() {
    # $1 = destination path, $2 = suite, $3 = keyring path
    cat >"$1" <<EOF
# IDKMANAGER fork of truenas-proxmox-plugin - written by install-idk.sh
Types: deb
URIs: ${APT_BASE_URL}/
Suites: ${2}
Components: main
Architectures: amd64
Signed-By: ${3}
EOF
}

apt_update_strict() {
    # Runs apt-get update with the given extra options and refuses to continue
    # when OUR repository is the one that failed. Plain `apt-get update` exits
    # 0 with a warning in that case, and the install then proceeds against a
    # stale index - or against upstream's.
    local host log_file
    host="$(apt_host)"
    log_file="$workdir/apt-update.log"
    set +e
    apt-get update "$@" 2>&1 | tee "$log_file"
    local rc=${PIPESTATUS[0]}
    set -e
    [ "$rc" -eq 0 ] || die 5 'apt-get update failed'
    if grep -qE "^(Err|E):.*${host}" "$log_file"; then
        grep -E "^(Err|E|W):.*${host}" "$log_file" >&2 || true
        die 5 "apt-get update could not use the fork repository at ${host}"
    fi
}

candidate_version() {
    LC_ALL=C apt-cache "$@" policy "$PKG_NAME" 2>/dev/null |
        sed -n 's/^[[:space:]]*Candidate:[[:space:]]*//p' | head -n1
}

candidate_origins() {
    # Prints the origin of each entry under the candidate version block.
    local cand="$1"
    shift
    LC_ALL=C apt-cache "$@" policy "$PKG_NAME" 2>/dev/null | awk -v cand="$cand" '
        {
            line = $0
            sub(/^[ \t]*/, "", line)
            sub(/^\*\*\*[ \t]*/, "", line)
            n = split(line, f, /[ \t]+/)
            if (n >= 2 && f[2] ~ /^(https?:|ftp:|file:|\/)/) {
                if (inblock) print f[2]
                next
            }
            inblock = (n >= 2 && f[1] == cand && f[2] ~ /^[0-9]+$/)
        }
    '
}

assert_candidate_is_ours() {
    # $@ = extra apt-cache options (used by --dry-run's sandbox)
    local cand origins host
    host="$(apt_host)"
    cand="$(candidate_version "$@")"
    if [ -z "$cand" ] || [ "$cand" = '(none)' ]; then
        warn "APT has no installation candidate for $PKG_NAME."
        warn 'A negative pin is the usual cause: look in /etc/apt/preferences.d/'
        warn "for a 'Pin: release *' entry with Pin-Priority below 0 on this"
        warn "package, and narrow it to upstream's origin (truenas.github.io)."
        die 5 'the repository is configured but the package is pinned out'
    fi
    origins="$(candidate_origins "$cand" "$@")"
    if ! printf '%s\n' "$origins" | grep -qF "$host"; then
        warn "candidate $cand comes from: ${origins:-<unknown>}"
        warn "expected an origin on $host"
        die 5 "the installation candidate is NOT the fork's package; refusing to install"
    fi
    case "$cand" in
        1:*) : ;;
        *)
            warn "candidate $cand carries no epoch"
            die 5 "the candidate does not look like a fork build (epoch '1:' missing)"
            ;;
    esac
    log "repository candidate: $cand (from $host)"
}

apt_dry_run() {
    # Everything --apt does, against a throwaway APT state: the real
    # sources.list.d, keyring and lists are untouched, but the key, the
    # signature and the candidate are all genuinely checked.
    local suite sandbox
    suite="$1"
    sandbox="$workdir/apt-sandbox"
    mkdir -p "$sandbox/sources.list.d" "$sandbox/lists/partial" "$sandbox/archives/partial"

    fetch_and_verify_key "$sandbox/KEY.gpg"
    write_sources_file "$sandbox/sources.list.d/truenas-proxmox-plugin-idk.sources" \
        "$suite" "$sandbox/KEY.gpg"

    log '--dry-run: refreshing the fork repository into a temporary APT state'
    local opts
    opts=(-o "Dir::Etc::sourcelist=/dev/null"
          -o "Dir::Etc::sourceparts=$sandbox/sources.list.d"
          -o "Dir::State::lists=$sandbox/lists"
          -o "Dir::Cache::archives=$sandbox/archives"
          -o "APT::Get::List-Cleanup=0"
          # the sandbox lives in a root-only tmpdir that _apt cannot read;
          # dropping privileges there only produces a warning about itself.
          -o "APT::Sandbox::User=root")
    apt_update_strict "${opts[@]}"
    assert_candidate_is_ours -o "Dir::State::lists=$sandbox/lists" \
        -o "Dir::Etc::sourcelist=/dev/null" \
        -o "Dir::Etc::sourceparts=$sandbox/sources.list.d"

    log "--dry-run: would write $APT_KEYRING_FILE and $APT_SOURCES_FILE"
    log '--dry-run: would install the candidate above; nothing was changed'
    show_state
}

install_from_apt() {
    local suite installed
    suite="$(apt_suite)"
    log "APT mode: suite ${suite}, base ${APT_BASE_URL}"

    if [ "$opt_dry_run" -eq 1 ]; then
        apt_dry_run "$suite"
        return 0
    fi

    fetch_and_verify_key "$workdir/KEY.gpg"
    install -D -m 0644 "$workdir/KEY.gpg" "$APT_KEYRING_FILE"
    log "repository key installed at $APT_KEYRING_FILE"

    mkdir -p "$(dirname "$APT_SOURCES_FILE")"
    write_sources_file "$APT_SOURCES_FILE" "$suite" "$APT_KEYRING_FILE"
    log "APT source written to $APT_SOURCES_FILE"

    apt_update_strict
    assert_candidate_is_ours

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

# --- release .deb path ---------------------------------------------------

install_from_release() {
    local sums_url deb_url deb_name served_name line expected_hash
    local installed deb_version
    local apt_args

    release_json
    parse_assets

    sums_url="$(asset_url_exact 'SHA256SUMS')"
    [ -n "$sums_url" ] || die 4 'the release has no SHA256SUMS asset'
    deb_url="$(asset_url_deb)"
    [ -n "$deb_url" ] || die 4 'the release has no .deb asset'

    http_get "$(rebase_url "$sums_url")" "$workdir/SHA256SUMS" ||
        die 4 'could not download SHA256SUMS'

    # GitHub rewrites '~' to '.' in asset names, so the served file name does
    # not match SHA256SUMS. The checksum file holds the authoritative name -
    # and, being downloaded, is also untrusted input to a path used as root.
    deb_name="$(deb_name_from_sums)"
    [ -n "$deb_name" ] || die 4 'SHA256SUMS does not list a .deb file'
    valid_deb_name "$deb_name" ||
        die 3 "SHA256SUMS names a file this installer will not write: '$deb_name'"

    served_name="${deb_url##*/}"
    log "release asset: $served_name"
    log "verified name: $deb_name"

    line="$(sums_line_for "$deb_name")"
    [ -n "$line" ] || die 3 "SHA256SUMS has no line for $deb_name"
    expected_hash="${line%% *}"
    printf '%s' "$expected_hash" | grep -qE '^[0-9a-f]{64}$' ||
        die 3 "SHA256SUMS holds no usable digest for $deb_name"

    http_get "$(rebase_url "$deb_url")" "$workdir/$deb_name" ||
        die 4 'could not download the package'

    log 'verifying SHA256'
    verify_sha256 "$deb_name" "$expected_hash" ||
        die 3 'checksum verification FAILED - the package was NOT installed'

    if [ "$opt_dry_run" -eq 1 ]; then
        log '--dry-run: checksum OK, skipping the installation'
        show_state
        return 0
    fi

    installed="$(installed_version)"
    deb_version="$(dpkg-deb -f "$workdir/$deb_name" Version 2>/dev/null || true)"
    apt_args=(install -y)

    if [ -n "$installed" ] && [ -n "$deb_version" ]; then
        if [ "$installed" = "$deb_version" ]; then
            log "version $installed already installed: reinstalling"
            apt_args=(install --reinstall -y)
        elif dpkg --compare-versions "$deb_version" lt "$installed"; then
            if [ "$opt_allow_downgrade" -ne 1 ]; then
                warn "installed: $installed"
                warn "requested: $deb_version"
                die 1 'that is a downgrade; re-run with --allow-downgrade if you mean it'
            fi
            warn "downgrading $installed -> $deb_version (--allow-downgrade)"
            apt_args=(install -y --allow-downgrades)
        fi
    fi

    apt-get "${apt_args[@]}" "$workdir/$deb_name" || die 5 'apt-get install failed'

    show_state
    run_wizard
}

main() {
    parse_args "$@"
    check_option_combination
    require_root
    require_proxmox
    require_tools
    warn_upstream_repo

    workdir="$(mktemp -d)"
    trap cleanup EXIT
    trap on_int INT
    trap on_term TERM

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
