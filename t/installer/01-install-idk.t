#!/usr/bin/perl
# Offline contract tests for install-idk.sh, the one-line installer of the fork.
#
# Nothing here touches the network or the package manager: the GitHub API and
# the release assets are served from a temporary directory over file:// (via
# IDK_GH_API_BASE / IDK_DOWNLOAD_BASE), and apt-get/dpkg-query/dpkg-deb/
# systemctl/id are replaced by stubs placed first on PATH. An apt-get stub that
# logs every invocation is what lets the red cases assert that NOTHING was
# installed - an exit code alone would not prove it.
#
# The cases pinned here are the ways this installer can hurt a node:
#   - running as a non-root user, or off a Proxmox node, must stop early;
#   - a corrupted SHA256SUMS must abort with exit 3 and install nothing;
#   - --dry-run must never call apt-get;
#   - GitHub rewrites '~' to '.' in asset names, so the served file name never
#     matches the one inside SHA256SUMS. The installer has to download the
#     rewritten asset and save it under the original name, or `sha256sum -c`
#     fails on a package that is in fact intact.
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

my $root = tempdir(CLEANUP => 1);

# file:// URLs need a native path: on MSYS/Git Bash the POSIX path is not one.
sub file_url {
    my ($path) = @_;
    my $native = `cygpath -m '$path' 2>/dev/null`;
    chomp $native;
    $native = $path unless $native;
    $native =~ s{^/}{};
    return "file:///$native";
}

# --- fake release assets -------------------------------------------------
my $dl = "$root/dl";
make_path($dl);
open(my $fh, '>', "$dl/$DEB_SERVED") or die "cannot write the fake deb: $!";
print $fh "not a real package, just bytes with a stable digest\n";
close $fh;

my $digest = `sha256sum '$dl/$DEB_SERVED'`;
$digest =~ s/\s.*//s;
chomp $digest;
ok($digest =~ /^[0-9a-f]{64}$/, 'the fake package has a sha256 digest');

sub write_sums {
    my ($hash) = @_;
    open(my $s, '>', "$dl/SHA256SUMS") or die "cannot write SHA256SUMS: $!";
    print $s "$hash  $DEB_ORIGINAL\n";
    close $s;
}
write_sums($digest);

# --- fake GitHub API -----------------------------------------------------
my $api = "$root/api/repos/$REPO/releases";
make_path($api);
my $dl_url = file_url($dl);
my $release_json = <<"JSON";
{
  "tag_name": "v2.1.23-alpha1+idk18",
  "name": "idk18",
  "assets": [
    {
      "name": "SHA256SUMS",
      "browser_download_url": "$dl_url/SHA256SUMS"
    },
    {
      "name": "$DEB_SERVED",
      "browser_download_url": "$dl_url/$DEB_SERVED"
    }
  ]
}
JSON
for my $f ("$api/latest") {
    open(my $j, '>', $f) or die "cannot write $f: $!";
    print $j $release_json;
    close $j;
}

# --- stubs ---------------------------------------------------------------
my $stubs = "$root/stubs";
make_path($stubs);

sub stub {
    my ($name, $body) = @_;
    my $path = "$stubs/$name";
    open(my $s, '>', $path) or die "cannot write the $name stub: $!";
    print $s "#!/usr/bin/env bash\n$body\n";
    close $s;
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

# apt-get: never does anything, but records that it was asked to.
stub('apt-get', 'printf "%s\n" "$*" >>"$IDK_TEST_APT_LOG"; exit 0');
stub('dpkg-deb', 'printf "%s\n" "${IDK_TEST_DEB_VERSION:-1:2.1.23~alpha1+idk18}"');
stub('systemctl', 'printf "active\n"');

# --- runner --------------------------------------------------------------
my $run_n = 0;

sub run_installer {
    my (%opt) = @_;
    $run_n++;
    my $log = "$root/apt-$run_n.log";
    open(my $l, '>', $log) or die $!;
    close $l;

    my @env = (
        "PATH='$stubs:$ENV{PATH}'",
        "IDK_GH_API_BASE='" . file_url("$root/api") . "'",
        "IDK_DOWNLOAD_BASE='$dl_url'",
        "IDK_TEST_APT_LOG='$log'",
    );
    push @env, "IDK_TEST_UID='$opt{uid}'"            if defined $opt{uid};
    push @env, "IDK_TEST_NO_PVE=1"                   if $opt{no_pve};
    push @env, "IDK_TEST_INSTALLED='$opt{installed}'" if defined $opt{installed};

    my $args = $opt{args} // '';
    my $cmd = join(' ', @env) . " bash '$SCRIPT' $args 2>&1";
    my $out = `$cmd`;
    my $rc  = $? >> 8;

    open(my $r, '<', $log) or die $!;
    my $apt = do { local $/; <$r> };
    close $r;

    return ($rc, $out // '', $apt // '');
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
    like($apt, qr/\Q$DEB_ORIGINAL\E/, 'apt-get was handed the original file name');
    like($apt, qr/^install -y /m, 'a fresh node gets a plain install');
}

# --- 3b. the same version already installed is reinstalled ---------------
{
    my ($rc, undef, $apt) = run_installer(installed => $DEB_VERSION);
    is($rc, 0, 'reinstalling the same version succeeds');
    like($apt, qr/install --reinstall -y/, 'and goes through --reinstall');
}

# --- 4. --dry-run never calls apt-get ------------------------------------
{
    my ($rc, $out, $apt) = run_installer(args => '--dry-run');
    is($rc, 0, '--dry-run exits 0');
    like($out, qr/checksum OK, skipping the installation/, 'it verified and stopped');
    is($apt, '', 'apt-get was never called');
}

# --- 5. RED: a corrupted SHA256SUMS aborts with exit 3, installing nothing -
{
    my $bad = $digest;
    substr($bad, 0, 1) = ($digest =~ /^0/) ? '1' : '0';
    write_sums($bad);

    my ($rc, $out, $apt) = run_installer();
    is($rc, 3, 'a bad checksum gives exit 3');
    like($out, qr/checksum verification FAILED/, 'and says so plainly');
    is($apt, '', 'NOTHING was installed');

    # --dry-run must fail just as hard: it verifies before it decides.
    my ($rc2, undef, $apt2) = run_installer(args => '--dry-run');
    is($rc2, 3, '--dry-run also refuses a bad checksum');
    is($apt2, '', 'and still installs nothing');

    write_sums($digest);
}

# --- 6. a bad --version argument is a usage error ------------------------
{
    my ($rc, $out, $apt) = run_installer(args => '--version 18');
    is($rc, 1, 'a malformed --version gives exit 1');
    like($out, qr/--version expects idkNN/, 'with a usable message');
    is($apt, '', 'apt-get was never called');
}

done_testing();
