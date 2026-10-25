#!/usr/bin/perl
use strict;
use warnings;
use Time::HiRes ();
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../nvme/lib";
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);
use JSON::PP qw(decode_json);

my $PLUGIN = "$FindBin::Bin/../../TrueNASPlugin.pm";
unless (eval { require $PLUGIN; 1 }) {
    plan skip_all => "cannot load plugin: $@";
}
my $pkg = 'PVE::Storage::Custom::TrueNASPlugin';
my $rpc = $pkg->can('_broker_rpc') or BAIL_OUT('no _broker_rpc');
socketpair(my $client, my $server, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
    or plan skip_all => "socketpair unavailable: $!";

# The reply can be queued before the call; the other end captures the request.
$server->syswrite("{\"result\":\"ok\"}\n");
my $result;
{
    no strict 'refs';
    no warnings 'redefine';
    local *{"${pkg}::_tn_api_key"} = sub { 'test-key' };
    $result = $rpc->({ sock => $client, scfg => {
        tn_api_host => '127.0.0.1', tn_api_scheme => 'ws',
        tn_broker_timeout => 1,
    } }, { method => 'test.echo', params => [] });
}
is($result, 'ok', 'plugin accepts a broker response');
my $line = <$server>;
my $envelope = decode_json($line);
is($envelope->{timeout}, 1, 'client timeout is sent unchanged');
ok(!exists $envelope->{sent_at}, 'no wall-clock stamp is sent: a clock step must not decide whether a request expired');
my $now_mono = Time::HiRes::clock_gettime(Time::HiRes::CLOCK_MONOTONIC());
ok(defined $envelope->{sent_mono} && "$envelope->{sent_mono}" =~ /^[0-9]+[.][0-9]+$/,
    'a monotonic send stamp with subsecond precision is sent');
ok(abs($now_mono - $envelope->{sent_mono}) < 5, 'the stamp is on the same monotonic clock as the broker reads');
done_testing();
