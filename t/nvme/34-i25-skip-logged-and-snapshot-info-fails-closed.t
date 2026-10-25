#!/usr/bin/perl
# (1) i==25 of _nvme_device_for_uuid: the target UUID is not visible but ANOTHER
#     namespace of the subsystem is in use. It must not disconnect (GitHub #134)
#     and must say so in the log, with the iteration label, so a field report
#     pins the branch that acted.
# (2) volume_snapshot_info must fail on an unusable pool.snapshot.query answer
#     instead of reading it as "this volume has no snapshots" (a rollback guard
#     would then be decided on an empty list).
#
# Run with:  prove -v t/nvme/34-i25-skip-logged-and-snapshot-info-fails-closed.t
use strict;
use warnings;
use Test::More;
use FindBin;

my $PLUGIN = "$FindBin::Bin/../../TrueNASPlugin.pm";
unless (eval { require $PLUGIN; 1 }) {
    plan skip_all => "cannot load TrueNASPlugin.pm (needs PVE perl modules): $@";
}
my $PKG = 'PVE::Storage::Custom::TrueNASPlugin';
my $f = $PKG->can('_nvme_device_for_uuid') or BAIL_OUT('missing _nvme_device_for_uuid');

my (@logs, $disconnects, $api_answer);
{
    no strict 'refs'; no warnings 'redefine';
    *{"${PKG}::_log"} = sub { push @logs, $_[3] // ''; 1 };
    *{"${PKG}::usleep"} = sub { 1 };
    *{"${PKG}::run_command"} = sub { 1 };
    # Target UUID never seen: linux_device_count 0, so $ever_saw_devices stays false.
    *{"${PKG}::_nvme_find_device_by_subsystem"} = sub { return { linux_device_count => 0, selector_outcome => 'no_match' } };
    *{"${PKG}::_nvme_is_connected"} = sub { 1 };
    *{"${PKG}::_nvme_rescan_subsystem_controllers"} = sub { 1 };
    *{"${PKG}::_nvme_get_subsystem_device_paths"} = sub { ('/dev/nvme0n1', '/dev/nvme0n2') };
    *{"${PKG}::_nvme_check_devices_in_use"} = sub { 1 };      # a running VM holds another namespace
    *{"${PKG}::_nvme_reap_orphan_namespaces"} = sub { 0 };
    *{"${PKG}::_nvme_disconnect"} = sub { $disconnects++ };
    *{"${PKG}::_nvme_connect"} = sub { 1 };
    *{"${PKG}::_api_call"} = sub { $api_answer };
}
my $scfg = { tn_subsystem_nqn => 'nqn.x:y', tn_dataset => 'tank/pve' };

# --- (1) i==25 skip is logged, and never disconnects
$api_answer = [];                        # TN does not publish it either: i==75/125 branches stay out
$disconnects = 0;
eval { $f->($scfg, 'uuid-1', allow_reconnect => 1) };
is($disconnects, 0, 'i==25 with a namespace in use: no disconnect');
my @skip = grep { /i==25 reconnect SKIPPED/ } @logs;
is(scalar(@skip), 1, 'i==25 skip is logged exactly once');
like($skip[0] // '', qr/dev_paths=2.*in_use=1/s, '  ...with dev_paths and in_use');

# --- (2) snapshot info fails closed
my $info = $PKG->can('volume_snapshot_info') or BAIL_OUT('missing volume_snapshot_info');
{
    no strict 'refs'; no warnings 'redefine';
    local *{"${PKG}::parse_volname"} = sub { (undef, 'vm-100-disk-0') };
    for my $bad (undef, 'not-a-list', { error => 1 }) {
        $api_answer = $bad;
        my $r = eval { $info->($PKG, $scfg, 'tn', 'vm-100-disk-0'); 1 };
        ok(!$r, 'snapshot info: unusable answer (' . (defined $bad ? ref($bad) || 'scalar' : 'undef') . ') dies');
        like($@, qr/refusing to treat that as 'no snapshots'/, '  ...with the readable error');
    }
    $api_answer = [];
    my $ok = eval { $info->($PKG, $scfg, 'tn', 'vm-100-disk-0') };
    is_deeply($ok, {}, 'snapshot info: a genuinely empty list is still "no snapshots"');
}
done_testing;
