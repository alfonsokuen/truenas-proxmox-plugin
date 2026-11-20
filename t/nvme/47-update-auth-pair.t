#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use FindBin;

require "$FindBin::Bin/../../TrueNASPlugin.pm";
my $pkg = 'PVE::Storage::Custom::TrueNASPlugin';
my (@writes, @warnings, $legacy_config);
{
    no strict 'refs'; no warnings 'redefine', 'once';
    *{"${pkg}::_tn_set_secret"} = sub { push @writes, [@_] };
    *{"${pkg}::_tn_cluster_secrets_ready"} = sub { { ready => 1 } };
    *{"${pkg}::_tn_strip_inline_if_cluster_ready"} = sub {};
    *{"${pkg}::syslog"} = sub { my (undef, $format, @args) = @_; push @warnings, sprintf($format, @args) };
    *PVE::Storage::config = sub { {} };
    *PVE::Storage::storage_config = sub { $legacy_config };
}

for my $mode (qw(scram scram-plus)) {
    @writes = ();
    ok(!eval { $pkg->on_update_hook_full('tn', {}, { tn_auth_mechanism => $mode }, [], { tn_api_key => 'test-key' }); 1 },
        "#16 refuses $mode without a username");
    like($@, qr/tn_api_username.*set both/is, '#16 gives actionable guidance');
    is(scalar @writes, 0, '#16 validates before changing secrets');
    my $valid = { tn_auth_mechanism => $mode, tn_api_username => 'api-user' };
    ok(!eval { $pkg->on_update_hook_full('tn', $valid, {}, ['tn_api_username'], {}); 1 },
        "#16 refuses to delete the username while $mode stays enabled");
    ok(eval { $pkg->on_update_hook_full('tn', {}, $valid, [], {}); 1 },
        '#16 permits both options in one edit') or diag $@;
    ok(eval { $pkg->on_update_hook_full('tn', $valid, { tn_auth_mechanism => 'auto' }, ['tn_api_username'], {}); 1 },
        '#16 permits returning to auto and dropping the username') or diag $@;
}

ok(eval { $pkg->on_update_hook_full('tn', { tn_auth_mechanism => 'scram' }, { nodes => 'other' }, [], {}); 1 },
    '#16 permits unrelated edits on existing invalid configs') or diag $@;
like(join(' ', @warnings), qr/tn_api_username/, '#16 logs the existing invalid configuration');
$legacy_config = {};
ok(!eval { $pkg->on_update_hook('tn', { tn_auth_mechanism => 'scram-plus' }); 1 },
    '#16 legacy hook still refuses an incomplete SCRAM pair');
$legacy_config = { tn_api_username => 'api-user' };
ok(eval { $pkg->on_update_hook('tn', { tn_auth_mechanism => 'scram' }); 1 },
    '#16 legacy hook sees the current username') or diag $@;

done_testing;
