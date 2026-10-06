#!/usr/bin/perl
# The pooled-connection liveness probe (auth.me) must judge the ANSWER, not
# merely that one came back: ws_rpc returns the whole decoded envelope, and an
# ENOTAUTHENTICATED error envelope is a truthy hash. Counting it as alive kept
# a dead session in the pool and renewed its liveness cache.
#
# Run with:  prove -v t/broker/04-liveness-envelope.t
use strict;
use warnings;
use Test::More;
use FindBin;

my $BROKER = "$FindBin::Bin/../../tools/truenas-plugin-broker";
plan skip_all => "broker not found at $BROKER" unless -f $BROKER;
open(my $fh, '<', $BROKER) or die; my $src = do { local $/; <$fh> }; close $fh;
my ($snippet) = $src =~ /(sub liveness_ok\s*\{.*?\n\}\n.*?sub get_or_open_ws\s*\{.*?\n\}\n)/s;
plan skip_all => 'could not extract get_or_open_ws' unless $snippet;

package Br;
use strict; use warnings;
our (%POOL, $UPSTREAM_TIMEOUT, $PING_TIMEOUT, $LIVENESS_CACHE_SECS, @RPC, $opened, @RESP);
$UPSTREAM_TIMEOUT = 30; $PING_TIMEOUT = 5; $LIVENESS_CACHE_SECS = 60;
sub scfg_key { 'k' }
sub linfo { 1 }
sub ws_rpc { return shift @RESP }
sub ws_open { $opened++; return { sock => bless({}, 'Br::Sock') } }
sub Br::Sock::close { 1 }
sub sha1_hex { 'x' }
eval "$snippet; 1" or die "snippet failed: $@";
package main;

sub run {
    my ($resp) = @_;
    %Br::POOL = ( k => { conn => { sock => bless({}, 'Br::Sock') }, last_used => 1, last_liveness_ok => 0 } );
    $Br::opened = 0; @Br::RESP = ($resp);
    Br::get_or_open_ws({ api_host => 'h', api_key => 'k' });
    return ($Br::opened, $Br::POOL{k}{last_liveness_ok});
}

my ($o, $stamp) = run({ jsonrpc => '2.0', id => 999999, result => { pw_name => 'svc' } });
is($o, 0, 'a real auth.me result keeps the pooled connection');
ok($stamp > 0, '  ...and renews the liveness cache');

($o, $stamp) = run({ jsonrpc => '2.0', id => 999999, error => { code => -32001, message => 'ENOTAUTHENTICATED' } });
is($o, 1, 'an error envelope drops the connection and reopens (re-auth)');

($o) = run({ jsonrpc => '2.0', id => 999999, error => { code => -32601, message => 'Method does not exist' }, result => undef });
is($o, 1, 'an envelope carrying an error is never alive, even with a result key');
($o) = run(undef);
is($o, 1, 'no answer drops the connection');
($o) = run({ jsonrpc => '2.0', id => 999999 });
is($o, 1, 'an envelope with neither result nor error is not proof of life');
done_testing;
