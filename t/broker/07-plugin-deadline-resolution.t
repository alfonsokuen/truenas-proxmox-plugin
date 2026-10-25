#!/usr/bin/perl
# The plugin tells the broker "I will wait <timeout> seconds" and the broker works
# out how long it may spend upstream from that (leaving a margin to answer). The
# plugin's own wait must therefore last the declared time.
#
# Perl's core time() is whole seconds. A wait loop that recomputes
# `$deadline - time()` on every pass loses up to a second as soon as it runs a
# second pass across a second boundary - which is exactly what happens when the
# first bytes of an answer arrive and the rest does not. For a 1-2 s budget that
# is more than the broker's margin: the broker keeps working for a client that has
# already left, and a mutation it ran is reported as failed and may be retried.
#
# The scenario: the broker sends the start of its answer 0.3 s in, with the clock
# 0.15 s before a second boundary, and then goes quiet. The call must still wait
# for the full declared time.
#
# Run with:  prove -v -I t/nvme/lib t/broker/07-plugin-deadline-resolution.t
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../nvme/lib";
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);
use Time::HiRes ();

my $PLUGIN = "$FindBin::Bin/../../TrueNASPlugin.pm";
unless (eval { require $PLUGIN; 1 }) {
    plan skip_all => "cannot load plugin: $@";
}
my $pkg = 'PVE::Storage::Custom::TrueNASPlugin';
my $rpc = $pkg->can('_broker_rpc') or BAIL_OUT('no _broker_rpc');

my $TIMEOUT = 1.5;
my @waited;
for my $run (1 .. 3) {
    # Start 0.15 s before a whole second, so the partial answer lands after it.
    my $frac = Time::HiRes::time() - int(Time::HiRes::time());
    my $pause = (0.85 - $frac); $pause += 1 if $pause < 0;
    Time::HiRes::sleep($pause);

    socketpair(my $client, my $server, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
        or plan skip_all => "socketpair unavailable: $!";
    my $pid = fork();
    defined $pid or plan skip_all => "fork unavailable: $!";
    if (!$pid) {
        close $client;
        Time::HiRes::sleep(0.3);
        syswrite($server, '{"result":');          # the start of an answer, no newline
        Time::HiRes::sleep(3);                      # then silence until the parent is done
        exit 0;
    }
    close $server;

    my $t0 = Time::HiRes::time();
    {
        no strict 'refs';
        no warnings 'redefine';
        local *{"${pkg}::_tn_api_key"} = sub { 'test-key' };
        eval {
            $rpc->({ sock => $client, scfg => {
                tn_api_host => '127.0.0.1', tn_api_scheme => 'ws',
                tn_broker_timeout => $TIMEOUT,
            } }, { method => 'test.partial', params => [] });
        };
    }
    my $took = Time::HiRes::time() - $t0;
    my $err = $@;
    kill 'TERM', $pid; waitpid($pid, 0);
    push @waited, $took;
    like($err, qr/broker: read timeout/, "run $run: a partial answer followed by silence ends in a read timeout");
}
for my $i (0 .. $#waited) {
    cmp_ok($waited[$i], '>=', $TIMEOUT - 0.15,
        sprintf('run %d: waited %.2fs of the declared %.1fs (not up to a second less)', $i + 1, $waited[$i], $TIMEOUT));
}
done_testing;
