#!/usr/bin/perl
# volume_snapshot: pool.snapshot.create is not idempotent, so it must not be
# replayed after a lost response (the replay answers "already exists" and PVE
# is told the snapshot failed while it exists on the array - a ghost that then
# breaks the next vzdump with a stray @vzdump). The call runs with retry_max 0
# and, when it fails, the answer comes from the pool: if the snapshot is there
# the postcondition holds and the operation succeeded; if it is not (or the
# query itself fails) the ORIGINAL error is what the caller sees.
#
# Run with:  prove -v t/nvme/35-snapshot-create-lost-response.t
use strict;
use warnings;
use Test::More;
use FindBin;

my $PLUGIN = "$FindBin::Bin/../../TrueNASPlugin.pm";
unless (eval { require $PLUGIN; 1 }) {
    plan skip_all => "cannot load TrueNASPlugin.pm (needs PVE perl modules): $@";
}
my $PKG = 'PVE::Storage::Custom::TrueNASPlugin';
my $f = $PKG->can('volume_snapshot') or BAIL_OUT('missing volume_snapshot');

my (@calls, @logs, $create_error, $query_answer, $query_dies);
{
    no strict 'refs'; no warnings 'redefine';
    *{"${PKG}::_log"} = sub { push @logs, $_[3] // ''; 1 };
    *{"${PKG}::parse_volname"} = sub { (undef, 'vm-100-disk-0') };
    *{"${PKG}::cluster_lock_storage"} = sub { my ($c, $s, $t, $to, $code) = @_; $code->() };
    *{"${PKG}::_handle_api_result_with_job_support"} = sub { { success => 1 } };
    *{"${PKG}::_api_call_mutate"} = sub {
        my ($scfg, $method, $params, $opts) = @_;
        push @calls, { method => $method, opts => $opts };
        die $create_error if defined $create_error;
        return 1;
    };
    *{"${PKG}::_api_call"} = sub {
        my ($scfg, $method, $params) = @_;
        push @calls, { method => $method, params => $params };
        die "query failed\n" if $query_dies;
        return $query_answer;
    };
}
my $scfg = { tn_dataset => 'tank/pve' };
sub run { @calls = (); @logs = (); my $ok = eval { $f->($PKG, $scfg, 'tn', 'vm-100-disk-0', 's1'); 1 }; return ($ok, $@) }

# 1. success: no replay protection needed, and no postcondition query
($create_error, $query_dies, $query_answer) = (undef, 0, undef);
my ($ok) = run();
ok($ok, 'success path succeeds');
is((grep { $_->{method} eq 'pool.snapshot.query' } @calls), 0, '  ...without asking the pool');
my ($create) = grep { $_->{method} eq 'pool.snapshot.create' } @calls;
is($create->{opts}{retry_opts}{retry_max}, 0, 'create runs with retry_opts.retry_max => 0 (never replayed)');

# 2. lost response, snapshot exists -> operation succeeded
($create_error, $query_dies, $query_answer) = ("WS read failed: Broken pipe\n", 0, [ { id => 'tank/pve/vm-100-disk-0@s1' } ]);
my ($ok2, $err2) = run();
ok($ok2, 'lost response but the snapshot is on the pool: treated as created') or diag $err2;
my ($q) = grep { $_->{method} eq 'pool.snapshot.query' } @calls;
like(JSON::PP::encode_json($q->{params} // []), qr{tank/pve/vm-100-disk-0\@s1}, '  ...the query asks for exactly this snapshot id');

# 3. failure and the snapshot is NOT there -> original error surfaces
($create_error, $query_dies, $query_answer) = ("WS read failed: Broken pipe\n", 0, []);
my ($ok3, $err3) = run();
ok(!$ok3, 'failure and no snapshot: still dies');
like($err3, qr/WS read failed/, '  ...with the original error');

# 4. failure and the postcondition query ALSO fails -> original error, never a guess of success
($create_error, $query_dies, $query_answer) = ("WS read failed: Broken pipe\n", 1, undef);
my ($ok4, $err4) = run();
ok(!$ok4, 'failure and an unanswerable query: dies');
like($err4, qr/WS read failed/, '  ...with the original error, not the query one');

# 5. a definitive verdict from the server is not "maybe it worked"
($create_error, $query_dies, $query_answer) = ("[EINVAL] bad name\n", 0, [ { id => 'tank/pve/vm-100-disk-0@s1' } ]);
my ($ok5) = run();
ok(!$ok5, 'EINVAL from the server is a failure even if a same-named snapshot exists');

# 6. "already exists" with retries off can only mean the snapshot was there BEFORE
#    this call (a ghost of an earlier failure, or another creator). Reporting
#    success would hand PVE a snapshot that holds old data as if it were new.
for my $exists_err ("[EEXIST] snapshot already exists\n", "ZFSPathAlreadyExistsException: tank/pve/vm-100-disk-0\@s1\n", "EZFS_EXISTS\n") {
    ($create_error, $query_dies, $query_answer) = ($exists_err, 0, [ { id => 'tank/pve/vm-100-disk-0@s1' } ]);
    my ($ok6, $err6) = run();
    ok(!$ok6, 'already exists is a failure, never "created": ' . substr($exists_err, 0, 30));
    like($err6, qr/exist/i, '  ...with the server error');
    is((grep { $_->{method} eq 'pool.snapshot.query' } @calls), 0, '  ...and without a postcondition query');
}

# 7. a postcondition answer must be about THIS snapshot
($create_error, $query_dies, $query_answer) = ("WS read failed: Broken pipe\n", 0, [ { id => 'tank/pve/vm-100-disk-0@other' } ]);
my ($ok7, $err7) = run();
ok(!$ok7, 'a list whose id is not the requested snapshot does not count as created');
like($err7, qr/WS read failed/, '  ...original error kept');

# 8. an unanswerable postcondition query is said out loud, not swallowed
($create_error, $query_dies, $query_answer) = ("WS read failed: Broken pipe\n", 1, undef);
run();
ok((grep { /postcondition query failed/i && /query failed/ } @logs), 'the failure of the postcondition query is logged');
done_testing;
