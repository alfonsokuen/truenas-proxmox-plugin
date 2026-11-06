#!/usr/bin/perl
# _nvme_cap_max_io and a queue it cannot write.
#
# The cap (#96) only has to hold: no queue of the volume may accept requests
# larger than tn_nvme_max_io_kb. A queue that cannot be written but already
# reads at or below the cap satisfies that, so it counts as applied. It used
# to be dropped before it was read (`next if !-w`), and with every queue
# dropped activate_volume found "no writable queue" and refused a disk that
# was already safe. Only a queue above the cap that cannot be brought down is
# a failure, and then activate_volume still fails closed.
#
# Runs the REAL helper against a scratch sysfs tree ($_NVME_SYSFS). Writability
# is decided through _nvme_queue_writable, overridden here: the suite runs as
# root, for whom -w is true on any file.
#
# Run with:  prove -v t/nvme/43-cap-unwritable-queue.t
use strict;
use warnings;
use Test::More;
use FindBin;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

my $PLUGIN = "$FindBin::Bin/../../TrueNASPlugin.pm";
unless (eval { require $PLUGIN; 1 }) {
    plan skip_all => "cannot load TrueNASPlugin.pm (needs PVE perl modules): $@";
}
my $PKG  = 'PVE::Storage::Custom::TrueNASPlugin';
my $UUID = '11111111-2222-3333-4444-555555555555';
my $VOL  = "vol-vm-101-disk-0-ns$UUID";
my $CAP  = 1024;

my $root = tempdir(CLEANUP => 1);
my %unwritable;
{
    no strict 'refs'; no warnings 'redefine', 'once';
    ${"${PKG}::_NVME_SYSFS"} = $root;
    *{"${PKG}::_log"} = sub { 1 };
    *{"${PKG}::abs_path"} = sub { $_[0] };
    *{"${PKG}::_nvme_queue_writable"} = sub { !$unwritable{$_[0]} };
    # activate_volume around the real cap helper
    *{"${PKG}::_nvme_connect"} = sub { 1 };
    *{"${PKG}::_api_call"} = sub { [] };
    *{"${PKG}::_nvme_resync_configfs"} = sub { 1 };
    *{"${PKG}::_nvme_device_for_uuid"} = sub { '/dev/nvme0n1' };
    *{"${PKG}::_nvme_wait_for_uuid_link"} = sub { '/dev/nvme0n1' };
    *{"${PKG}::_nvme_warn_target_no_mdts"} = sub { 1 };
}

sub q_path { "$root/block/$_[0]/queue/max_sectors_kb" }

# %$queues: device name => value, or [value, 'ro'] for a queue not writable.
sub tree {
    my (%queues) = @_;
    %unwritable = ();
    system('rm', '-rf', "$root/block");
    for my $dev (sort keys %queues) {
        my ($val, $ro) = ref $queues{$dev} ? @{ $queues{$dev} } : ($queues{$dev});
        make_path("$root/block/$dev/queue");
        open(my $fh, '>', q_path($dev)) or die "$!";
        print $fh "$val\n";
        close $fh;
        $unwritable{ q_path($dev) } = 1 if $ro;
    }
}

sub cap { [ $PKG->can('_nvme_cap_max_io')->({}, 'activate', '/dev/nvme0n1') ] }

sub value {
    open(my $fh, '<', q_path($_[0])) or return undef;
    my $v = <$fh>;
    chomp $v;
    return $v;
}

sub activate {
    my $ok = eval { $PKG->activate_volume('store', { tn_dataset => 'tank/pve',
        tn_api_host => '198.51.100.7', tn_transport_mode => 'nvme-tcp',
        tn_subsystem_nqn => 'nqn.x:y' }, $VOL, undef, {}); 1 };
    return ($ok, $@);
}

# Already capped, not writable: applied, nothing failed.
tree(nvme0n1 => 1280, nvme0c0n1 => [ $CAP, 'ro' ]);
is_deeply(cap(), [1, 0, 2], 'path queue not writable but already at the cap -> counted, not failed');
is(value('nvme0n1'), $CAP, '  ...the writable head was capped');

tree(nvme0n1 => 1280, nvme0c0n1 => [ 512, 'ro' ]);
is_deeply(cap(), [1, 0, 2], 'path queue not writable, below the cap -> counted, not failed');

tree(nvme0n1 => [ $CAP, 'ro' ], nvme0c0n1 => [ $CAP, 'ro' ]);
is_deeply(cap(), [0, 0, 2], 'no queue writable, all already capped -> (0,0,2), not (0,0,0)');
{
    my ($ok, $err) = activate();
    ok($ok, '  ...and activate_volume exposes the disk (it is safe)') or diag($err);
}

# Above the cap and not writable: that one is a failure.
tree(nvme0n1 => 1280, nvme0c0n1 => [ 1280, 'ro' ]);
is_deeply(cap(), [1, 1, 2], 'path queue not writable and ABOVE the cap -> failed');
is(value('nvme0c0n1'), 1280, '  ...and it was not written');
{
    my ($ok, $err) = activate();
    ok(!$ok, '  ...and activate_volume fails closed');
    like($err // '', qr/#96/, '  ...citing #96');
}

tree(nvme0n1 => 1280, nvme0c0n1 => [ 'garbage', 'ro' ]);
is_deeply(cap(), [1, 1, 2], 'path queue not writable and unreadable -> failed');

# Writable queues keep working as before.
tree(nvme0n1 => 1280, nvme0c0n1 => 1280);
is_deeply(cap(), [2, 0, 2], 'both writable, above the cap -> both capped');
is(value('nvme0c0n1'), $CAP, '  ...to the cap');

tree(nvme0n1 => 1280, nvme0c0n1 => 512);
is_deeply(cap(), [1, 0, 2], 'writable queue already below the cap -> left as is, counted');
is(value('nvme0c0n1'), 512, '  ...not raised to the cap');

done_testing;
