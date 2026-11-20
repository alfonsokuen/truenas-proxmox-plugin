#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use FindBin;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use lib "$FindBin::Bin/lib";
use IDK::TestNVMeSysfs qw(write_attr);

my $fake_dev;
BEGIN {
    *CORE::GLOBAL::opendir = sub (*$) {
        my $path = defined($fake_dev) && $_[1] eq '/dev' ? $fake_dev : $_[1];
        CORE::opendir($_[0], $path);
    };
}

require "$FindBin::Bin/../../TrueNASPlugin.pm";
my $pkg = 'PVE::Storage::Custom::TrueNASPlugin';
my $vol = 'vol-vm-100-disk-0-ns11111111-2222-3333-4444-555555555555';
my $nqn = 'nqn.2024-01.test:pve';
my $cfg = { tn_dataset => 'tank/pve', tn_transport_mode => 'nvme-tcp', tn_subsystem_nqn => $nqn };
my $root = tempdir(CLEANUP => 1);
$fake_dev = "$root/dev";
my $subsystem = "$root/sys/class/nvme-subsystem/nvme-subsys0";
make_path("$subsystem/nvme99", "$fake_dev/nvme98", "$fake_dev/nvme97");
write_attr("$root/sys/class/nvme/nvme98/subsysnqn", 'nqn.2024-01.test:unrelated');
write_attr("$root/sys/class/nvme/nvme97/subsysnqn", $nqn);
open(my $fh, '>', "$subsystem/subsysnqn") or die $!;
print {$fh} "$nqn\n";
close($fh) or die $!;

my @events;
my $targeted_fails = 1;
my $rollback_fails = 0;
no strict 'refs';
no warnings 'redefine';
local ${"${pkg}::_NVME_SYSFS"} = "$root/sys";
local *{"${pkg}::_log"} = sub {};
local *{"${pkg}::_tn_dataset_get"} = sub { { volsize => 1024, volblocksize => 512 } };
local *{"${pkg}::_api_call"} = sub { push @events, $_[1]; return {} };
local *{"${pkg}::_invalidate_status_capacity_cache"} = sub {};
local *{"${pkg}::cluster_lock_storage"} = sub { $_[4]->() };
local *{"${pkg}::volume_rollback_is_possible"} = sub { 1 };
local *{"${pkg}::_tn_snapshot_rollback"} = sub {
    push @events, 'pool.snapshot.rollback';
    die "rollback failed\n" if $rollback_fails;
};
local *{"${pkg}::_try_run"} = sub {
    my ($cmd) = @_;
    push @events, join ' ', @$cmd;
    return !($targeted_fails && $cmd->[2] eq '/dev/nvme99');
};
local *{"${pkg}::run_command"} = sub { push @events, join ' ', @{$_[0]} };
local *{'PVE::Tools::run_command'} = sub { push @events, join ' ', @{$_[0]} };

is($pkg->volume_resize($cfg, 'store', $vol, 2048), 2, 'resize returns the new size in KiB');
is_deeply(\@events, ['pool.dataset.update', 'nvme ns-rescan /dev/nvme99',
    'nvme ns-rescan /dev/nvme97', 'udevadm settle'],
    'failed targeted NVMe rescan falls back only to a controller with the same NQN');

$targeted_fails = 0;
@events = ();
$pkg->volume_resize($cfg, 'store', $vol, 2048);
is_deeply(\@events, ['pool.dataset.update', 'nvme ns-rescan /dev/nvme99', 'udevadm settle'],
    'successful targeted rescan does not touch unrelated controllers');

@events = ();
$pkg->volume_snapshot_rollback($cfg, 'store', $vol, 'snap');
is_deeply(\@events, ['pool.snapshot.rollback', 'nvme ns-rescan /dev/nvme99', 'udevadm settle'],
    'successful NVMe rollback rescans the target before settling udev');

$targeted_fails = 1;
{
    local *{"${pkg}::_try_run"} = sub {
        my ($cmd) = @_;
        push @events, join ' ', @$cmd;
        return $cmd->[2] eq '/dev/nvme98';
    };
    @events = ();
    my $ok = eval { $pkg->volume_snapshot_rollback($cfg, 'store', $vol, 'snap'); 1 };
    ok(!$ok, 'rollback reports an error when no controller of the target was rescanned');
    like($@, qr/no NVMe controller rescanned/i, 'rollback explains why the local size was not refreshed');
    is(scalar(grep { /nvme98/ } @events), 0, 'rollback never rescans the unrelated controller');
    is(scalar(grep { /pool\.snapshot\.rollback/ } @events), 1, 'rollback mutation is not retried');
}

$rollback_fails = 1;
@events = ();
eval { $pkg->volume_snapshot_rollback($cfg, 'store', $vol, 'snap') };
like($@, qr/rollback failed/, 'rollback failure reaches caller');
is_deeply(\@events, ['pool.snapshot.rollback'], 'a failed rollback does not rescan');
done_testing;
