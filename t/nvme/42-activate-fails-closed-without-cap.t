#!/usr/bin/perl
# activate_volume must not hand out a disk whose request-size cap (#96) could
# not be applied.
#
# The target declares no MDTS, so the initiator merges requests up to 32 MiB
# and the target fails them silently: a copy through the page cache lost ~98 GiB
# of a 2 TiB disk with exit 0. The cap (tn_nvme_max_io_kb, max_sectors_kb on
# the head and every path device) is the only thing standing in for the missing
# limit. _nvme_cap_max_io reports ($changed, $failed, $total) and logs a
# warning, but activate_volume threw the result away and returned the disk
# anyway. A failed cap now stops the activation with a message that says why;
# without a configured cap nothing changes.
#
# Run with:  prove -v t/nvme/42-activate-fails-closed-without-cap.t
use strict;
use warnings;
use Test::More;
use FindBin;

my $PLUGIN = "$FindBin::Bin/../../TrueNASPlugin.pm";
unless (eval { require $PLUGIN; 1 }) {
    plan skip_all => "cannot load TrueNASPlugin.pm (needs PVE perl modules): $@";
}
my $PKG  = 'PVE::Storage::Custom::TrueNASPlugin';
my $UUID = '11111111-2222-3333-4444-555555555555';
my $VOL  = "vol-vm-101-disk-0-ns$UUID";

my (@cap_calls, @cap_answer, $cap_dies, $use_real);
my $REAL_CAP = $PKG->can('_nvme_cap_max_io') or BAIL_OUT('missing _nvme_cap_max_io');
{
    no strict 'refs'; no warnings 'redefine';
    *{"${PKG}::_log"} = sub { 1 };
    *{"${PKG}::_nvme_connect"} = sub { 1 };
    *{"${PKG}::_api_call"} = sub { [] };
    *{"${PKG}::_nvme_resync_configfs"} = sub { 1 };
    *{"${PKG}::_nvme_device_for_uuid"} = sub { '/dev/nvme0n1' };
    *{"${PKG}::_nvme_wait_for_uuid_link"} = sub { '/dev/disk/by-id/nvme-uuid.x' };
    *{"${PKG}::_nvme_cap_max_io"} = sub {
        goto &$REAL_CAP if $use_real;
        push @cap_calls, [ @_[1, 2] ];
        die "sysfs exploded\n" if $cap_dies;
        return @cap_answer;
    };
}

sub activate {
    my ($scfg, @answer) = @_;
    (@cap_calls, @cap_answer) = ();
    @cap_answer = @answer;
    my $ok = eval { $PKG->activate_volume('store', $scfg, $VOL, undef, {}); 1 };
    return ($ok, $@);
}
my $base = { tn_dataset => 'tank/pve', tn_api_host => '198.51.100.7', tn_transport_mode => 'nvme-tcp',
             tn_subsystem_nqn => 'nqn.x:y' };

{
    my ($ok, $err) = activate({ %$base }, 0, 2, 2);
    ok(!$ok, 'default cap configured, 2 of 2 queues could not be capped -> activate_volume dies');
    like($err, qr/#96/, '  ...citing #96');
    like($err, qr/MDTS/, '  ...explaining the target MDTS problem');
    like($err, qr/not (been )?(exposed|activated)|refus/i, '  ...saying the disk is not exposed');
    like($err, qr/2 of 2/, '  ...with how many queues failed');
    is_deeply(\@cap_calls, [ [ 'activate', '/dev/nvme0n1' ] ], '  ...after asking for the cap once on the device');
}
{
    my ($ok, $err) = activate({ %$base }, 1, 1, 3);
    ok(!$ok, 'one queue failed, two capped -> still dies (any failure leaves an uncapped path)');
}
{
    my ($ok, $err) = activate({ %$base }, 2, 0, 2);
    ok($ok, 'cap applied everywhere -> activate_volume succeeds') or diag($err);
    ($ok, $err) = activate({ %$base }, 0, 0, 2);
    ok($ok, 'cap already in place (nothing changed, nothing failed) -> succeeds') or diag($err);
}
{
    my ($ok, $err) = activate({ %$base, tn_nvme_max_io_kb => 512 }, 0, 1, 1);
    ok(!$ok, 'explicit cap value, failed -> dies');
}
{
    # Cap set but no writable max_sectors_kb found at all: nothing was capped,
    # so the cap is unreadable/unwritable, not satisfied.
    my ($ok, $err) = activate({ %$base }, 0, 0, 0);
    ok(!$ok, 'cap configured but no queue found (0,0,0) -> dies');
    like($err, qr{no queue/max_sectors_kb was found}, '  ...saying no queue was found');
    ($ok, $err) = activate({ %$base, tn_nvme_max_io_kb => 0 }, 0, 0, 0);
    ok($ok, 'same (0,0,0) with the cap disabled -> succeeds') or diag($err);
}
{
    # No cap configured: the REAL _nvme_cap_max_io answers (0,0,0) and touches
    # nothing, so the activation is exactly what it was.
    $use_real = 1;
    my ($ok, $err) = activate({ %$base, tn_nvme_max_io_kb => 0 });
    $use_real = 0;
    ok($ok, 'cap disabled (tn_nvme_max_io_kb 0) -> real helper answers (0,0,0), activation unchanged') or diag($err);
    is_deeply([ $REAL_CAP->({ tn_nvme_max_io_kb => 0 }, 'activate', '/dev/nvme0n1') ], [ 0, 0, 0 ],
        '  ...(0,0,0) is what the real helper returns with no cap');
}
{
    $cap_dies = 1;
    my ($ok, $err) = activate({ %$base });
    $cap_dies = 0;
    ok(!$ok, 'the cap call itself dying -> also fails closed');
    like($err, qr/sysfs exploded/, '  ...keeping the cause');
}

done_testing;
