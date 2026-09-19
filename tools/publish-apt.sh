#!/usr/bin/env bash
#
# publish-apt.sh - build and publish the signed APT repository of the IDKMANAGER
# fork of truenas-proxmox-plugin to the `gh-pages` branch of the GitHub fork,
# served by GitHub Pages at https://alfonsokuen.github.io/truenas-proxmox-plugin/apt
#
# WHERE IT RUNS
#   On the workstation (Git Bash on Windows, or any Linux box). It needs `gh`,
#   `sops`, `git`, `ssh` and `scp` locally, and orchestrates a throwaway
#   `debian:12` container on the Docker host (default IAS03) for the one step
#   that has no Windows equivalent: `reprepro` signing the indices with GnuPG.
#   Nothing persistent is left on that host.
#
# WHY A FULL REBUILD EVERY RUN
#   The reprepro database is not carried across runs, so the repository is
#   rebuilt from every release tag that matches the fork's version scheme
#   (idk15 and up), in ascending order. That is idempotent by construction:
#   re-running publishes the same tree plus whatever new revisions exist, and
#   it can never lose one to a stale database.
#
#   Caveat: reprepro 5.3.1 - what Debian ships in BOTH bookworm and trixie -
#   has no `Limit` field, so a distribution holds exactly one version of a
#   package. The repository therefore serves the newest revision; older ones
#   stay installable from their GitHub release with
#   `install-idk.sh --version idkNN`. When Debian ships reprepro >= 5.4, add
#   `Limit: -1` to the generated conf/distributions to keep them all.
#
# THE SIGNING KEY
#   Lives only in the SOPS vault under `apt_signing_truenas_plugin`. It is
#   decrypted into the container's GNUPGHOME at the start of the run and the
#   whole working directory is wiped on exit (including on failure).
#
# Usage:
#   tools/publish-apt.sh [--no-push] [--tags "idk15 idk16"] [--host root@IP]
#                        [--vault PATH] [--keep]
#
# Exit codes: 0 ok, 1 usage, 2 missing tool / unreachable host, 3 checksum
# verification failed, 4 release download failure, 5 reprepro failure,
# 6 publish (git push) failure.
#
# The remote commands below interpolate $REMOTE_BASE on purpose: the path is
# ours, not the remote shell's, and it must be fixed before ssh sees it.
# shellcheck disable=SC2029
set -euo pipefail

REPO_SLUG="${IDK_GH_REPO:-alfonsokuen/truenas-proxmox-plugin}"
PAGES_URL='https://alfonsokuen.github.io/truenas-proxmox-plugin/apt'
VAULT_DEFAULT="${IDK_VAULT:-$HOME/Nextcloud/Documentos/Claude.md/credentials/credentials.sops.yaml}"
VAULT_KEY='apt_signing_truenas_plugin'
DOCKER_HOST_SSH="${IDK_DOCKER_HOST:-root@190.160.10.143}"
REMOTE_BASE='/root/idk-plugin-apt'
MIN_REVISION=15          # idk15 is the first revision worth serving
SUITES='bookworm trixie'

opt_push=1
opt_keep=0
opt_tags=''
vault="$VAULT_DEFAULT"
workdir=''

log()  { printf '[publish-apt] %s\n' "$*"; }
warn() { printf '[publish-apt] WARNING: %s\n' "$*" >&2; }
die()  { printf '[publish-apt] ERROR: %s\n' "$2" >&2; exit "$1"; }

usage() {
    sed -n '3,30p' "$0"
}

cleanup() {
    if [ "$opt_keep" -eq 1 ]; then
        [ -n "$workdir" ] && log "--keep: leaving $workdir in place"
        return 0
    fi
    [ -n "$workdir" ] && [ -d "$workdir" ] && rm -rf -- "$workdir"
    # The remote side holds a decrypted private key: wipe it even on failure.
    ssh "$DOCKER_HOST_SSH" "rm -rf -- '$REMOTE_BASE/build'" >/dev/null 2>&1 || true
}

while [ $# -gt 0 ]; do
    case "$1" in
        --no-push) opt_push=0 ;;
        --keep)    opt_keep=1 ;;
        --tags)    [ $# -ge 2 ] || die 1 '--tags needs an argument'; opt_tags="$2"; shift ;;
        --host)    [ $# -ge 2 ] || die 1 '--host needs an argument'; DOCKER_HOST_SSH="$2"; shift ;;
        --vault)   [ $# -ge 2 ] || die 1 '--vault needs an argument'; vault="$2"; shift ;;
        -h|--help) usage; exit 0 ;;
        *)         usage >&2; die 1 "unknown option: $1" ;;
    esac
    shift
done

for tool in gh sops git ssh scp sha256sum; do
    command -v "$tool" >/dev/null 2>&1 || die 2 "required tool not found: $tool"
done
[ -f "$vault" ] || die 2 "SOPS vault not found: $vault"
ssh -o ConnectTimeout=15 "$DOCKER_HOST_SSH" 'docker --version >/dev/null' ||
    die 2 "cannot reach docker on $DOCKER_HOST_SSH"

workdir="$(mktemp -d)"
trap cleanup EXIT INT TERM
mkdir -p "$workdir/debs" "$workdir/pages"

# --- 1. which releases to publish ---------------------------------------
if [ -n "$opt_tags" ]; then
    revisions="$opt_tags"
else
    revisions="$(gh release list -R "$REPO_SLUG" --limit 100 --json tagName -q '.[].tagName' |
        sed -n 's/.*+\(idk[0-9]\{1,\}\)$/\1/p' |
        awk -v min="$MIN_REVISION" '{ n = $0; sub(/^idk/, "", n); if (n + 0 >= min) print }' |
        sort -t k -k2 -n)"
fi
[ -n "$revisions" ] || die 4 'no release tags matched the fork version scheme'
log "publishing revisions: $(echo "$revisions" | tr '\n' ' ')"

# --- 2. download every .deb and verify it against its SHA256SUMS ---------
for rev in $revisions; do
    tag="v2.1.23-alpha1+${rev}"
    dir="$workdir/rel/$rev"
    mkdir -p "$dir"
    log "downloading $tag"
    gh release download "$tag" -R "$REPO_SLUG" -D "$dir" --clobber ||
        die 4 "could not download release $tag"
    [ -f "$dir/SHA256SUMS" ] || die 4 "$tag has no SHA256SUMS"

    # GitHub rewrites '~' to '.' in asset names; SHA256SUMS holds the real one.
    original="$(awk 'NF >= 2 && $2 ~ /\.deb$/ { print $2; exit }' "$dir/SHA256SUMS")"
    [ -n "$original" ] || die 4 "$tag: SHA256SUMS lists no .deb"
    served="$(printf '%s' "$original" | tr '~' '.')"
    if [ ! -f "$dir/$original" ] && [ -f "$dir/$served" ]; then
        mv -- "$dir/$served" "$dir/$original"
    fi
    ( cd "$dir" && sha256sum -c --ignore-missing SHA256SUMS ) ||
        die 3 "$tag: checksum verification FAILED"
    cp -- "$dir/$original" "$workdir/debs/$original"
    log "  verified $original"
done

# --- 3. reprepro, in a throwaway debian:12 container ---------------------
fingerprint="$(sops -d --extract "[\"$VAULT_KEY\"][\"fingerprint\"]" "$vault")"
[ -n "$fingerprint" ] || die 2 "no fingerprint under $VAULT_KEY in the vault"
log "signing with $fingerprint"

mkdir -p "$workdir/conf"
{
    for suite in $SUITES; do
        cat <<EOF
Origin: IDKMANAGER truenas-proxmox-plugin fork
Label: truenas-proxmox-plugin (IDK fork)
Suite: $suite
Codename: $suite
Components: main
Architectures: amd64
SignWith: $fingerprint
Description: IDKMANAGER fork of the TrueNAS Proxmox VE storage plugin ($suite)

EOF
    done
} >"$workdir/conf/distributions"
printf 'verbose\n' >"$workdir/conf/options"

cat >"$workdir/build.sh" <<EOF
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null
apt-get install -y -qq gnupg reprepro >/dev/null
export GNUPGHOME=/build/gnupg
mkdir -p "\$GNUPGHOME"
chmod 700 "\$GNUPGHOME"
gpg --batch --quiet --import /build/signing.asc
printf '%s:6:\n' '$fingerprint' | gpg --batch --import-ownertrust >/dev/null 2>&1
mkdir -p /build/repo/conf
cp /build/conf/distributions /build/conf/options /build/repo/conf/
for suite in $SUITES; do
    for deb in /build/debs/*.deb; do
        reprepro -b /build/repo --ignore=wrongdistribution includedeb "\$suite" "\$deb"
    done
done
rm -rf /build/repo/db /build/repo/conf
chmod -R a+rX /build/repo
EOF

# The private key never touches disk outside the working directory, and the
# working directory is wiped by the EXIT trap.
sops -d --extract "[\"$VAULT_KEY\"][\"private_key_asc\"]" "$vault" >"$workdir/signing.asc"
chmod 600 "$workdir/signing.asc"

log "shipping the build to $DOCKER_HOST_SSH"
ssh "$DOCKER_HOST_SSH" "rm -rf -- '$REMOTE_BASE/build' && mkdir -p '$REMOTE_BASE/build'"
scp -q -r "$workdir/debs" "$workdir/conf" "$workdir/build.sh" "$workdir/signing.asc" \
    "$DOCKER_HOST_SSH:$REMOTE_BASE/build/"
rm -f "$workdir/signing.asc"

ssh "$DOCKER_HOST_SSH" \
    "docker run --rm -v '$REMOTE_BASE/build':/build -w /build debian:12 bash /build/build.sh" ||
    die 5 'reprepro failed'
ssh "$DOCKER_HOST_SSH" "rm -f -- '$REMOTE_BASE/build/signing.asc'"

log 'fetching the built repository'
scp -q -r "$DOCKER_HOST_SSH:$REMOTE_BASE/build/repo/dists" "$workdir/pages/" ||
    die 5 'could not fetch dists/'
scp -q -r "$DOCKER_HOST_SSH:$REMOTE_BASE/build/repo/pool" "$workdir/pages/" ||
    die 5 'could not fetch pool/'
ssh "$DOCKER_HOST_SSH" "rm -rf -- '$REMOTE_BASE/build'"

# --- 4. assemble the gh-pages tree --------------------------------------
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
site="$workdir/site"
mkdir -p "$site/apt"
cp -r "$workdir/pages/dists" "$workdir/pages/pool" "$site/apt/"
cp "$repo_root/apt/KEY.gpg" "$repo_root/apt/KEY.asc" "$site/apt/"
: >"$site/.nojekyll"
sed -e "s|@PAGES_URL@|$PAGES_URL|g" -e "s|@FINGERPRINT@|$fingerprint|g" \
    "$repo_root/apt/index.html.in" >"$site/index.html"
cp "$site/index.html" "$site/apt/index.html"

if [ "$opt_push" -eq 0 ]; then
    opt_keep=1
    log "--no-push: the site is ready at $site"
    exit 0
fi

# --- 5. publish to the orphan gh-pages branch ---------------------------
push_url="$(git -C "$repo_root" remote get-url github)"
(
    cd "$site"
    git init -q -b gh-pages
    git add -A
    git -c user.name='Alfonso Kuen' -c user.email='gerencia@idkmanager.com' commit -q -m \
"apt: publish the IDK fork repository, replacing upstream's gh-pages copy

This branch used to be a copy of upstream's GitHub Pages site, serving
upstream's 2.1.17+deb1 package signed with upstream's key. It is replaced
wholesale: the packages are the fork's idk releases (epoch 1:, so they win
over upstream's on a node that has both sources) and the indices are signed
with the IDKMANAGER key $fingerprint.

Built by tools/publish-apt.sh.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
    # `git push` on this workstation sometimes dies with "getaddrinfo() thread
    # failed to start"; pinning the address through curl's resolver sidesteps
    # the thread-starved resolver without disabling TLS verification.
    if ! git push -q --force "$push_url" gh-pages:gh-pages; then
        warn 'plain push failed, retrying with a pinned resolver'
        git -c http.curloptResolve=github.com:443:140.82.114.4 \
            push -q --force "$push_url" gh-pages:gh-pages
    fi
) || die 6 'could not push gh-pages'

log "published: $PAGES_URL"
log 'GitHub Pages can take a minute to rebuild.'
