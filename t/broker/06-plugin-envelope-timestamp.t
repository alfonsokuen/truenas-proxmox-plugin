#!/usr/bin/perl
use strict;
use warnings;
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
like("$envelope->{sent_at}", qr/^\d+\.\d+$/,
    'send timestamp has subsecond precision for short budgets');
done_testing();
