#!/usr/bin/perl
# Run as root on the node to inspect devices and other guests' processes.
use strict;
use warnings;

package IDK::ReadOnlySmoke;

use Cwd qw(abs_path);
use Test::More;

my $plugin = 'PVE::Storage::Custom::TrueNASPlugin';
my $uuid_pattern = qr/\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/i;

sub running {
    my ($type, $vmid) = @_;
    my $command = $type eq 'qemu' ? '/usr/sbin/qm' : '/usr/sbin/pct';
    my $status;
    PVE::Tools::run_command([$command, 'status', $vmid], timeout => 5, outfunc => sub {
        $status = $1 if $_[0] =~ /\Astatus:\s*(running|stopped)\s*\z/;
    });
    die "Could not read status of guest $vmid\n" unless defined $status;
    return $status eq 'running';
}

sub active_volume {
    my ($type, $spec) = @_;
    my $key = $type eq 'qemu' ? 'file' : 'volume';
    my @properties = split /,/, $spec;
    for my $property (@properties) {
        return $1 if $property =~ /\A\Q$key\E=(.+)\z/;
    }
    return $properties[0] if @properties && $properties[0] !~ /=/;
    return undef;
}

sub subsystem_devices {
    my ($id, $scfg, $head_present) = @_;
    no warnings 'once';
    my $sys = $PVE::Storage::Custom::TrueNASPlugin::_NVME_SYSFS;
    my $paths = eval { [$plugin->can('_nvme_get_subsystem_device_paths')->($scfg, strict => 1)] };
    if (!$paths) {
        fail("$id enumeration_failed");
        diag($@);
        return {};
    }
    my %uuids;
    for my $path (@$paths) {
        my ($name) = $path =~ m{\A/dev/(nvme\d+(?:c\d+)?n\d+)\z};
        my ($uuid, $error) = $plugin->can('_nvme_sysfs_attr')->("$sys/block/$name/uuid", 1);
        if (!defined($uuid) || $uuid !~ $uuid_pattern) {
            fail("$id $path has a readable namespace UUID");
            diag($error) if defined $error;
            next;
        }
        $uuids{lc $uuid} = 1;
    }
    note("$id connected namespaces: " . scalar(keys %uuids));
    pass("$id connected namespace inventory") unless keys %uuids;

    my %devices;
    for my $uuid (sort keys %uuids) {
        # The selector reads namespace metadata. The activation path may
        # rescan, repair publication, or reconnect controllers.
        my $result = $plugin->can('_nvme_find_device_by_subsystem')->($scfg, $uuid);
        if ($result->{selector_outcome} eq 'enumeration_failed') {
            fail("$id $uuid enumeration_failed");
            diag($_) for @{ $result->{enumeration_errors} // [] };
            next;
        }
        my $head = $result->{selected_device_path} // '(unresolved)';
        next unless ok($head =~ m{\A/dev/nvme\d+n\d+\z} && $head_present->($head),
            "$id $uuid has an existing NVMe head $head");
        my $busy = $plugin->can('_nvme_check_devices_in_use')->($scfg, $head);
        $devices{$uuid} = [$head, $busy];
        note("$id $head is " . ($busy ? 'in use' : 'free'));
    }
    return \%devices;
}

sub run {
    my ($head_present) = @_;
    $head_present //= sub { -b $_[0] };
    require PVE::Storage;
    require PVE::Storage::Custom::TrueNASPlugin;
    require PVE::Cluster;
    require PVE::INotify;
    PVE::Cluster::cfs_update();
    my $ids = PVE::Storage::config()->{ids};
    die "Could not read the storage inventory\n" unless ref($ids) eq 'HASH';
    my %storages = map { $_ => $ids->{$_} } grep {
        ($ids->{$_}{type} // '') eq $plugin->type && ($ids->{$_}{tn_transport_mode} // '') eq 'nvme-tcp'
    } keys %$ids;
    plan(skip_all => 'No TrueNAS NVMe storage configured') unless keys %storages;
    my (%devices, %busy_paths);
    for my $id (sort keys %storages) {
        next unless ok($storages{$id}{tn_subsystem_nqn}, "$id has a configured subsystem NQN");
        $devices{$id} = subsystem_devices($id, $storages{$id}, $head_present);
        for my $device (values %{ $devices{$id} }) {
            $busy_paths{$device->[0]} = $device->[1];
        }
    }

    PVE::Cluster::cfs_update();
    my $guests = PVE::Cluster::get_vmlist()->{ids};
    die "Could not read the guest inventory\n" unless ref($guests) eq 'HASH';
    my $node = PVE::INotify::nodename();
    for my $vmid (sort keys %$guests) {
        my $guest = $guests->{$vmid};
        next unless $guest->{node} eq $node;
        my $type = $guest->{type};
        next unless $type eq 'qemu' || $type eq 'lxc';
        my $running = eval { running($type, $vmid) };
        if ($@) {
            fail("guest $vmid running status");
            diag($@);
            next;
        }
        next unless $running;
        my ($class, $disk_key);
        if ($type eq 'qemu') {
            require PVE::QemuConfig;
            $class = 'PVE::QemuConfig';
            $disk_key = qr/\A(?:ide|sata|scsi|virtio|efidisk|tpmstate)\d+\z/;
        } else {
            require PVE::LXC::Config;
            $class = 'PVE::LXC::Config';
            $disk_key = qr/\A(?:rootfs|mp\d+)\z/;
        }
        my $conf = $class->load_config($vmid);
        for my $key (sort grep { /$disk_key/ } keys %$conf) {
            my $volume = active_volume($type, $conf->{$key}) // next;
            if ($volume =~ m{\A/dev/}) {
                my $path = abs_path($volume) // next;
                $path =~ s{\A(/dev/nvme\d+n\d+)p\d+\z}{$1};
                next unless exists $busy_paths{$path};
                ok($busy_paths{$path}, "guest $vmid $key $path is in use");
                next;
            }
            my ($id, $volname) = split /:/, $volume, 2;
            next unless defined($volname) && exists $storages{$id};
            my $label = "guest $vmid $key $volume";
            my $uuid = eval {
                my (undef, $zname, undef, undef, undef, undef, undef, $known) = $plugin->parse_volname($volname);
                $plugin->can('_resolve_nvme_uuid')->($storages{$id}, $zname, $known);
            };
            if (!defined $uuid) {
                fail("$label has a namespace UUID");
                diag($@) if $@;
                next;
            }
            my $device = $devices{$id}{lc $uuid};
            ok($device && $device->[1], "$label is in use");
        }
    }
    done_testing();
}

if (!caller) {
    eval { run(); 1 } or BAIL_OUT($@ || 'Could not complete the smoke');
}
1;
