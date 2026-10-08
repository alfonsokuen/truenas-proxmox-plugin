#!/usr/bin/perl
# The clone teardown runs inside the storage lock, under the operation's
# deadline. Its udevadm settle must be bounded by what is left of it, and the
# dataset-delete backoffs must not sleep past it: with the deadline spent there
# are no further retries, only the visible error.
#
# Run with:  prove -v t/nvme/36-teardown-deadline.t
use strict;
use warnings;
use Test::More;
use FindBin;

my $PLUGIN = "$FindBin::Bin/../../TrueNASPlugin.pm";
unless (eval { require $PLUGIN; 1 }) {
    plan skip_all => "cannot load TrueNASPlugin.pm (needs PVE perl modules): $@";
}
my $PKG = 'PVE::Storage::Custom::TrueNASPlugin';
my $scfg = { tn_dataset => 'tank/pve', tn_api_host => '198.51.100.7', tn_transport_mode => 'nvme-tcp',
             tn_subsystem_nqn => 'nqn.x:y' };
my $vol = 'vol-vm-101-disk-0-ns11111111-2222-3333-4444-555555555555';

my (@sleeps, @cmds, $deletes, $mode);
{
    no strict 'refs'; no warnings 'redefine';
    *{"${PKG}::_log"} = sub { 1 };
    *{"${PKG}::_nvme_delete_namespace"} = sub { 1 };
    *{"${PKG}::run_command"} = sub { push @cmds, join(' ', @{$_[0]}); 1 };
    *{"${PKG}::_handle_api_result_with_job_support"} = sub { { success => 1, result => 1 } };
    *{"${PKG}::_api_call_mutate"} = sub {
        $deletes++;
        die "[EBUSY] dataset is busy\n" if $mode eq 'ebusy';
        return 1;                                   # 'masked': says success
    };
    *{"${PKG}::_tn_dataset_get"} = sub { return { id => $_[1] } };   # still there
    # sleeping seam: record, never sleep
    *{"${PKG}::_backoff_sleep"} = sub { push @sleeps, $_[0]; };
}

sub teardown {
    my ($m, $deadline) = @_;
    ($mode, @sleeps, @cmds, $deletes) = ($m);
    $deletes = 0;
    no strict 'refs';
    local ${"${PKG}::_api_deadline"} = $deadline;
    my $ok = eval { $PKG->_teardown_snapshot_device($scfg, $vol, 's1'); 1 };
    return ($ok, $@);
}

for my $m ('ebusy', 'masked') {
    my ($ok, $err) = teardown($m, time() - 5);
    ok(!$ok, "$m, deadline spent: the teardown still fails visibly");
    like($err, qr/EBUSY|busy|masked/i, '  ...with the cause');
    is($deletes, 1, '  ...after ONE attempt, no retry past the deadline');
    is(scalar(@sleeps), 0, '  ...and no backoff wait at all');
    my ($settle) = grep { /udevadm settle/ } @cmds;
    like($settle // '', qr/--timeout=1\b/, '  ...and udevadm settle is bounded to 1 s');
}

{
    my ($ok) = teardown('ebusy', time() + 100);
    ok(!$ok, 'ebusy with time left: still fails after the retries');
    is($deletes, 3, '  ...but did use all 3 attempts');
    is(scalar(@sleeps), 2, '  ...with the 2 backoff waits');
    my ($settle) = grep { /udevadm settle/ } @cmds;
    like($settle // '', qr/--timeout=(?:[1-9]|10)\b/, '  ...settle bounded (<= 10 s) even with plenty of budget');
}

# The stop messages say the real attempt count and why it stopped, whichever path.
{
    my ($ok, $err) = teardown('ebusy', time() - 5);
    like($err, qr/after 1 attempt\(s\)/, 'busy + deadline spent before the first retry: says 1 attempt');
    like($err, qr/deadline/, '  ...and that the deadline cut it');
    ($ok, $err) = teardown('ebusy', undef);
    like($err, qr/after 3 attempt\(s\) \(retries exhausted\)/, 'busy, no deadline: 3 attempts, retries exhausted');
    unlike($err, qr/deadline/, '  ...and does not blame a deadline');
}

# The backoff itself can cross the deadline: the check before sleeping passes
# (1 s left), the wait takes longer, and the next attempt would start AFTER the
# deadline. A stub that really waits 2 s stands in for a backoff longer than the
# time left; no further attempt may start once the deadline is gone.
{
    no strict 'refs'; no warnings 'redefine';
    local *{"${PKG}::_backoff_sleep"} = sub { sleep 2 };
    for my $m ('ebusy', 'masked') {
        my ($ok, $err) = teardown($m, time() + 1);
        ok(!$ok, "$m: backoff crosses the deadline -> the teardown fails visibly");
        is($deletes, 1, '  ...and NO second attempt starts after the deadline');
        like($err, qr/after 1 attempt\(s\)/, '  ...the message says how many attempts there really were');
        like($err, qr/deadline/, '  ...and that the deadline cut it short');
        unlike($err, qr/after 3 attempts/, '  ...not the configured maximum');
    }
}

done_testing;
