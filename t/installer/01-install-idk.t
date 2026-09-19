#!/usr/bin/perl
# Offline contract tests for install-idk.sh, the one-line installer of the fork.
#
# Nothing here touches the network or the package manager: the GitHub API and
# the release assets are served from a temporary directory over file:// (via
# IDK_GH_API_BASE / IDK_DOWNLOAD_BASE), and apt-get/apt-cache/dpkg-query/
# dpkg-deb/dpkg/systemctl/gpg/id are replaced by stubs placed first on PATH. An
# apt-get stub that logs every invocation is what lets the red cases assert
# that NOTHING was installed - an exit code alone would not prove it.
#
# The cases pinned here are the ways this installer can hurt a node:
#   - running as a non-root user, or off a Proxmox node, must stop early;
#   - a corrupted digest must abort with exit 3 and install nothing;
#   - a SHA256SUMS that does not list the downloaded package at all must abort
#     too. `sha256sum -c --ignore-missing` returns 0 there, which silently
#     turns "never verified" into "verified" (found in dual review);
#   - a package name out of SHA256SUMS is untrusted input to a path used as
#     root: '../../evil.deb' must be refused before anything is written;
#   - an API that answers with HTML, or a release with no .deb, must die with
#     a message. Under `set -euo pipefail` a pipeline ending in a grep with no
#     match used to kill the script silently, rc=1, no diagnosis;
#   - --apt must refuse a candidate that is not the fork's (upstream's, or
#     none at all because a pin blocks it), and must verify the repository
#     key's fingerprint rather than merely checking it is not empty;
#   - --dry-run must never call apt-get install.
#
# Run with:  prove -v t/installer/01-install-idk.t

use strict;
use warnings;
use Test::More;
use FindBin;
use File::Spec;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

my $SCRIPT = File::Spec->rel2abs("$FindBin::Bin/../../install-idk.sh");
plan skip_all => "install-idk.sh not found at $SCRIPT" unless -f $SCRIPT;

for my $tool (qw(bash curl sha256sum)) {
    plan skip_all => "$tool not available" if system("command -v $tool >/dev/null 2>&1") != 0;
}

my $DEB_VERSION  = '1:2.1.23~alpha1+idk18';
my $DEB_ORIGINAL = 'truenas-proxmox-plugin_2.1.23~alpha1+idk18_all.deb';
my $DEB_SERVED   = 'truenas-proxmox-plugin_2.1.23.alpha1+idk18_all.deb';
my $REPO         = 'alfonsokuen/truenas-proxmox-plugin';
my $KEY_FPR      = '1B44882462A1200EFFCFAEFC79E67ECFB42EE1CC';
my $APT_HOST     = 'apt.example.invalid';

my $root = tempdir(CLEANUP => 1);
make_path("$root/etc");

# file:// URLs need a native path: on MSYS/Git Bash the POSIX path is not one.
sub file_url {
    my ($path) = @_;
    my $native = `cygpath -m '$path' 2>/dev/null`;
    chomp $native;
    $native = $path unless $native;
    $native =~ s{^/}{};
    return "file:///$native";
}

sub spew {
    my ($path, $content) = @_;
    open(my $fh, '>', $path) or die "cannot write $path: $!";
    print $fh $content;
    close $fh;
}

# --- fake release assets -------------------------------------------------
my $dl = "$root/dl";
make_path($dl);
spew("$dl/$DEB_SERVED", "not a real package, just bytes with a stable digest\n");

my $digest = `sha256sum '$dl/$DEB_SERVED'`;
$digest =~ s/\s.*//s;
chomp $digest;
ok($digest =~ /^[0-9a-f]{64}$/, 'the fake package has a sha256 digest');

sub write_sums {
    my ($body) = @_;
    spew("$dl/SHA256SUMS", $body);
}
sub good_sums { write_sums("$digest  $DEB_ORIGINAL\n") }
good_sums();

# --- fake GitHub API -----------------------------------------------------
my $api = "$root/api/repos/$REPO/releases";
make_path($api);
my $dl_url = file_url($dl);

sub release_json {
    my (%opt) = @_;
    my @assets = ({ name => 'SHA256SUMS', url => "$dl_url/SHA256SUMS" });
    push @assets, { name => $DEB_SERVED, url => "$dl_url/$DEB_SERVED" }
        unless $opt{no_deb};
    my $body = join(",\n", map {
        qq({\n      "name": "$_->{name}",\n      "browser_download_url": "$_->{url}"\n    })
    } @assets);
    return qq({\n  "tag_name": "v2.1.23-alpha1+idk18",\n  "assets": [\n    $body\n  ]\n}\n);
}
spew("$api/latest", release_json());

# --- stubs ---------------------------------------------------------------
my $stubs = "$root/stubs";
make_path($stubs);

sub stub {
    my ($name, $body) = @_;
    my $path = "$stubs/$name";
    spew($path, "#!/usr/bin/env bash\n$body\n");
    chmod 0755, $path;
}

# id: uid 0 unless IDK_TEST_UID says otherwise.
stub('id', 'if [ "${1:-}" = "-u" ]; then printf "%s\n" "${IDK_TEST_UID:-0}"; exit 0; fi; exec /usr/bin/id "$@"');

# dpkg-query: pve-manager present unless IDK_TEST_NO_PVE is set; the plugin
# itself reports whatever IDK_TEST_INSTALLED holds (empty = not installed).
stub('dpkg-query', <<'SH');
fmt=""; pkg=""
for a in "$@"; do
  case "$a" in
    -f=*) fmt="${a#-f=}" ;;
    -*) ;;
    *) pkg="$a" ;;
  esac
done
case "$pkg" in
  pve-manager)
    [ -n "${IDK_TEST_NO_PVE:-}" ] && exit 1
    case "$fmt" in
      *Status*)  printf 'install ok installed\n' ;;
      *Version*) printf '9.2.4\n' ;;
      *)         printf 'pve-manager\t9.2.4\n' ;;
    esac
    ;;
  truenas-proxmox-plugin)
    [ -z "${IDK_TEST_INSTALLED:-}" ] && exit 1
    case "$fmt" in
      *Version*) printf '%s\n' "$IDK_TEST_INSTALLED" ;;
      *)         printf 'truenas-proxmox-plugin\t%s\n' "$IDK_TEST_INSTALLED" ;;
    esac
    ;;
  *) exit 1 ;;
esac
SH

# apt-get: never does anything, but records that it was asked to. `update`
# is recorded too, so the --apt tests can tell an update from an install.
stub('apt-get', 'printf "%s\n" "$*" >>"$IDK_TEST_APT_LOG"; exit "${IDK_TEST_APT_RC:-0}"');
stub('dpkg-deb', 'printf "%s\n" "${IDK_TEST_DEB_VERSION:-1:2.1.23~alpha1+idk18}"');
stub('systemctl', 'printf "active\n"');

# dpkg --compare-versions, used by the downgrade guard. Only the pair the
# tests exercise needs real semantics, so compare the idkNN suffix.
stub('dpkg', <<'SH');
if [ "${1:-}" = "--compare-versions" ]; then
  a="${2##*idk}"; op="$3"; b="${4##*idk}"
  case "$op" in
    lt) [ "$a" -lt "$b" ] ;;
    gt) [ "$a" -gt "$b" ] ;;
    *)  [ "$a" = "$b" ] ;;
  esac
  exit $?
fi
exit 0
SH

# apt-cache policy, driven by IDK_TEST_CANDIDATE:
#   fork     -> the fork's package from the fork's host
#   upstream -> upstream's package, no epoch, upstream host
#   none     -> pinned out
stub('apt-cache', <<"SH");
case "\${IDK_TEST_CANDIDATE:-fork}" in
  none)
    printf '%s:\\n  Installed: 1:2.1.23~alpha1+idk18\\n  Candidate: (none)\\n' truenas-proxmox-plugin
    ;;
  upstream)
    cat <<'OUT'
truenas-proxmox-plugin:
  Installed: (none)
  Candidate: 2.1.17+deb1
  Version table:
     2.1.17+deb1 500
        500 https://truenas.github.io/truenas-proxmox-plugin/apt trixie/main amd64 Packages
OUT
    ;;
  *)
    cat <<'OUT'
truenas-proxmox-plugin:
  Installed: 1:2.1.23~alpha1+idk18
  Candidate: 1:2.1.23~alpha1+idk18
  Version table:
 *** 1:2.1.23~alpha1+idk18 500
        500 https://$APT_HOST/truenas-proxmox-plugin/apt trixie/main amd64 Packages
        100 /var/lib/dpkg/status
     2.1.17+deb1 -1
        500 https://truenas.github.io/truenas-proxmox-plugin/apt trixie/main amd64 Packages
OUT
    ;;
esac
SH

# gpg --show-keys: reports whatever fingerprint the key file names on its
# first line, so a test can serve a key that is not ours.
stub('gpg', <<'SH');
file=""
for a in "$@"; do case "$a" in -*) ;; *) file="$a" ;; esac; done
[ -n "$file" ] && [ -s "$file" ] || exit 2
fpr=$(head -n1 "$file")
case "$fpr" in
  [0-9A-F]*) printf 'pub:-:4096:1:x:::::::scSC:::::::\nfpr:::::::::%s:\n' "$fpr" ;;
  *) exit 2 ;;
esac
SH

# install(1) would write outside the sandbox; the --apt tests never get that
# far, but stub it so a regression cannot touch the host.
stub('install', 'printf "coreutils-install %s\n" "$*" >>"$IDK_TEST_APT_LOG"; exit 0');

# --- APT repository served over file:// ----------------------------------
my $aptdir = "$root/aptrepo";
make_path($aptdir);
spew("$aptdir/KEY.gpg", "$KEY_FPR\n");
spew("$aptdir/WRONGKEY.gpg", "DEADBEEF00000000000000000000000000000000\n");
my $apt_url = file_url($aptdir);

# --- runner --------------------------------------------------------------
my $run_n = 0;

sub run_installer {
    my (%opt) = @_;
    $run_n++;
    my $log = "$root/apt-$run_n.log";
    spew($log, '');

    my @env = (
        "PATH='$stubs:$ENV{PATH}'",
        "IDK_GH_API_BASE='" . file_url("$root/api") . "'",
        "IDK_DOWNLOAD_BASE='$dl_url'",
        "IDK_APT_BASE_URL='" . ($opt{apt_base} // $apt_url) . "'",
        "IDK_APT_KEY_FPR='$KEY_FPR'",
        "IDK_APT_EXPECTED_HOST='$APT_HOST'",
        "IDK_APT_EXPECTED_HOST='$APT_HOST'",
        "IDK_TEST_APT_LOG='$log'",
        "IDK_APT_SOURCES_FILE='$root/etc/truenas-proxmox-plugin-idk.sources'",
        "IDK_APT_KEYRING_FILE='$root/etc/truenas-proxmox-plugin-idk.gpg'",
    );
    push @env, "IDK_TEST_UID='$opt{uid}'"             if defined $opt{uid};
    push @env, "IDK_TEST_NO_PVE=1"                    if $opt{no_pve};
    push @env, "IDK_TEST_INSTALLED='$opt{installed}'" if defined $opt{installed};
    push @env, "IDK_TEST_CANDIDATE='$opt{candidate}'" if defined $opt{candidate};
    push @env, "IDK_TEST_DEB_VERSION='$opt{deb_version}'" if defined $opt{deb_version};

    my $args = $opt{args} // '';
    my $cmd = join(' ', @env) . " bash '$SCRIPT' $args 2>&1";
    my $out = `$cmd`;
    my $rc  = $? >> 8;

    open(my $r, '<', $log) or die $!;
    my $apt = do { local $/; <$r> };
    close $r;

    return ($rc, $out // '', $apt // '');
}

sub apt_installs {
    my ($apt) = @_;
    return join("\n", grep { /^install/ } split /\n/, $apt);
}

# --- 1. refuses to run as a non-root user --------------------------------
{
    my ($rc, $out, $apt) = run_installer(uid => 1000);
    is($rc, 2, 'a non-root user gets exit 2');
    like($out, qr/must run as root/, 'and is told why');
    is($apt, '', 'apt-get was never called');
}

# --- 2. refuses to run off a Proxmox node --------------------------------
{
    my ($rc, $out, $apt) = run_installer(no_pve => 1);
    is($rc, 2, 'a node without pve-manager gets exit 2');
    like($out, qr/pve-manager is not installed/, 'and is told why');
    is($apt, '', 'apt-get was never called');
}

# --- 3. the rewritten asset name resolves to the original ----------------
{
    my ($rc, $out, $apt) = run_installer();
    is($rc, 0, 'the happy path succeeds');
    like($out, qr/\Qrelease asset: $DEB_SERVED\E/, 'the served name is the rewritten one');
    like($out, qr/\Qverified name: $DEB_ORIGINAL\E/, 'saved under the name SHA256SUMS lists');
    like($out, qr/\Qsha256 OK: $DEB_ORIGINAL\E/, 'the digest was compared explicitly');
    like($apt, qr/\Q$DEB_ORIGINAL\E/, 'apt-get was handed the original file name');
    like($apt, qr/^install -y /m, 'a fresh node gets a plain install');
}

# --- 3b. the same version already installed is reinstalled ---------------
{
    my ($rc, undef, $apt) = run_installer(installed => $DEB_VERSION);
    is($rc, 0, 'reinstalling the same version succeeds');
    like($apt, qr/install --reinstall -y/, 'and goes through --reinstall');
}

# --- 3c. a downgrade needs saying so -------------------------------------
{
    my ($rc, $out, $apt) = run_installer(
        installed => '1:2.1.23~alpha1+idk20', deb_version => '1:2.1.23~alpha1+idk18');
    is($rc, 1, 'an unasked-for downgrade is refused');
    like($out, qr/that is a downgrade/, 'and says so');
    is(apt_installs($apt), '', 'nothing was installed');

    my ($rc2, $out2, $apt2) = run_installer(
        args        => '--allow-downgrade',
        installed   => '1:2.1.23~alpha1+idk20',
        deb_version => '1:2.1.23~alpha1+idk18');
    is($rc2, 0, '--allow-downgrade lets it through');
    like($out2, qr/downgrading/, 'and announces it');
    like($apt2, qr/--allow-downgrades/, 'apt-get is told to allow it too');
}

# --- 4. --dry-run never installs -----------------------------------------
{
    my ($rc, $out, $apt) = run_installer(args => '--dry-run');
    is($rc, 0, '--dry-run exits 0');
    like($out, qr/checksum OK, skipping the installation/, 'it verified and stopped');
    is(apt_installs($apt), '', 'apt-get install was never called');
}

# --- 5. RED: a corrupted digest aborts with exit 3, installing nothing ----
{
    my $bad = $digest;
    substr($bad, 0, 1) = ($digest =~ /^0/) ? '1' : '0';
    write_sums("$bad  $DEB_ORIGINAL\n");

    my ($rc, $out, $apt) = run_installer();
    is($rc, 3, 'a bad checksum gives exit 3');
    like($out, qr/checksum verification FAILED/, 'and says so plainly');
    is(apt_installs($apt), '', 'NOTHING was installed');

    my ($rc2, undef, $apt2) = run_installer(args => '--dry-run');
    is($rc2, 3, '--dry-run also refuses a bad checksum');
    is(apt_installs($apt2), '', 'and still installs nothing');

    good_sums();
}

# --- 5b. RED: a manifest whose line for the package is not a digest -------
# `sha256sum -c --ignore-missing` treats a malformed line as a WARNING, not a
# failure: as long as some other listed file verifies, it exits 0 having
# checked nothing about the package. release.json is sitting in the working
# directory, so one well-formed line about it is enough to paint the run
# green. This is the dual review's blocking finding; the installer now reads
# the package's own line and refuses anything that is not 64 hex characters.
{
    my $json_digest = `sha256sum '$api/latest'`;
    $json_digest =~ s/\s.*//s;
    chomp $json_digest;
    write_sums("not-a-sha256-digest  $DEB_ORIGINAL\n$json_digest  release.json\n");

    my ($rc, $out, $apt) = run_installer();
    is($rc, 3, 'a package line that is not a digest gives exit 3');
    like($out, qr/no usable digest/, 'and names the problem');
    is(apt_installs($apt), '', 'NOTHING was installed');
    good_sums();
}

# --- 5b2. RED: a manifest that does not mention the package at all --------
{
    write_sums("$digest  some-other-artifact.tar.gz\n");
    my ($rc, $out, $apt) = run_installer();
    isnt($rc, 0, 'a manifest that never names a .deb is not a pass');
    like($out, qr/does not list a \.deb/, 'and says so');
    is(apt_installs($apt), '', 'nothing was installed');
    good_sums();
}

# --- 5c. RED: the package name is a path traversal ------------------------
{
    write_sums("$digest  ../../../../tmp/evil.deb\n");
    my ($rc, $out, $apt) = run_installer();
    is($rc, 3, 'a traversing file name gives exit 3');
    like($out, qr/will not write/, 'and is refused by name, before any download');
    is(apt_installs($apt), '', 'nothing was installed');
    ok(!-e '/tmp/evil.deb', 'and nothing landed outside the working directory');
    good_sums();
}

# --- 6. RED: the API answers with something that is not a release ---------
{
    spew("$api/latest", "<!DOCTYPE html>\n<html><body>403 Forbidden</body></html>\n");
    my ($rc, $out, $apt) = run_installer();
    is($rc, 4, 'an HTML body served as the API gives exit 4');
    like($out, qr/did not return a release/, 'with a diagnosis, not a silent rc=1');
    is($apt, '', 'apt-get was never called');

    spew("$api/latest", release_json(no_deb => 1));
    my ($rc2, $out2) = run_installer();
    is($rc2, 4, 'a release with no .deb asset gives exit 4');
    like($out2, qr/no \.deb asset/, 'and says which asset is missing');

    spew("$api/latest", release_json());
}

# --- 6b. RED: the API is unreachable -------------------------------------
{
    my ($rc, $out) = run_installer(args => '--version idk99');
    is($rc, 4, 'a tag that does not exist gives exit 4');
    like($out, qr/could not fetch release metadata/, 'and says so');
}

# --- 7. usage errors ------------------------------------------------------
{
    my ($rc, $out, $apt) = run_installer(args => '--version 18');
    is($rc, 1, 'a malformed --version gives exit 1');
    like($out, qr/--version expects idkNN/, 'with a usable message');
    is($apt, '', 'apt-get was never called');

    my ($rc2, $out2) = run_installer(args => '--version=');
    is($rc2, 1, 'an empty --version= is an error, not "use the default"');
    like($out2, qr/--version is empty/, 'and says so');

    my ($rc3, $out3) = run_installer(args => '--apt --version idk18');
    is($rc3, 1, '--apt with --version is refused');
    like($out3, qr/mutually exclusive/, 'and explains why');
}

# --- 8. --apt: the candidate has to be ours ------------------------------
{
    my ($rc, $out, $apt) = run_installer(args => '--apt', candidate => 'fork');
    is($rc, 0, '--apt succeeds when the candidate is the fork package');
    like($out, qr/\Qrepository key fingerprint verified: $KEY_FPR\E/, 'the key was pinned by fingerprint');
    like($out, qr/\Qrepository candidate: 1:2.1.23~alpha1+idk18 (from $APT_HOST)\E/, 'and the origin was checked');
    like($apt, qr/^update/m, 'apt-get update ran');

    my ($rc2, $out2, $apt2) = run_installer(args => '--apt', candidate => 'upstream');
    is($rc2, 5, "--apt refuses upstream's package");
    like($out2, qr/is NOT the fork's package/, 'and names the problem');
    is(apt_installs($apt2), '', 'nothing was installed');

    my ($rc3, $out3, $apt3) = run_installer(args => '--apt', candidate => 'none');
    is($rc3, 5, '--apt refuses a pinned-out package');
    like($out3, qr/pinned out/, 'and points at the pin');
    is(apt_installs($apt3), '', 'nothing was installed');
}

# --- 8b. --apt: a key with the wrong fingerprint is refused --------------
{
    my $bad = "$root/badkey";
    make_path($bad);
    spew("$bad/KEY.gpg", "DEADBEEF00000000000000000000000000000000\n");
    my ($rc, $out, $apt) = run_installer(args => '--apt', apt_base => file_url($bad));
    is($rc, 3, 'a key that is not ours gives exit 3');
    like($out, qr/does not match the fingerprint/, 'and says so');
    is(apt_installs($apt), '', 'nothing was installed');
}

done_testing();
