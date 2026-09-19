#!/usr/bin/env bash
#
# publish-apt.sh - build and publish the signed APT repository of the IDKMANAGER
# fork of truenas-proxmox-plugin to the `gh-pages` branch of the GitHub fork,
# served by GitHub Pages.
#
# WHERE IT RUNS
#   On the workstation (Git Bash on Windows, or any Linux box). It needs `gh`,
#   `sops`, `git`, `ssh` and `scp` locally, and orchestrates a throwaway
#   `debian:12` container on a Docker host for the one step that has no Windows
#   equivalent: `reprepro` signing the indices with GnuPG.
#
# REQUIRED ENVIRONMENT (no host, path or address is baked into this file)
#   IDK_DOCKER_HOST   ssh destination of the Docker host, e.g. root@docker-host.example
#   IDK_VAULT         path to the SOPS vault holding the signing key
#   IDK_GH_REPO       owner/repo (default: taken from the `github` git remote)
#   IDK_PAGES_URL     public URL of the published repository
#                     (default: https://<owner>.github.io/<repo>/apt)
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
#   Lives only in the SOPS vault. It is streamed to the container over ssh's
#   stdin and imported into a GNUPGHOME on tmpfs, so it is never written to a
#   filesystem on the Docker host - tmpfs pages can still be swapped out by
#   that host's kernel, which is the residual exposure. The remote working
#   directory is removed on exit, including on failure and including with
#   --keep.
#
# Usage:
#   IDK_DOCKER_HOST=root@<host> IDK_VAULT=/path/to/vault.sops.yaml \
#     tools/publish-apt.sh [--no-push] [--tags "idk15 idk16"] [--keep]
#
# Exit codes: 0 ok, 1 usage, 2 missing tool / missing configuration /
# unreachable host, 3 verification failed, 4 release download failure,
# 5 reprepro failure, 6 publish (git push) failure, 130/143 interrupted.
#
# The remote commands below interpolate paths on purpose: they are ours, not
# the remote shell's, and must be fixed before ssh sees them.
# shellcheck disable=SC2029
set -euo pipefail

BASE_VERSION='2.1.23-alpha1'
VAULT_KEY='apt_signing_truenas_plugin'
MIN_REVISION=15          # idk15 is the first revision worth serving
SUITES='bookworm trixie'
DEB_NAME_RE='^truenas-proxmox-plugin_[A-Za-z0-9.~+]+_all\.deb$'

opt_push=1
opt_keep=0
opt_tags=''
workdir=''
remote_dir=''
docker_host=''

log()  { printf '[publish-apt] %s\n' "$*"; }
warn() { printf '[publish-apt] WARNING: %s\n' "$*" >&2; }
die()  { printf '[publish-apt] ERROR: %s\n' "$2" >&2; exit "$1"; }

usage() {
    sed -n '3,50p' "$0"
}

resolve_host() {
    # Some workstations answer every getaddrinfo() in git with "thread failed
    # to start". Resolving out of band and pinning the address through curl's
    # resolver gets around it without weakening TLS. getent is absent on
    # MSYS, and python3 there can be a stub that is not python at all, so try
    # several and accept the first that prints an address.
    local host="$1" ip='' candidate
    ip="$(getent hosts "$host" 2>/dev/null | awk '{ print $1; exit }' || true)"
    if [ -z "$ip" ]; then
        for candidate in python3 python; do
            command -v "$candidate" >/dev/null 2>&1 || continue
            ip="$("$candidate" -c "import socket,sys
try:
    sys.stdout.write(socket.gethostbyname('$host'))
except Exception:
    pass" 2>/dev/null || true)"
            [ -n "$ip" ] && break
        done
    fi
    printf '%s\n' "$ip"
}

git_remote() {
    # git against $push_url, retrying once with a pinned address. Output and
    # exit status are the caller's to inspect; a failure is never swallowed.
    local host ip
    if git "$@"; then
        return 0
    fi
    host="${push_url#*://}"
    host="${host%%/*}"
    host="${host##*@}"
    ip="$(resolve_host "$host")"
    if [ -z "$ip" ]; then
        warn "git failed and $host could not be resolved locally"
        return 1
    fi
    warn "git failed, retrying via $ip"
    git -c "http.curloptResolve=${host}:443:${ip}" "$@"
}

wipe_remote() {
    # Unconditional: the container's working directory holds the built
    # repository and, briefly, a GNUPGHOME. --keep is about the LOCAL tree, it
    # is never a reason to leave ours on someone else's disk. A failure here
    # is reported, never swallowed.
    [ -n "$remote_dir" ] || return 0
    [ -n "$docker_host" ] || return 0
    if ssh -o ConnectTimeout=15 "$docker_host" "rm -rf -- '$remote_dir'" >/dev/null 2>&1; then
        remote_dir=''
        return 0
    fi
    warn "COULD NOT REMOVE the remote working directory."
    warn "Delete it by hand: ssh $docker_host rm -rf $remote_dir"
    return 1
}

cleanup() {
    wipe_remote || true
    if [ "$opt_keep" -eq 1 ]; then
        [ -n "$workdir" ] && log "--keep: leaving $workdir in place"
        return 0
    fi
    [ -n "$workdir" ] && [ -d "$workdir" ] && rm -rf -- "$workdir"
    workdir=''
    return 0
}
on_int()  { cleanup; exit 130; }
on_term() { cleanup; exit 143; }

while [ $# -gt 0 ]; do
    case "$1" in
        --no-push) opt_push=0 ;;
        --keep)    opt_keep=1 ;;
        --tags)    [ $# -ge 2 ] || die 1 '--tags needs an argument'; opt_tags="$2"; shift ;;
        -h|--help) usage; exit 0 ;;
        *)         usage >&2; die 1 "unknown option: $1" ;;
    esac
    shift
done

for tool in gh sops git ssh scp sha256sum awk; do
    command -v "$tool" >/dev/null 2>&1 || die 2 "required tool not found: $tool"
done

docker_host="${IDK_DOCKER_HOST:-}"
vault="${IDK_VAULT:-}"
[ -n "$docker_host" ] ||
    die 2 'IDK_DOCKER_HOST is not set (example: IDK_DOCKER_HOST=root@docker.internal.example)'
[ -n "$vault" ] ||
    die 2 "IDK_VAULT is not set (example: IDK_VAULT=/path/to/credentials.sops.yaml)"
[ -f "$vault" ] || die 2 "SOPS vault not found: $vault"

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
repo_slug="${IDK_GH_REPO:-}"
if [ -z "$repo_slug" ]; then
    repo_slug="$(git -C "$repo_root" remote get-url github 2>/dev/null |
        sed -n 's#.*github[.]com[:/]##p' | sed -e 's#[.]git$##' -e 's#/$##')"
fi
[ -n "$repo_slug" ] ||
    die 2 'cannot tell which GitHub repo to publish; set IDK_GH_REPO=owner/repo'
pages_url="${IDK_PAGES_URL:-https://${repo_slug%%/*}.github.io/${repo_slug#*/}/apt}"

push_url="$(git -C "$repo_root" remote get-url github)"
# Read the tip we intend to replace NOW, not after the build: the lease has to
# cover the whole run, or a gh-pages published while this one was building gets
# discarded by a lease that was taken after it landed.
#
# An ls-remote that FAILED and one that found nothing look the same in a
# variable, and treating the first as "the branch does not exist yet" drops
# the lease and turns the publish into an unguarded push. So check the status.
ls_err="$(mktemp)"
set +e
remote_refs="$(git_remote -C "$repo_root" ls-remote "$push_url" gh-pages 2>"$ls_err")"
ls_rc=$?
set -e
if [ "$ls_rc" -ne 0 ]; then
    cat "$ls_err" >&2
    rm -f "$ls_err"
    die 2 'could not read gh-pages from the remote; refusing to publish without a lease'
fi
rm -f "$ls_err"

# Stderr is kept out of the capture on purpose: git's progress and warnings
# would otherwise end up parsed as a ref. An empty answer means the branch
# does not exist; anything else has to be exactly one ref line.
expected_tip=''
if [ -n "$remote_refs" ]; then
    if ! printf '%s\n' "$remote_refs" |
            grep -qE '^[0-9a-f]{40}[[:space:]]+refs/heads/gh-pages$'; then
        printf '%s\n' "$remote_refs" >&2
        die 2 'unexpected ls-remote output for gh-pages; refusing to publish'
    fi
    expected_tip="$(printf '%s\n' "$remote_refs" | awk '{ print $1; exit }')"
fi
if [ -n "$expected_tip" ]; then
    log "gh-pages is at $expected_tip; that is the tip this run will replace"
else
    log 'gh-pages does not exist on the remote yet'
fi

ssh -o ConnectTimeout=15 "$docker_host" 'docker --version >/dev/null' ||
    die 2 "cannot reach docker on $docker_host"

workdir="$(mktemp -d)"
trap cleanup EXIT
trap on_int INT
trap on_term TERM
mkdir -p "$workdir/debs" "$workdir/pages"

# --- 1. which releases to publish ---------------------------------------
if [ -n "$opt_tags" ]; then
    revisions="$opt_tags"
else
    revisions="$(gh release list -R "$repo_slug" --limit 100 --json tagName -q '.[].tagName' |
        sed -n 's/.*+\(idk[0-9]\{1,\}\)$/\1/p' |
        awk -v min="$MIN_REVISION" '{ n = $0; sub(/^idk/, "", n); if (n + 0 >= min) print }' |
        sort -t k -k2 -n)"
fi
[ -n "$revisions" ] || die 4 'no release tags matched the fork version scheme'
log "publishing revisions: $(echo "$revisions" | tr '\n' ' ')"

# --- 2. download every .deb and verify it against its SHA256SUMS ---------
# The name and the digest both come out of a downloaded manifest, so both are
# untrusted: the name is validated before it is used as a path, and the digest
# is compared explicitly. `sha256sum -c --ignore-missing` is not used - it
# exits 0 when the manifest happens not to cover the file, and a malformed
# digest line is only a warning there.
for rev in $revisions; do
    tag="v${BASE_VERSION}+${rev}"
    dir="$workdir/rel/$rev"
    mkdir -p "$dir"
    log "downloading $tag"
    gh release download "$tag" -R "$repo_slug" -D "$dir" --clobber ||
        die 4 "could not download release $tag"
    [ -f "$dir/SHA256SUMS" ] || die 4 "$tag has no SHA256SUMS"

    original="$(awk 'NF >= 2 && $2 ~ /\.deb$/ { print $2; exit }' "$dir/SHA256SUMS")"
    [ -n "$original" ] || die 4 "$tag: SHA256SUMS lists no .deb"
    printf '%s' "$original" | grep -qE "$DEB_NAME_RE" ||
        die 3 "$tag: SHA256SUMS names a file this script will not handle: '$original'"

    expected="$(awk -v want="$original" 'NF >= 2 && $2 == want { print $1; exit }' "$dir/SHA256SUMS")"
    printf '%s' "$expected" | grep -qE '^[0-9a-f]{64}$' ||
        die 3 "$tag: SHA256SUMS holds no usable digest for $original"

    # GitHub rewrites '~' to '.' in asset names.
    served="$(printf '%s' "$original" | tr '~' '.')"
    if [ ! -f "$dir/$original" ] && [ -f "$dir/$served" ]; then
        mv -- "$dir/$served" "$dir/$original"
    fi
    [ -f "$dir/$original" ] || die 4 "$tag: the release did not carry $served"

    actual="$(sha256sum "$dir/$original" | awk '{ print $1 }')"
    if [ "$actual" != "$expected" ]; then
        warn "expected $expected"
        warn "computed $actual"
        die 3 "$tag: checksum verification FAILED for $original"
    fi
    cp -- "$dir/$original" "$workdir/debs/$original"
    log "  verified $original"
done

# --- 3. reprepro, in a throwaway debian:12 container ---------------------
fingerprint="$(sops -d --extract "[\"$VAULT_KEY\"][\"fingerprint\"]" "$vault")"
printf '%s' "$fingerprint" | grep -qE '^[0-9A-F]{40}$' ||
    die 2 "no usable fingerprint under $VAULT_KEY in the vault"
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

# The key arrives on stdin and stays in the container's memory. GNUPGHOME is a
# tmpfs, not a bind mount, so nothing of it can reach the host's filesystem.
cat >"$workdir/build.sh" <<EOF
set -e
key="\$(cat)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null </dev/null
apt-get install -y -qq gnupg reprepro >/dev/null </dev/null
export GNUPGHOME=/gnupg
chmod 700 "\$GNUPGHOME"
printf '%s\n' "\$key" | gpg --batch --quiet --import
key=''
printf '%s:6:\n' '$fingerprint' | gpg --batch --import-ownertrust >/dev/null 2>&1
gpg --list-secret-keys --with-colons | grep -q '^fpr:*$fingerprint:' ||
    { echo "the signing key did not import" >&2; exit 1; }
mkdir -p /build/repo/conf
cp /build/conf/distributions /build/conf/options /build/repo/conf/
for suite in $SUITES; do
    for deb in /build/debs/*.deb; do
        reprepro -b /build/repo --ignore=wrongdistribution includedeb "\$suite" "\$deb" </dev/null
    done
done
rm -rf /build/repo/db /build/repo/conf
chmod -R a+rX /build/repo
EOF

remote_dir="$(ssh "$docker_host" 'mktemp -d /tmp/idk-apt-XXXXXXXX')"
[ -n "$remote_dir" ] || die 2 'could not create a working directory on the Docker host'
log "shipping the build to $docker_host:$remote_dir"
scp -q -r "$workdir/debs" "$workdir/conf" "$workdir/build.sh" "$docker_host:$remote_dir/"

set +e
sops -d --extract "[\"$VAULT_KEY\"][\"private_key_asc\"]" "$vault" |
    ssh "$docker_host" \
        "docker run --rm -i --tmpfs /gnupg:rw,mode=700,size=32m -v '$remote_dir':/build -w /build debian:12 bash /build/build.sh"
build_rc=("${PIPESTATUS[@]}")
set -e
[ "${build_rc[0]}" -eq 0 ] || die 2 'could not read the signing key from the vault'
[ "${build_rc[1]}" -eq 0 ] || die 5 'reprepro failed'

log 'fetching the built repository'
scp -q -r "$docker_host:$remote_dir/repo/dists" "$workdir/pages/" || die 5 'could not fetch dists/'
scp -q -r "$docker_host:$remote_dir/repo/pool" "$workdir/pages/" || die 5 'could not fetch pool/'
wipe_remote || die 5 'the remote working directory could not be removed'

# --- 4. assemble the gh-pages tree --------------------------------------
site="$workdir/site"
mkdir -p "$site/apt"
cp -r "$workdir/pages/dists" "$workdir/pages/pool" "$site/apt/"
cp "$repo_root/apt/KEY.gpg" "$repo_root/apt/KEY.asc" "$site/apt/"
: >"$site/.nojekyll"
sed -e "s|@PAGES_URL@|$pages_url|g" -e "s|@FINGERPRINT@|$fingerprint|g" \
    -e "s|@REPO_SLUG@|$repo_slug|g" \
    "$repo_root/apt/index.html.in" >"$site/index.html"
cp "$site/index.html" "$site/apt/index.html"

if [ "$opt_push" -eq 0 ]; then
    opt_keep=1
    log "--no-push: the site is ready at $site"
    exit 0
fi

# --- 5. publish to the orphan gh-pages branch ---------------------------
# The lease was taken at the start of the run, on purpose.
if [ -n "$expected_tip" ]; then
    log "replacing gh-pages $expected_tip"
    lease_arg="--force-with-lease=gh-pages:$expected_tip"
else
    log 'creating gh-pages'
    lease_arg=''
fi

(
    cd "$site"
    git init -q -b gh-pages
    git add -A
    git -c user.name='IDKMANAGER release bot' -c user.email='gerencia@idkmanager.com' commit -q -m \
"apt: publish the IDK fork repository, replacing upstream's gh-pages copy

This branch used to be a copy of upstream's GitHub Pages site, serving
upstream's 2.1.17+deb1 package signed with upstream's key. It is replaced
wholesale: the packages are the fork's idk releases (epoch 1:, so they win
over upstream's on a node that has both sources) and the indices are signed
with the IDKMANAGER key $fingerprint.

Built by tools/publish-apt.sh.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"

    git_remote push -q ${lease_arg:+"$lease_arg"} "$push_url" gh-pages:gh-pages
) || die 6 'could not push gh-pages'

log "published: $pages_url"
log 'GitHub Pages can take a minute to rebuild.'

# --- 6. the installer itself, as a release asset -------------------------
# raw.githubusercontent.com serves a cached copy of a branch file for a long
# while - long enough that a node ran the previous revision of this installer
# without anyone noticing. Release assets are not behind that cache, so the
# documented one-line install points at
# .../releases/latest/download/install-idk.sh and this is what keeps it
# current.
newest_rev="$(printf '%s' "$revisions" | tr ' ' '\n' | grep -v '^$' | tail -n1)"
newest_tag="v${BASE_VERSION}+${newest_rev}"
if gh release upload "$newest_tag" "$repo_root/install-idk.sh" -R "$repo_slug" --clobber; then
    log "install-idk.sh uploaded to $newest_tag"
    log "one-line install: https://github.com/$repo_slug/releases/latest/download/install-idk.sh"
else
    warn "could not attach install-idk.sh to $newest_tag; the one-line install"
    warn 'URL will keep serving the previous revision until it is uploaded.'
fi
