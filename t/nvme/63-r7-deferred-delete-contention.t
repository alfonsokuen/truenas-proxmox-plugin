#!/usr/bin/perl
# idk31 r7 (rev4-astra B08/B09): two deferred-delete workers of one NVMe free
# run as two real PROCESSES and really contend for the storage lock.
#
# A barrier makes worker B ask for the lock while worker A holds it, after A
# has pinned and read generation 101 and before A deletes it. Then A deletes
# 101 and the allocator reuses the name for generation 202 (under the same
# lock, as PVE allocates). B must have waited (or aborted) on the lock, and
# only 101 may be deleted: 202 survives.
#
# The storage lock is the plugin's own cluster_lock_storage wrapper over a
# lock that excludes across processes the way pmxcfs does (an atomic mkdir,
# polled until a timeout). Without the lock around each delete attempt, B
# reads 101 before A deletes it and then deletes by name what is now 202:
# deletes=[101,202]. That run is recorded in INFORME7.md.
use strict;
use warnings;
use Test::More;
use FindBin;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use IO::Handle;
use IO::Select;
use JSON::PP qw(encode_json);
use POSIX qw(_exit);
use Time::HiRes qw(time sleep);

require "$FindBin::Bin/../../TrueNASPlugin.pm";
my $pkg = 'PVE::Storage::Custom::TrueNASPlugin';
my $uuid = '11111111-2222-3333-4444-555555555555';
my $name = 'vm-101-disk-0';
my $vol = "vol-$name-ns$uuid";
my $ds = "tank/pve/$name";
my $scfg = { storeid => 'store', tn_dataset => 'tank/pve', tn_transport_mode => 'nvme-tcp',
    tn_subsystem_nqn => 'nqn.test' };
my $root = tempdir(CLEANUP => 1);
make_path("$root/nodes/local/qemu-server");
my ($ZVOL, $DELETES, $EVENTS, $LOCKDIR) =
    ("$root/zvol", "$root/deletes", "$root/events", "$root/lock-storage-store");

sub slurp_lines { open(my $fh, '<', $_[0]) or return (); chomp(my @l = <$fh>); return @l }
sub append_line { open(my $fh, '>>', $_[0]) or die "$_[0]: $!"; print {$fh} "$_[1]\n"; close($fh) or die $! }
sub write_zvol { open(my $fh, '>', $ZVOL) or die $!; print {$fh} $_[0]; close($fh) or die $! }
sub current_zvol { my ($g) = slurp_lines($ZVOL); return $g }

open(my $vmlist, '>', "$root/.vmlist") or die $!;
print {$vmlist} encode_json({ version => 1, ids => {} });
close($vmlist);

no strict 'refs';
no warnings 'redefine', 'once';
${"${pkg}::_PRUNE_PVE_ROOT"} = $root;
$INC{'PVE/Cluster.pm'} = $INC{'PVE/INotify.pm'} = __FILE__;
*PVE::Cluster::check_cfs_quorum = sub { 1 };
*PVE::INotify::nodename = sub { 'local' };
*PVE::Storage::config = sub { {} };
*PVE::Storage::storage_config = sub { { tn_storage_lock_timeout => 20, tn_op_budget_s => 0 } };
local *{"${pkg}::_log"} = sub {};
local *{"${pkg}::_defer_after_lock"} = sub {};
local *{"${pkg}::_invalidate_status_capacity_cache"} = sub {};
local *{"${pkg}::_udev_settle_bounded"} = sub {};
local *{"${pkg}::_backoff_sleep"} = sub {};
local *{"${pkg}::_nvme_reap_orphan_namespaces"} = sub { 0 };
local *{"${pkg}::_nvme_find_pending_free_zvols"} = sub { [] };
local *{"${pkg}::_nvme_pending_free_mark"} = sub {};
local *{"${pkg}::_nvme_pending_free_clear_if_exported"} = sub {};
local *{"${pkg}::_handle_api_result_with_job_support"} = sub { { success => 1 } };
local *{"${pkg}::_nvme_find_device_by_subsystem"} = sub {
    return { selector_outcome => 'publication_mismatch', enumeration_complete => 1 };
};
local *{"${pkg}::_nvme_delete_namespace"} = sub {};
local *{"${pkg}::_api_call"} = sub { die "unexpected RPC $_[1]" };

# The base class lock (what pmxcfs provides under the plugin's wrapper):
# exclusive across processes, waits up to the timeout, then dies like PVE.
local *PVE::Storage::Plugin::cluster_lock_storage = sub {
    my (undef, $storeid, undef, $timeout, $func, @param) = @_;
    my $deadline = time() + ($timeout // 20);
    my $contended = 0;
    until (mkdir $LOCKDIR) {
        die "cannot acquire lock '$storeid' - got timeout\n" if time() > $deadline;
        append_line($EVENTS, "contended $$") if !$contended++;
        sleep 0.02;
    }
    append_line($EVENTS, "acquire $$");
    my $result = eval { $func->(@param) };
    my $err = $@;
    append_line($EVENTS, "release $$");
    rmdir $LOCKDIR or die "cannot release lock: $!";
    die $err if $err;
    return $result;
};

# The array, shared by the processes through files.
our $on_identity_read;
local *{"${pkg}::_tn_dataset_get"} = sub {
    my (undef, undef, $opts) = @_;
    my $guid = current_zvol();
    # Only the generation reads ask for properties. Fire after the answer was
    # taken: the caller has read the generation and is about to act on it.
    if ($opts && $opts->{extra} && $opts->{extra}{properties} && $on_identity_read) {
        my $hook = $on_identity_read;
        undef $on_identity_read;
        $hook->();
    }
    die "[ENOENT] InstanceNotFound\n" if !defined $guid;
    return { id => $ds, children => [], guid => { rawvalue => $guid } };
};
local *{"${pkg}::_api_call_mutate"} = sub {
    die "unexpected mutation $_[1]" unless $_[1] eq 'pool.dataset.delete';
    my $guid = current_zvol();
    die "[ENOENT] InstanceNotFound\n" if !defined $guid;
    append_line($DELETES, $guid);
    unlink $ZVOL or die $!;
    return 1;
};

# Barrier: children report on one pipe, each waits for its own go line.
pipe(my $report_r, my $report_w) or die $!;
pipe(my $go_a_r, my $go_a_w) or die $!;
pipe(my $go_b_r, my $go_b_w) or die $!;
$_->autoflush(1) for $report_w, $go_a_w, $go_b_w;
sub tell_parent { print {$report_w} "$_[0]\n" }
sub wait_for_go { my $line = readline($_[0]); die "barrier broken\n" unless defined $line }

sub run_child {
    my ($role, $work) = @_;
    my $pid = fork();
    die "fork failed: $!" unless defined $pid;
    return $pid if $pid;
    alarm(60);
    my $ok = eval { $work->(); 1 };
    tell_parent($ok ? "$role ok" : "$role died " . ($@ =~ s/\n/ /gr));
    _exit($ok ? 0 : 1);
}

my %seen;
my $select = IO::Select->new($report_r);
sub wait_report {
    my ($want, $limit) = @_;
    my $deadline = time() + $limit;
    until ($want->()) {
        my $left = $deadline - time();
        return 0 if $left <= 0;
        next unless $select->can_read($left > 0.1 ? 0.1 : $left);
        my $line = readline($report_r);
        chomp($line) if defined $line;
        $seen{$line} = time() if defined $line;
    }
    return 1;
}
sub b_contended_on_a {
    my ($a_pid) = @_;
    return 0 unless -d $LOCKDIR;
    return scalar grep { /^contended / && !/ \Q$a_pid\E$/ } slurp_lines($EVENTS);
}

write_zvol('101');
my $worker_a = $pkg->free_image('store', $scfg, $vol, 0, 'raw');
my $worker_b = $pkg->free_image('store', $scfg, $vol, 0, 'raw');
is(ref($worker_a) . ref($worker_b), 'CODECODE', 'both frees pinned generation 101 and returned a worker');

my $a_pid = run_child('A', sub {
    local $on_identity_read = sub { tell_parent('A read'); wait_for_go($go_a_r) };
    $worker_a->('UPID:a');
    # The allocator reuses the name, under the storage lock as PVE does.
    $pkg->cluster_lock_storage('store', 1, undef, sub { write_zvol('202') if !defined current_zvol() });
    tell_parent('A allocated 202');
});
ok(wait_report(sub { $seen{'A read'} }, 20), 'A pinned 101, read it and paused before deleting');
my $a_held = -d $LOCKDIR;

my $b_pid = run_child('B', sub {
    local $on_identity_read = sub { tell_parent('B read'); wait_for_go($go_b_r) };
    $worker_b->('UPID:b');
});
# B either queues on the lock A holds, or (no lock) reads 101 right away.
wait_report(sub { b_contended_on_a($a_pid) || $seen{'B read'} }, 20);
my $b_contended = b_contended_on_a($a_pid);
ok($a_held && $b_contended, 'B asked for the storage lock while A held it');
ok(!$seen{'B read'}, 'B did not read the generation while A held the lock');

print {$go_a_w} "go\n";
# Release B once it has read: at once when it had to queue on the lock (A may
# still need the lock to allocate), otherwise only after the reuse as 202.
wait_report(sub { $seen{'B read'} && ($b_contended || $seen{'A allocated 202'}) }, 40);
print {$go_b_w} "go\n";
wait_report(sub { ($seen{'A ok'} || grep { /^A died/ } keys %seen)
                && ($seen{'B ok'} || grep { /^B died/ } keys %seen) }, 40);
waitpid($_, 0) for $a_pid, $b_pid;

my @events = slurp_lines($EVENTS);
diag("lock events: @events");
ok($seen{'A ok'}, 'worker A deleted its generation and completed')
    or diag(join(' | ', grep { /^A / } keys %seen));
ok($seen{'B ok'} || (grep { /^B died .*got timeout/ } keys %seen),
    'worker B waited for the lock (or aborted on its timeout)')
    or diag(join(' | ', grep { /^B / } keys %seen));
my @b_acquired = grep { /^acquire \Q$b_pid\E$/ } @events;
my ($first_a_release) = grep { $events[$_] eq "release $a_pid" } 0 .. $#events;
my ($first_b_acquire) = grep { $events[$_] eq "acquire $b_pid" } 0 .. $#events;
ok(!@b_acquired || (defined $first_a_release && $first_b_acquire > $first_a_release),
    'B only got the lock after A released it');
is_deeply([slurp_lines($DELETES)], ['101'], 'deletes=[101]: no pool.dataset.delete reached generation 202');
is(current_zvol(), '202', 'the zvol the allocator created survives');
ok(!-d $LOCKDIR, 'the lock is free at the end');

done_testing;
