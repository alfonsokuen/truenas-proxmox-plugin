#!/usr/bin/perl
# A slow TrueNAS must arm the status() backoff, and must NOT become retryable.
#
# Three errors come from our own broker/client, not from the network stack, so
# _is_connection_error never matched them:
#   broker: no response from upstream      (tools/truenas-plugin-broker)
#   broker: EOF before complete response   (broker client, _broker_call)
#   broker socket missing                  (broker client, _ws_get_persistent)
# Without a match, status() logged a warning and probed again on every poll,
# so pvestatd paid the full deadline each time against a slow array.
#
# The fix is a separate classifier, _is_broker_transport_error, used ONLY by
# status(). It must stay out of _is_retryable_error: after "no response" the
# request may already have been executed, and retrying a mutation can create
# it twice (the same hole documented in volume_snapshot). Both directions are
# asserted here: status() backs off, and nothing starts retrying.
#
# Assertions tagged EXPECT-FAIL(unfixed) must FAIL without the classifier.
#
# Run with:  prove -v t/nvme/37-broker-transport-errors.t

use strict;
use warnings;
use Test::More;
use FindBin;

my $PLUGIN = "$FindBin::Bin/../../TrueNASPlugin.pm";
unless (eval { require $PLUGIN; 1 }) {
    plan skip_all => "cannot load TrueNASPlugin.pm (needs PVE perl modules): $@";
}

my $PKG = 'PVE::Storage::Custom::TrueNASPlugin';
plan skip_all => "status not found" unless $PKG->can('status');

my @calls;
my $fail_with;

{
    no strict 'refs';
    no warnings 'redefine';
    # Same stubs as 13-status-probe-backoff.t: no cross-process stamp under
    # /run, no logging, no sysfs work, and a fake API that dies on demand.
    *{"${PKG}::_read_status_stamp"}  = sub { undef };
    *{"${PKG}::_write_status_stamp"} = sub { 1 };
    *{"${PKG}::_log"} = sub { 1 };
    *{"${PKG}::_nvme_connect"} = sub { 1 };
    *{"${PKG}::_api_call"} = sub {
        my ($scfg, $method) = @_;
        push @calls, $method;
        die $fail_with if defined $fail_with;
        return {
            id => 'tank/pve', type => 'FILESYSTEM',
            available => { parsed => 500 }, used => { parsed => 500 },
            written   => { parsed => 500 }, quota => { parsed => 0 },
        } if $method eq 'pool.dataset.get_instance';
        return [ { name => 'tank', status => 'ONLINE', healthy => 1 } ]
            if $method eq 'pool.query';
        return [];
    };
    *{"${PKG}::_api_call_mutate"} = sub { goto &{"${PKG}::_api_call"} };
}

my @TRANSPORT = (
    'broker: no response from upstream',
    'broker: EOF before complete response',
    'broker: request expired in queue',
    "[TrueNAS] broker socket missing at /run/truenas-plugin/broker.sock.\n  The truenas-plugin-broker service is required\n",
);

# --- the classifier itself --------------------------------------------------

my $classify = $PKG->can('_is_broker_transport_error');
ok($classify, '_is_broker_transport_error exists')
    or BAIL_OUT('no _is_broker_transport_error');

ok($classify->($_), "broker transport error: " . (split /\n/, $_)[0]) for @TRANSPORT;
ok($classify->(uc $TRANSPORT[0]), 'matching ignores case');
ok($classify->("Operation failed after 2 retries: $TRANSPORT[1]"),
   'matches inside a wrapped message');

# Definitive server verdicts and unrelated text must not match.
ok(!$classify->($_), "not a transport error: $_") for (
    '[EINVAL] bad name',
    'JSON-RPC error [EEXIST]: dataset already exists',
    'dataset already exists',
    'JSON-RPC error [ENOENT]: dataset does not exist',
    'ENOENT',
    'broker: bad response: malformed JSON',
    'broker: write failed: Broken pipe',
);
ok(!$classify->(undef), 'undef is not a transport error');
ok(!$classify->(''),    'empty string is not a transport error');

# --- the decision that must NOT move: retry behaviour -----------------------
# Documented on purpose: retrying after "no response" can duplicate a mutation.

my $retryable = $PKG->can('_is_retryable_error') or BAIL_OUT('no _is_retryable_error');
my $conn_err  = $PKG->can('_is_connection_error') or BAIL_OUT('no _is_connection_error');
ok(!$retryable->($_), "still NOT retryable: " . (split /\n/, $_)[0]) for @TRANSPORT;
ok(!$conn_err->($_),  "still not a _is_connection_error: " . (split /\n/, $_)[0]) for @TRANSPORT;

# --- status() backs off on each of them -------------------------------------

my %SCFG = (
    tn_dataset        => 'tank/pve',
    tn_api_host       => '198.51.100.7',
    tn_transport_mode => 'nvme-tcp',
    tn_subsystem_nqn  => 'nqn.2011-06.com.example:test',
);

# One host per case: the marker is keyed per host and package-global.
my $HOSTN = 100;
sub fresh_scfg {
    $HOSTN++;
    return { %SCFG, tn_api_host => "198.51.100.$HOSTN" };
}

sub call_status {
    my ($scfg) = @_;
    @calls = ();
    my @r = $PKG->status('store1', $scfg, undef);
    return { total => $r[0], active => $r[3], api_calls => scalar(@calls) };
}

for my $err (@TRANSPORT) {
    my $label = (split /\n/, $err)[0];
    my $scfg = fresh_scfg();
    $fail_with = $err;

    my $first = call_status($scfg);
    ok(!$first->{active}, "status inactive on: $label");
    cmp_ok($first->{api_calls}, '>', 0, '...after really trying');
    is($first->{api_calls}, 1, '...exactly once: the error is not retried');

    my $second = call_status($scfg);
    ok(!$second->{active}, '...next poll still inactive');
    # EXPECT-FAIL(unfixed): without the classifier this probes again.
    is($second->{api_calls}, 0, '...and answers from the marker, without touching the API');
}

# A definitive server verdict still does not arm the marker.
{
    my $scfg = fresh_scfg();
    $fail_with = "dataset does not exist\n";
    call_status($scfg);
    my $second = call_status($scfg);
    cmp_ok($second->{api_calls}, '>', 0, 'a configuration error still does NOT arm the marker');
}

# And a recovered array is seen: the marker is dropped on the first answer.
{
    my $scfg = fresh_scfg();
    $fail_with = $TRANSPORT[0];
    call_status($scfg);
    $fail_with = undef;
    my $r = call_status({ %$scfg, tn_status_probe_backoff_s => 0 });
    ok($r->{active}, 'with the backoff disabled a recovered array is seen at once');
}

done_testing();
