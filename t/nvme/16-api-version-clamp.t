#!/usr/bin/perl
# api() must never claim a storage API version the host does not implement.
#
# PVE's loader accepts a claim only inside [APIVER - APIAGE, APIVER]. Above the
# range it dies ("newer than current"); below it, it dies too ("too old");
# inside it, a claim that is not exactly APIVER only warns. The cost is
# asymmetric at the top: overclaiming by one loses the whole storage.
#
# The negotiation this replaced had three branches and returned $TESTED_APIVER
# unclamped whenever the host reported below 11:
#
#   if ($sysver >= 11 && $sysver <= $tested) { return $sysver }
#   if ($sysver - $sysage < $tested)         { return $tested }   # <-- unclamped
#   return 11;
#
# On a host at APIVER 10 (PVE shipped exactly that: "bump plugin APIVER (10)
# and APIAGE (1)") the second branch returned 14 > 10, so the storage failed to
# load outright, while the header comment claimed PVE 8.x support.
#
# Run with:  prove -v t/nvme/16-api-version-clamp.t

use strict;
use warnings;
use Test::More;
use FindBin;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Spec;

my $PLUGIN_FILE = File::Spec->rel2abs("$FindBin::Bin/../../TrueNASPlugin.pm");
plan skip_all => "TrueNASPlugin.pm not found at $PLUGIN_FILE" unless -f $PLUGIN_FILE;

# Read the tested version from source, so this test does not go stale in
# silence the day someone bumps the constant.
my $TESTED;
{
    open(my $fh, '<', $PLUGIN_FILE) or die "open $PLUGIN_FILE: $!";
    while (my $l = <$fh>) { $TESTED = $1, last if $l =~ /^our \$TESTED_APIVER\s*=\s*(\d+)/ }
    close $fh;
}
plan skip_all => "cannot read \$TESTED_APIVER from the plugin" unless defined $TESTED;

# Ask the plugin, in a fresh interpreter, what it declares against a host that
# reports ($apiver, $apiage). A stub PVE/Storage.pm shadows the real module;
# api() holds the only reference to it in the whole plugin, so nothing else
# shifts underneath. List-form open, no shell: with a shell in between, the
# quoting let it expand $ARGV[0] away before perl ever saw the program.
#
# The child's STDERR goes to a FILE, not to /dev/null. Discarding it is what
# made "the plugin is broken" indistinguishable from "this box has no PVE",
# and a test that cannot tell those apart reports green for a plugin that
# does not load at all.
sub api_against {
    my ($apiver, $apiage, $plugin) = @_;
    $plugin = $PLUGIN_FILE if !defined $plugin;

    my $dir = tempdir(CLEANUP => 1);
    make_path("$dir/PVE");
    open(my $fh, '>', "$dir/PVE/Storage.pm") or die "write stub: $!";
    print $fh "package PVE::Storage;\n"
            . "use constant APIVER => $apiver;\n"
            . "use constant APIAGE => $apiage;\n1;\n";
    close $fh;

    my $errfile = "$dir/child-stderr.txt";
    my $code = 'open(STDERR, ">", $ARGV[1]) or die "redirect: $!";'
             . 'require $ARGV[0];'
             . 'print PVE::Storage::Custom::TrueNASPlugin->api();';

    my $out = '';
    if (open(my $ph, '-|', $^X, '-I', $dir, '-e', $code, $plugin, $errfile)) {
        local $/;
        $out = <$ph>;
        $out = '' if !defined $out;
        close $ph;
    }

    my $err = '';
    if (open(my $eh, '<', $errfile)) { local $/; $err = <$eh>; $err = '' if !defined $err; close $eh; }

    return ($out =~ /^(\d+)$/ ? $1 : undef, $err);
}

# What PVE's loader would do with a given claim.
sub verdict {
    my ($claimed, $apiver, $apiage) = @_;
    return 'NO CARGA (declara mas que el host)'  if $claimed > $apiver;
    return 'NO CARGA (declara menos del minimo)' if $claimed < $apiver - $apiage;
    return $claimed != $apiver ? 'carga + warn' : 'carga limpia';
}

# The probe decides skip vs fail. ONLY an absent PVE installation earns a skip:
# those are the three modules the plugin pulls in at load time. Any other
# failure - a syntax error, a missing module of our own, a die inside api() -
# is a real failure, and skipping it would let a broken plugin ship green.
my ($probe, $probe_err) = api_against(15, 6);
if (!defined $probe) {
    if ($probe_err =~ m{Can't locate PVE/(?:Tools|JSONSchema|Storage/Plugin)\.pm}) {
        plan skip_all => "no PVE perl modules here (needs libpve-storage-perl)";
    }
    plan tests => 1;
    fail("the plugin did not load in a subprocess, and not for lack of PVE");
    diag("child stderr was:\n$probe_err");
    exit 1;
}

# (apiver, apiage) pairs PVE has actually shipped, plus hosts newer than us.
my @HOSTS = (
    [  9, 2, 'PVE 7.x temprano' ],
    [ 10, 1, 'PVE 7.0-14, el que rompia' ],
    [ 11, 2, 'PVE 8.x' ],
    [ 14, 3, 'PVE 9.1.3' ],
    [ 15, 6, 'PVE 9.2.4, este cluster' ],
    [ 16, 6, 'host mas nuevo que nosotros' ],
    [ 20, 3, 'host que ya no nos acepta' ],
);

plan tests => 2 * scalar(@HOSTS) + 3;

for my $h (@HOSTS) {
    my ($apiver, $apiage, $label) = @$h;
    my ($got) = api_against($apiver, $apiage);
    my $want = $apiver < $TESTED ? $apiver : $TESTED;

    is($got, $want, "APIVER=$apiver AGE=$apiage ($label): declara $want");

    my $v = defined $got ? verdict($got, $apiver, $apiage) : 'sin respuesta';
    if ($apiver - $apiage > $TESTED) {
        like($v, qr/NO CARGA \(declara menos/,
            "  ...host demasiado nuevo: muere citando nuestra version real");
    } else {
        unlike($v, qr/NO CARGA/, "  ...el plugin carga (veredicto: $v)");
    }
}

# The two rows that regress the moment anyone reinstates the unclamped branch.
is((api_against(10, 1))[0], 10, "regresion: en APIVER 10 declara 10, no $TESTED");
is((api_against(9, 2))[0],   9, "regresion: en APIVER 9 declara 9, no $TESTED");

# And the guard on this very test: a plugin that cannot be loaded must NOT be
# reported as a skip. Feed the harness a file that is syntactically valid Perl
# but is not the plugin, and assert we can tell that apart from missing PVE.
{
    my $dir = tempdir(CLEANUP => 1);
    my $broken = "$dir/Broken.pm";
    open(my $bh, '>', $broken) or die $!;
    print $bh "use No::Such::Module::Here;\n1;\n";
    close $bh;

    my (undef, $err) = api_against(15, 6, $broken);
    unlike($err, qr{Can't locate PVE/(?:Tools|JSONSchema|Storage/Plugin)\.pm},
        "un plugin roto no se confunde con la ausencia de PVE (skip indebido)");
}
