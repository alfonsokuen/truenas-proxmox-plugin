#!/usr/bin/perl
# The release tag of a fork revision carries the upstream base it was cut from:
#   idk12..idk21 -> v2.1.23-alpha1+idkNN
#   idk22        -> v2.1.23-beta8+idk22
#   idk23 onward -> v2.1.23-deb1+idkNN   (upstream's stable 2.1.23+deb1)
# install-idk.sh (download path) and tools/publish-apt.sh (APT publisher) each
# carry their own copy of the mapping; a mismatch means one of them looks up a
# tag that was never created. Both copies are exercised here and compared.
#
# Run with:  prove -v t/installer/06-base-version-tags.t
use strict;
use warnings;
use Test::More;
use FindBin;
use File::Spec;

my $ROOT = File::Spec->rel2abs("$FindBin::Bin/../..");
my @FILES = ("$ROOT/install-idk.sh", "$ROOT/tools/publish-apt.sh");
plan skip_all => "bash not available" if system("command -v bash >/dev/null 2>&1") != 0;
for my $f (@FILES) { plan skip_all => "$f not found" unless -f $f }

sub base_for {
    my ($file, $rev) = @_;
    # Pull just the function out: sourcing either script would run its main.
    my $cmd = qq{bash -c 'eval "\$(sed -n "/^base_version_for() {/,/^}/p" "$file")"; base_version_for "$rev"'};
    my $out = `$cmd 2>/dev/null`;
    chomp $out;
    return $out;
}

my %want = (
    idk15 => '2.1.23-alpha1',
    idk21 => '2.1.23-alpha1',
    idk22 => '2.1.23-beta8',
    idk23 => '2.1.23-deb1',
    idk24 => '2.1.23-deb1',
    idk99 => '2.1.23-deb1',
    ''    => '2.1.23-deb1',      # unparseable falls to the current base, as before
);
for my $f (@FILES) {
    (my $label = $f) =~ s{^\Q$ROOT\E/}{};
    for my $rev (sort keys %want) {
        is(base_for($f, $rev), $want{$rev}, "$label: base_version_for('$rev') = $want{$rev}");
    }
}

# The tag the release must be published under for idk23, as both scripts build it.
is('v' . base_for($FILES[0], 'idk23') . '+idk23', 'v2.1.23-deb1+idk23',
    'idk23 release tag is v2.1.23-deb1+idk23');

# INSTALLER_VERSION keeps the idkN.M shape the installer tests rely on.
open(my $fh, '<', $FILES[0]) or die "cannot read $FILES[0]: $!";
my ($iv) = grep { /^INSTALLER_VERSION=/ } <$fh>;
close $fh;
like($iv // '', qr/^INSTALLER_VERSION='idk\d+\.\d+'$/, 'INSTALLER_VERSION matches idkN.M');
like($iv // '', qr/'idk23\./, 'INSTALLER_VERSION is the idk23 line');

done_testing;
