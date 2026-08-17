#!/usr/bin/perl
# Offline tests for namespace-to-device selection.
#
# This is the code that turns a volume name into the block device Proxmox writes
# to. Getting it wrong does not throw - it hands back another VM's disk. So the
# tests are about which identity wins, and about refusing rather than guessing.
#
# Two facts measured against a live nvmet target, both of which shape the code:
#
#   * The NGUID a target sets does reach the initiator at /sys/block/<dev>/nguid.
#   * When the target's device_nguid is all zeros that file does not exist at
#     all, while /sys/block/<dev>/uuid is always there.
#
# And one from the same target: NSIDs are recycled. Delete a namespace, create
# another, and the new one can take the old NSID pointing at a different zvol.
#
# Run with:  prove -v t/nvme/03-namespace-selector.t

use strict;
use warnings;
use Test::More;
use FindBin;

my $PLUGIN = "$FindBin::Bin/../../TrueNASPlugin.pm";

unless (eval { require $PLUGIN; 1 }) {
    plan skip_all => "cannot load TrueNASPlugin.pm (needs PVE perl modules): $@";
}

my $PKG = 'PVE::Storage::Custom::TrueNASPlugin';
{
    no strict 'refs';
    no warnings 'redefine';
    *{"${PKG}::_log"} = sub { 1 };
}

my $select = $PKG->can('_nvme_select_namespace_device');

my $OUR_UUID  = '11111111-2222-3333-4444-555555555555';
my $OUR_NGUID = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';
my $ZERO      = '00000000-0000-0000-0000-000000000000';

sub dev {
    my (%a) = @_;
    return { path => $a{path}, name => ($a{path} =~ m{([^/]+)$})[0],
             nsid => $a{nsid}, nguid => $a{nguid}, uuid => $a{uuid}, type => 'ns' };
}

sub meta {
    my (%a) = @_;
    # metadata_state matters: without it the selector takes the metadata-failure
    # branch and returns before reaching any matching tier, which would make
    # several of these tests pass while testing nothing at all.
    return { api_namespace_count => $a{count} // 1,
             metadata_state => ($a{state} // 'ok'),
             namespace => { nsid => $a{nsid}, device_nguid => $a{nguid} } };
}

sub pick {
    my ($devices, $m) = @_;
    my $r = $select->({}, $OUR_UUID, $devices, $m);
    return ($r->{selected_device_path}, $r->{match_tier}, $r->{selector_outcome});
}

# ---------------------------------------------------------------------------
# Exact identities win, in order
# ---------------------------------------------------------------------------

{
    my ($p, $t) = pick(
        [ dev(path => '/dev/nvme0n1', nsid => 7, nguid => 'aaaa1111-0000-0000-0000-000000000001', uuid => 'dead0000-0000-0000-0000-000000000001'),
          dev(path => '/dev/nvme0n2', nsid => 9, nguid => $OUR_NGUID, uuid => $OUR_UUID) ],
        meta(nsid => 7, nguid => $OUR_NGUID));
    is($p, '/dev/nvme0n2', 'the NGUID wins over a device that merely has the right NSID');
    is($t, 'nguid', '...and says so');
}

# The NGUID is absent from sysfs whenever the target left it at zero, which is
# the normal state of a namespace created outside this plugin.
{
    my ($p, $t) = pick(
        [ dev(path => '/dev/nvme0n1', nsid => 7, nguid => undef, uuid => 'dead0000-0000-0000-0000-000000000001'),
          dev(path => '/dev/nvme0n2', nsid => 9, nguid => undef, uuid => $OUR_UUID) ],
        meta(nsid => 7, nguid => $ZERO));
    is($p, '/dev/nvme0n2', 'with no NGUID anywhere, the namespace UUID identifies the device');
    is($t, 'uuid', '...as its own tier, not as a lucky NSID hit');
}

# The case this tier exists for: an all-zero NGUID passes the format check - it
# is hex and hyphens in the right shape - so it used to be taken as usable, never
# matched anything, and dropped the selector onto NSID.
{
    my ($p, $t) = pick(
        [ dev(path => '/dev/nvme0n1', nsid => 7, nguid => undef, uuid => 'dead0000-0000-0000-0000-000000000001') ],
        meta(nsid => 7, nguid => $ZERO));
    isnt($p, '/dev/nvme0n1',
        'an all-zero NGUID plus a foreign UUID does not fall through to a bare NSID match');
    isnt($t, 'nsid', '...on any tier');
}

# ---------------------------------------------------------------------------
# A recycled NSID must not be handed out
# ---------------------------------------------------------------------------

# The device carries a real UUID that is not ours. That is the kernel telling us
# its namespace is a different one - the NSID agreeing is exactly the coincidence
# NSID recycling produces.
{
    my ($p, $t, $o) = pick(
        [ dev(path => '/dev/nvme0n1', nsid => 7, nguid => undef, uuid => 'dead0000-0000-0000-0000-000000000009') ],
        meta(nsid => 7, nguid => undef));
    is($p, undef, 'an NSID match is refused when the device UUID says it is someone else');
    is($o, 'publication_mismatch', '...and reported as a publication mismatch');
}

# With no identity on either side there is nothing better than the NSID, and
# refusing outright would break targets that publish neither.
{
    my ($p, $t) = pick(
        [ dev(path => '/dev/nvme0n1', nsid => 7, nguid => undef, uuid => undef) ],
        meta(nsid => 7, nguid => undef));
    is($p, '/dev/nvme0n1', 'with no identity available at all, the NSID is still used');
    is($t, 'nsid', '...and the tier is recorded so the log says how it was matched');
}

# ---------------------------------------------------------------------------
# The legacy single-device fallback stays tightly gated
# ---------------------------------------------------------------------------

{
    my ($p, $t) = pick(
        [ dev(path => '/dev/nvme0n1', nsid => 3, nguid => undef, uuid => undef) ],
        { api_namespace_count => 1, metadata_state => 'ok', namespace => undef });
    is($p, '/dev/nvme0n1', 'one device and one namespace is unambiguous, so the fallback applies');
    is($t, 'single', '...as the legacy tier');
}

{
    my ($p, $t, $o) = pick(
        [ dev(path => '/dev/nvme0n1', nsid => 3, nguid => undef, uuid => undef),
          dev(path => '/dev/nvme0n2', nsid => 4, nguid => undef, uuid => undef) ],
        { api_namespace_count => 2, metadata_state => 'ok', namespace => undef });
    is($p, undef, 'with more than one device the fallback refuses rather than guessing');
}

# An identity that was usable but matched nothing must never reach the fallback:
# something is wrong, and picking the only device present would be a guess.
{
    my ($p, $t, $o) = pick(
        [ dev(path => '/dev/nvme0n1', nsid => 99, nguid => 'bbbb2222-0000-0000-0000-000000000002', uuid => undef) ],
        meta(nsid => 7, nguid => $OUR_NGUID, count => 1));
    is($p, undef, 'a usable NGUID that matched nothing blocks the single-device fallback');
    is($o, 'publication_mismatch', '...and is reported as a mismatch');
}

done_testing();
