#!/usr/bin/perl
# idk31 r7: prerm ignores a failed stop, so purge must not delete the broker's
# run dir (socket, pidfile) while the broker is still alive. An unknown unit
# state counts as alive.
use strict;
use warnings;
use FindBin;
use File::Temp qw(tempdir tempfile);
use Test::More;

plan skip_all => 'sh not available' if system('command -v sh >/dev/null 2>&1') != 0;

my $postrm = "$FindBin::Bin/../../debian/postrm";
open(my $input, '<', $postrm) or die "cannot read $postrm: $!";
my $source = do { local $/; <$input> };
close $input;
my ($unit) = $source =~ /^(BROKER_UNIT=.*)$/m;
my ($function) = $source =~ /^(broker_alive\(\) \{.*?^\})/ms;
die 'could not extract broker_alive and its unit' unless $function && $unit;

like($source, qr/if broker_alive; then\n[^\n]*WARNING[^\n]*\n\s*else\n\s*rm -rf "\$BROKER_RUNDIR"\n\s*fi/,
    'purge removes the run dir only in the branch where the broker is not alive');

my $rundir = tempdir(CLEANUP => 1);
# Take the systemd branch on any host: point its marker dir at one that exists.
my $systemd_marker = tempdir(CLEANUP => 1);
$function =~ s{/run/systemd/system}{$systemd_marker}g;
my ($script_fh, $script_path) = tempfile(UNLINK => 1);
print {$script_fh} <<"SH";
BROKER_RUNDIR="$rundir"
$unit
state="\$1"
show_rc="\$2"
systemctl() {
    [ "\$1" = show ] || exit 127
    [ "\$show_rc" = 0 ] || return "\$show_rc"
    echo "\$state"
}
$function
if broker_alive; then echo alive; else echo stopped; fi
SH
close $script_fh;

sub alive {
    my ($state, $show_rc, $pid) = @_;
    unlink "$rundir/broker.pid";
    if (defined $pid) {
        open(my $fh, '>', "$rundir/broker.pid") or die $!;
        print {$fh} "$pid\n";
        close $fh;
    }
    chomp(my $out = `sh "$script_path" "$state" "$show_rc"`);
    return $out;
}

is(alive('active', 0), 'alive', 'an active unit is alive');
is(alive('deactivating', 0), 'alive', 'a unit still draining is alive');
is(alive('', 1), 'alive', 'an unreadable unit state counts as alive');
is(alive('inactive', 0, $$), 'alive', 'a pidfile naming a live process is alive');
is(alive('inactive', 0, 999999), 'stopped', 'a stale pidfile is not');
is(alive('inactive', 0), 'stopped', 'no pidfile and an inactive unit: purge may delete the run dir');

done_testing;
