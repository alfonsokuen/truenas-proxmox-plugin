#!/usr/bin/perl
# volume_import's allocation lifecycle.
#  - a stream that dies must delete the zvol: free_image returns the cleanup
#    worker that holds the dataset delete, and the rollback used to drop it;
#  - alloc (and the rollback free) run inside cluster_lock_storage, the way
#    PVE's vdisk_alloc/vdisk_free call them;
#  - an imported disk is not given the 4096-byte iSCSI extent (it carries data
#    laid out for the source's sector size).
#
# Run with:  prove -v t/nvme/30-volume-import-lifecycle.t
use strict;
use warnings;
use Test::More;
use FindBin;
use File::Temp qw(tempdir);

my $PLUGIN = "$FindBin::Bin/../../TrueNASPlugin.pm";
unless (eval { require $PLUGIN; 1 }) {
    plan skip_all => "cannot load TrueNASPlugin.pm (needs PVE perl modules): $@";
}
my $PKG = 'PVE::Storage::Custom::TrueNASPlugin';
my $scfg = { tn_dataset => 'tank/pve', tn_api_host => '198.51.100.7', tn_transport_mode => 'iscsi' };
my $dir = tempdir(CLEANUP => 1);

my (@events, $in_lock, $worker_ran, $import_flag_seen);
{
    no strict 'refs'; no warnings 'redefine';
    *{"${PKG}::_log"} = sub { 1 };
    *{"${PKG}::cluster_lock_storage"} = sub {
        my ($class, $storeid, $shared, $timeout, $func, @p) = @_;
        push @events, 'lock-enter'; $in_lock = 1;
        my $r = eval { $func->(@p) }; my $e = $@; $in_lock = 0; push @events, 'lock-exit';
        die $e if $e; return $r;
    };
    *{"${PKG}::alloc_image"} = sub {
        push @events, $in_lock ? 'alloc-in-lock' : 'alloc-OUTSIDE-lock';
        $import_flag_seen = $PKG->can('_import_alloc_active') ? $PKG->_import_alloc_active : ${"${PKG}::_import_alloc"};
        return 'vol-vm-9-disk-0-lun1';
    };
    *{"${PKG}::activate_volume"} = sub { 1 };
    *{"${PKG}::path"} = sub { ('/dev/null', 9, 'images') };
    *{"${PKG}::free_image"} = sub {
        push @events, $in_lock ? 'free-in-lock' : 'free-OUTSIDE-lock';
        return sub { $worker_ran++ };
    };
    *PVE::Storage::Plugin::read_common_header = sub { 10000 };
}

sub import_with {
    my ($data) = @_;
    @events = (); $worker_ran = 0; $import_flag_seen = 0;
    my $src = "$dir/s.bin"; open(my $w, '>:raw', $src) or die; print $w $data; close $w;
    open(my $in, '<:raw', $src) or die;
    my $ok = eval { $PKG->volume_import($scfg, 's', $in, 'vm-9-disk-0', 'raw+size', undef, undef, 0, 0); 1 };
    return ($ok, $@);
}

# Whatever makes the streaming step fail (a short stream, or this host having
# no block device to write to) must roll the allocation back completely.
{
    no strict 'refs'; no warnings 'redefine';
    *{"${PKG}::_real_dev_path"} = sub { '/dev/null' };
}
{
    my ($ok, $err) = import_with('x' x 100);
    ok(!$ok, 'a failing import dies');
    ok($worker_ran, '  ...and the cleanup worker returned by free_image was INVOKED (the zvol is deleted)');
    ok(length($err // ''), '  ...and the original error is not lost');
    my %seen = map { $_ => 1 } @events;
    ok($seen{'alloc-in-lock'} && !$seen{'alloc-OUTSIDE-lock'}, 'alloc_image ran inside cluster_lock_storage');
    ok($seen{'free-in-lock'} && !$seen{'free-OUTSIDE-lock'}, 'the rollback free_image ran inside cluster_lock_storage');
    ok($import_flag_seen, 'the import flag was set while allocating');
}

# --- extent payload: no 4096 for an import ---------------------------------
{
    no strict 'refs'; no warnings 'redefine';
    my @payloads;
    local *{"${PKG}::_tn_extent_query_by_disk"} = sub { [] };
    local *{"${PKG}::_generate_extent_name"} = sub { 'ext' };
    local *{"${PKG}::_api_call_mutate"} = sub { push @payloads, $_[2][0]; die "stop here\n" };
    local *{"${PKG}::_api_call"} = sub { [] };
    eval { PVE::Storage::Custom::TrueNASPlugin::_alloc_image_iscsi($PKG, $scfg, 'vm-9-disk-0', 'tank/pve/vm-9-disk-0', 'zvol/tank/pve/vm-9-disk-0') };
    ok($payloads[0] && $payloads[0]{blocksize} == 4096, 'a fresh disk still gets blocksize 4096');
    @payloads = ();
    { local ${"${PKG}::_import_alloc"} = 1;
      eval { PVE::Storage::Custom::TrueNASPlugin::_alloc_image_iscsi($PKG, $scfg, 'vm-9-disk-0', 'tank/pve/vm-9-disk-0', 'zvol/tank/pve/vm-9-disk-0') }; }
    ok($payloads[0] && !exists $payloads[0]{blocksize} && !exists $payloads[0]{pblocksize}, 'an imported disk gets NO blocksize/pblocksize');
}
done_testing;
