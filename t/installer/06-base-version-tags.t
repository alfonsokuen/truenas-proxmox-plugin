#!/usr/bin/perl
# The release tag of a fork revision carries the upstream base it was cut from:
#   idk12..idk21 -> v2.1.23-alpha1+idkNN
#   idk22        -> v2.1.23-beta8+idk22
#   idk23        -> v2.1.23-deb1+idk23
#   idk31 onward -> v2.1.25-beta2+idkNN
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
    idk24 => '2.1.24-beta4',
    idk25 => '2.1.24-beta4',
    idk26 => '2.1.24-beta6',
    idk27 => '2.1.24-beta6',
    idk28 => '2.1.24-beta6',
    idk29 => '2.1.24',
    idk30 => '2.1.24',
    idk31 => '2.1.25-beta2',
    idk99 => '2.1.25-beta2',
    ''    => '2.1.25-beta2',           # unparseable falls to the current base, as before
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
like($iv // '', qr/'idk31\./, 'INSTALLER_VERSION is the idk31 line');

# deb_version -> release tag, as .github/workflows/build-package.yml computes it.
sub tag_for { my $v = shift; $v =~ s/~/-/g; $v =~ s/\+/-/ if $v =~ /\+deb/; return "v$v"; }
is(tag_for('2.1.23+deb1+idk23'), 'v2.1.23-deb1+idk23', 'workflow tag rule: idk23 unchanged');
is(tag_for('2.1.24~beta4+idk25'), 'v2.1.24-beta4+idk25', 'workflow tag rule: idk25 has no tilde and keeps +idk25');
is('v' . base_for($FILES[0], 'idk25') . '+idk25', tag_for('2.1.24~beta4+idk25'), 'scripts and workflow agree on the idk25 tag');
is(tag_for('2.1.24~beta6+idk26'), 'v2.1.24-beta6+idk26', 'workflow tag rule: idk26 has no tilde and keeps +idk26');
is('v' . base_for($FILES[0], 'idk26') . '+idk26', tag_for('2.1.24~beta6+idk26'), 'scripts and workflow agree on the idk26 tag');
is(tag_for('2.1.24~beta6+idk27'), 'v2.1.24-beta6+idk27', 'workflow tag rule: idk27 has no tilde and keeps +idk27');
is('v' . base_for($FILES[0], 'idk27') . '+idk27', tag_for('2.1.24~beta6+idk27'), 'scripts and workflow agree on the idk27 tag');
is(tag_for('2.1.24~beta6+idk28'), 'v2.1.24-beta6+idk28', 'workflow tag rule: idk28 has no tilde and keeps +idk28');
is('v' . base_for($FILES[0], 'idk28') . '+idk28', tag_for('2.1.24~beta6+idk28'), 'scripts and workflow agree on the idk28 tag');
is(tag_for('2.1.24+idk30'), 'v2.1.24+idk30', 'workflow tag rule: idk30 (final 2.1.24 base) keeps +idk30');
is('v' . base_for($FILES[0], 'idk30') . '+idk30', tag_for('2.1.24+idk30'), 'scripts and workflow agree on the idk30 tag');

is(tag_for('2.1.25~beta2+idk31'), 'v2.1.25-beta2+idk31', 'workflow tag rule: idk31 keeps +idk31');
is('v' . base_for($FILES[0], 'idk31') . '+idk31', tag_for('2.1.25~beta2+idk31'), 'scripts and workflow agree on the idk31 tag');

done_testing;
