#!/usr/bin/perl
# An existing storage has to remain editable.
#
# check_config is called on two very different paths. On create it receives the
# whole configuration and is right to insist that tn_api_host, tn_api_key and
# tn_dataset are there. On update PVE hands it only the options that changed:
#
#   pvesm set tn-pilot --nodes pve3     ->  check_config('tn-pilot', { nodes => 'pve3' }, 0, 1)
#
# The plugin took the second for the first, found no tn_api_host in a config
# that was never supposed to carry one, and died. The effect was that no setting
# on a truenasplugin storage could ever be changed again - not from `pvesm set`,
# not from `pvesh`, not from the web interface. Enabling a disabled storage, or
# restricting it to a node, both failed the same way.
#
# Found on a live node while trying to enable the pilot storage. The error
# reads like a missing parameter, which sends you looking at your own command
# rather than at the plugin.
#
# Run with:  prove -v t/nvme/09-check-config-update.t
#            (needs the PVE perl modules, so it runs on a node, not a laptop)

use strict;
use warnings;
use Test::More;
use FindBin;

my $PLUGIN = "$FindBin::Bin/../../TrueNASPlugin.pm";
unless (eval { require $PLUGIN; 1 }) {
    plan skip_all => "cannot load TrueNASPlugin.pm (needs PVE perl modules): $@";
}

my $PKG = 'PVE::Storage::Custom::TrueNASPlugin';

# Unlike every other test here, this one goes through PVE::SectionConfig - and
# a custom storage plugin is unknown to it until it has been registered. PVE
# does that at runtime for everything under PVE/Storage/Custom/; the plugin file
# does not register itself. A test that just loads the file gets "unknown
# section type 'truenasplugin'" from the SUPER call, before reaching a single
# line of the plugin's own validation, and every assertion below fails for a
# reason that has nothing to do with what it is testing.
unless (eval {
    require PVE::Storage::Plugin;
    $PKG->register();
    PVE::Storage::Plugin->init();
    1;
}) {
    plan skip_all => "cannot register the plugin with PVE::SectionConfig: $@";
}

# A complete, valid nvme-tcp configuration, as it would arrive on create.
my %full = (
    type              => 'truenasplugin',
    tn_api_host       => '198.51.100.7',
    tn_api_key        => '1-notarealkey',
    tn_dataset        => 'tank/pve',
    tn_transport_mode => 'nvme-tcp',
    tn_subsystem_nqn  => 'nqn.2011-06.com.example:uuid:0000:pilot',
    content           => 'images',
);

sub try_check {
    my ($config, $create) = @_;
    my $out = eval { $PKG->check_config('store', $config, $create, 1) };
    return ($out, $@);
}

# ---------------------------------------------------------------------------
# The update path: a delta must be accepted
# ---------------------------------------------------------------------------

# This is the exact shape that `pvesm set tn-pilot --nodes pve3 --disable 0`
# produces, and the exact shape that used to fail.
{
    my ($out, $err) = try_check({ nodes => 'pve3', disable => 0 }, 0);
    ok(!$err, 'changing nodes/disable on an existing storage is accepted')
        or diag("died with: $err");
    unlike($err // '', qr/is required/,
        '...and specifically not for a missing required field');
}

# Every other single-option edit an operator might make.
for my $opt (
    { content => 'images' },
    { tn_debug => 1 },
    { tn_api_retry_max => 5 },
    { tn_sparse => 0 },
    { nodes => 'pve1,pve2' },
) {
    my ($name) = keys %$opt;
    my (undef, $err) = try_check($opt, 0);
    ok(!$err, "editing $name alone is accepted on an existing storage")
        or diag("died with: $err");
}

# ---------------------------------------------------------------------------
# The create path must keep every check it had
# ---------------------------------------------------------------------------

{
    my ($out, $err) = try_check({ %full }, 1);
    ok(!$err, 'a complete configuration is still accepted on create')
        or diag("died with: $err");
    is($out->{shared}, 1, '...and shared is still forced on') if $out;
}

# The three fields whose absence must still be fatal at creation. If the fix
# had simply deleted these checks, this is what would notice.
#
# The message comes from PVE::SectionConfig, not from the plugin: options
# without `optional => 1` are enforced by the SUPER call before the plugin's own
# "is required" lines are ever reached, so those lines are unreachable on the
# create path too. They are left in place as documentation of intent, but this
# asserts on the behaviour - creation is refused and the error names the field -
# rather than on which layer produced the wording.
for my $missing (qw(tn_api_host tn_api_key tn_dataset)) {
    my %cfg = %full;
    delete $cfg{$missing};
    my (undef, $err) = try_check(\%cfg, 1);
    like($err // '', qr/\Q$missing\E/,
        "creating without $missing is refused, and the error names it");
}

# Transport-specific requirements likewise.
{
    my %cfg = %full;
    delete $cfg{tn_subsystem_nqn};
    my (undef, $err) = try_check(\%cfg, 1);
    like($err // '', qr/tn_subsystem_nqn is required/,
        'creating an nvme-tcp storage without a subsystem NQN is still refused');
}
{
    my %cfg = (%full, tn_transport_mode => 'iscsi');
    delete $cfg{tn_subsystem_nqn};
    my (undef, $err) = try_check(\%cfg, 1);
    like($err // '', qr/tn_target_iqn is required/,
        'creating an iSCSI storage without a target IQN is still refused');
}
{
    my %cfg = (%full, tn_transport_mode => 'carrier-pigeon');
    my (undef, $err) = try_check(\%cfg, 1);
    like($err // '', qr/Invalid transport_mode/,
        'an unknown transport mode is still refused');
}

# ---------------------------------------------------------------------------
# What must still be validated on update
# ---------------------------------------------------------------------------

# tn_hostnqn is not fixed, so it can be changed on a live storage - which means
# its format has to be checked on the update path too, not only at creation.
{
    my (undef, $err) = try_check({ tn_hostnqn => 'not-an-nqn' }, 0);
    like($err // '', qr/tn_hostnqn must follow NVMe NQN format/,
        'a malformed hostnqn is refused even on update');
}
{
    my (undef, $err) = try_check({ tn_hostnqn => 'nqn.2014-08.org.nvmexpress:uuid:abc' }, 0);
    ok(!$err, 'a well-formed hostnqn is accepted on update') or diag("died with: $err");
}

# The range checks are written as `if (defined ...)`, so they already apply to
# both paths. Hold that down: they are the other half of "still validated".
{
    my (undef, $err) = try_check({ tn_api_retry_max => 99 }, 0);
    like($err // '', qr/tn_api_retry_max must be between/,
        'an out-of-range retry count is still refused on update');
}

done_testing();
