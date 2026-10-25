#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use FindBin;
use JSON::PP ();

my $PLUGIN = "$FindBin::Bin/../../TrueNASPlugin.pm";
unless (eval { require $PLUGIN; 1 }) {
    plan skip_all => "cannot load TrueNASPlugin.pm (needs PVE perl modules): $@";
}
my $PKG = 'PVE::Storage::Custom::TrueNASPlugin';
my $status = $PKG->can('status') or BAIL_OUT('missing status');
my $dataset_get = $PKG->can('_tn_dataset_get') or BAIL_OUT('missing _tn_dataset_get');
my (@calls, $answer, $fail_once, $other_error);
{
    no strict 'refs'; no warnings 'redefine';
    *{"${PKG}::_api_call"} = sub {
        my ($scfg, $method, $params, $opts) = @_;
        push @calls, { method => $method, params => $params, opts => $opts };
        if ($fail_once && exists($params->[1])) {
            $fail_once = 0;
            die "[EINVAL] Invalid params: validation failed\n";
        }
        die $other_error if defined $other_error;
        return $answer if $method eq 'pool.dataset.get_instance';
        return {};
    };
    *{"${PKG}::_log"} = sub { 1 };
    *{"${PKG}::_get_cached"} = sub { undef };
    *{"${PKG}::_read_status_stamp"} = sub { undef };
    *{"${PKG}::_write_status_stamp"} = sub { 1 };
    *{"${PKG}::_set_cache"} = sub { 1 };
    *{"${PKG}::_tn_pool_health"} = sub { undef };
}
my $scfg = { tn_dataset => 'tank/pve', tn_host => 'array-status-test', tn_status_budget_s => 8 };
my $full = {
    id => 'tank/pve', name => 'tank/pve', pool => 'tank', type => 'FILESYSTEM',
    mountpoint => '/mnt/tank/pve', children => [ { id => 'tank/pve/child' } ],
    user_properties => [], used => { parsed => 1000, rawvalue => '1000' },
    # No top-level `written`: that is what the real 25.10 array answers (measured
    # on tn-prod). status() therefore reports `used`, and the minimal request
    # must not change that by asking for `written`.
    available => { parsed => 9000, rawvalue => '9000' }, quota => { parsed => 0, rawvalue => '0' },
};
my $minimal = { %$full };
$minimal->{children} = [];
$answer = $full;
@calls = ();
my @full_status = $status->($PKG, 'store1', $scfg, {});
my ($status_call) = grep { $_->{method} eq 'pool.dataset.get_instance' } @calls;
is_deeply($status_call->{params}[1], { extra => {
    retrieve_children => JSON::PP::false, properties => [qw(used available quota)],
}}, 'status requests exactly its capacity properties');
ok(!(grep { $_ eq 'written' } @{ $status_call->{params}[1]{extra}{properties} }),
   'status does NOT request `written`: the array would return the parent dataset own written and status() prefers it');

# What asking for `written` would have done, on the real array's numbers: the
# parent's own written is tiny, status() prefers it, and the pool looks empty.
{
    my $with_written = { %$full, written => { parsed => 130944, rawvalue => '130944' } };
    $answer = $with_written;
    my @bad = $status->($PKG, 'store1', { %$scfg, tn_host => 'array-status-written' }, {});
    isnt($bad[2], $full_status[2], 'control: a `written` in the answer DOES change status() (why it is not requested)');
    $answer = $full;
}
$answer = $minimal;
@calls = ();
my @minimal_status = $status->($PKG, 'store1', { %$scfg, tn_host => 'array-status-minimal' }, {});
is_deeply(\@minimal_status, \@full_status, 'status result is identical with complete and minimal responses');

my $preflight = $PKG->can('_preflight_check_alloc') or BAIL_OUT('missing _preflight_check_alloc');
@calls = ();
$preflight->({ %$scfg, tn_host => 'array-preflight-test', tn_transport_mode => 'nvme-tcp',
    tn_subsystem_nqn => 'nqn.2026-01.test:preflight' }, 1000);
my ($preflight_call) = grep { $_->{method} eq 'pool.dataset.get_instance' } @calls;
is_deeply($preflight_call->{params}[1], { extra => {
    retrieve_children => JSON::PP::false, properties => [qw(available)],
}}, 'allocation preflight requests only available');

@calls = ();
$dataset_get->($scfg, 'tank/pve');
my ($plain_call) = grep { $_->{method} eq 'pool.dataset.get_instance' } @calls;
ok(!exists($plain_call->{params}[1]), 'without extra, the original one-parameter request is preserved');

my $fallback_scfg = { %$scfg, tn_host => 'array-fallback-test' };
$fail_once = 1;
@calls = ();
my $fallback_result = $dataset_get->($fallback_scfg, 'tank/pve', { extra => {
    retrieve_children => JSON::PP::false, properties => [qw(available)],
}});
is($fallback_result, $minimal, 'EINVAL fallback returns the unfiltered result');
is(scalar(grep { $_->{method} eq 'pool.dataset.get_instance' } @calls), 2, 'EINVAL retries once without extra');
ok(!exists($calls[1]{params}[1]), 'fallback retry omits extra');
@calls = ();
$dataset_get->($fallback_scfg, 'tank/pve', { extra => {
    retrieve_children => JSON::PP::false, properties => [qw(available)],
}});
is(scalar(grep { $_->{method} eq 'pool.dataset.get_instance' } @calls), 1, 'unsupported extra is remembered per host');
ok(!exists($calls[0]{params}[1]), 'remembered host uses plain request');
$other_error = "permission denied\n";
@calls = ();
my $other_ok = eval {
    $dataset_get->({ %$scfg, tn_host => 'array-other-error-test' }, 'tank/pve', { extra => {
        retrieve_children => JSON::PP::false, properties => [qw(available)],
    }});
    1;
};
my $other_err = $@;
$other_error = undef;
ok(!$other_ok, 'non-validation errors still propagate');
is($other_err, "permission denied\n", 'non-validation error text is preserved');
is(scalar(@calls), 1, 'non-validation errors do not trigger a retry');
done_testing;
