#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use FindBin;
use File::Path qw(make_path);
use File::Temp qw(tempdir);

my $PLUGIN = "$FindBin::Bin/../../TrueNASPlugin.pm";
unless (eval { require $PLUGIN; 1 }) {
    plan skip_all => "cannot load TrueNASPlugin.pm (needs PVE perl modules): $@";
}
my $PKG = 'PVE::Storage::Custom::TrueNASPlugin';
my $find = $PKG->can('_nvme_find_device_by_subsystem') or BAIL_OUT('missing selector');
my $check = $PKG->can('_nvme_check_devices_in_use') or BAIL_OUT('missing in-use gate');
my $read_attr = $PKG->can('_nvme_sysfs_attr') or BAIL_OUT('missing sysfs reader');
my $NQN = 'nqn.2011-06.com.truenas:uuid:test:pve';
my $UUID = '11111111-2222-3333-4444-555555555555';
my $OTHER = 'aaaaaaaa-0000-0000-0000-000000000001';
my $scfg = { tn_dataset => 'tank/pve', tn_api_host => '198.51.100.7',
    tn_transport_mode => 'nvme-tcp', tn_subsystem_nqn => $NQN };

sub put {
    my ($path, $value) = @_;
    (my $dir = $path) =~ s{/[^/]+$}{};
    make_path($dir);
    open(my $fh, '>', $path) or die "$path: $!";
    print {$fh} "$value\n";
    close($fh) or die "$path: $!";
}

sub device {
    my ($root, $uuid, $devnum) = @_;
    put("$root/block/nvme1n1/device/subsysnqn", $NQN);
    put("$root/block/nvme1n1/nsid", 9);
    put("$root/block/nvme1n1/uuid", $uuid);
    put("$root/block/nvme1n1/dev", $devnum // '259:1');
    make_path("$root/block/nvme1n1/holders");
}

sub world {
    my ($uuid) = @_;
    my $root = tempdir(CLEANUP => 1);
    put("$root/class/nvme-subsystem/nvme-subsys1/subsysnqn", $NQN);
    put("$root/mountinfo", '26 1 8:3 / / rw - ext4 /dev/sda3 rw');
    make_path("$root/proc");
    device($root, $uuid);
    return $root;
}

sub replace_device {
    my ($root, $uuid, $number) = @_;
    # Keep the retired directory alive so its inode cannot be immediately
    # recycled by the fixture's filesystem.
    rename("$root/block/nvme1n1", "$root/retired-$number") or die "retire device: $!";
    device($root, $uuid);
}

my (@mutations, $lookups);
no strict 'refs';
no warnings 'once', 'redefine';
local *{"${PKG}::_log"} = sub { 1 };
local *{"${PKG}::_nvme_get_namespace_selector_metadata"} = sub {
    ++$lookups;
    return { namespace => { device_uuid => $UUID, nsid => 7, subsys => 1 },
        api_namespace_count => 2, metadata_state => 'ok' };
};
local *{"${PKG}::_assert_nvme_cluster_unreferenced"} = sub { 1 };
local *{"${PKG}::_assert_no_child_datasets"} = sub { 1 };
local *{"${PKG}::_defer_after_lock"} = sub { 1 };
local *{"${PKG}::_nvme_pending_free_mark"} = sub { 1 };
local *{"${PKG}::_nvme_delete_namespace"} = sub { push @mutations, 'namespace'; 1 };
local *{"${PKG}::_delete_dataset_with_retry"} = sub { push @mutations, 'dataset'; 1 };

for my $attr ('class/nvme-subsystem/nvme-subsys1/subsysnqn',
              'block/nvme1n1/device/subsysnqn', 'block/nvme1n1/nsid') {
    my $root = world($OTHER);
    unlink("$root/$attr") or die "remove $attr: $!";
    local ${"${PKG}::_NVME_SYSFS"} = $root;
    my $result = $find->($scfg, $UUID);
    is($result->{selector_outcome}, 'enumeration_failed', "missing $attr fails enumeration");
}

{
    my $root = world($OTHER);
    local ${"${PKG}::_NVME_SYSFS"} = $root;
    my $reads = 0;
    $lookups = 0;
    local *{"${PKG}::_nvme_sysfs_attr"} = sub {
        my @result = $read_attr->(@_);
        if ($_[0] eq "$root/block/nvme1n1/uuid" && ++$reads == 1) {
            replace_device($root, $UUID, 1);
        }
        return @result;
    };
    my $result = $find->($scfg, $UUID);
    is($result->{selected_device_path}, '/dev/nvme1n1', 'a stable retry selects the replacement namespace');
    is($reads, 2, 'same-name replacement retries the sysfs walk');
    is($lookups, 1, 'selector metadata is fetched once after the walk stabilizes');
}

{
    my $root = world($OTHER);
    local ${"${PKG}::_NVME_SYSFS"} = $root;
    my $reads = 0;
    local *{"${PKG}::_nvme_sysfs_attr"} = sub {
        my @result = $read_attr->(@_);
        replace_device($root, $OTHER, ++$reads) if $_[0] eq "$root/block/nvme1n1/uuid";
        return @result;
    };
    my $result = $find->($scfg, $UUID);
    is($result->{selector_outcome}, 'enumeration_failed', 'a perpetually changing walk fails closed');
    is($result->{mismatch_reason}, 'sysfs_changed_during_walk', 'the selector reports the race');
    is($reads, 3, 'the unstable walk gets at most three attempts');
    my $ok = eval { $PKG->free_image('store', $scfg, "vol-vm-101-disk-0-ns$UUID", 0, 'raw'); 1 };
    ok(!$ok, 'free_image refuses deletion after an unstable walk');
    is_deeply(\@mutations, [], 'free_image does not delete the namespace or dataset');
}

for my $change (
    [ 'same-name device replacement', sub { replace_device($_[0], $UUID, 1) } ],
    [ 'changed major:minor', sub { put("$_[0]/block/nvme1n1/dev", '259:2') } ],
    [ 'new partition', sub { put("$_[0]/block/nvme1n1/nvme1n1p1/dev", '259:2') } ],
    [ 'new holder', sub { make_path("$_[0]/block/nvme1n1/holders/dm-0") } ],
) {
    my ($name, $mutate) = @$change;
    my $root = world($UUID);
    local ${"${PKG}::_NVME_SYSFS"} = $root;
    local ${"${PKG}::_NVME_MOUNTINFO"} = "$root/mountinfo";
    local ${"${PKG}::_NVME_PROC_ROOT"} = "$root/proc";
    local ${"${PKG}::_NVME_FUSER_RC"} = sub { $mutate->($root); return 1 };
    is($check->($scfg, '/dev/nvme1n1'), 1, "a $name during the in-use check reads as busy");
}

done_testing;
