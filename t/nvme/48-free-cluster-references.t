#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use FindBin;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use JSON::PP qw(encode_json);

require "$FindBin::Bin/../../TrueNASPlugin.pm";
my $pkg = 'PVE::Storage::Custom::TrueNASPlugin';
my $uuid = '11111111-2222-3333-4444-555555555555';
my $vol = "vol-vm-101-disk-0-ns$uuid";
my $scfg = { tn_dataset => 'tank/pve', tn_transport_mode => 'nvme-tcp' };
my $root = tempdir(CLEANUP => 1);
make_path("$root/nodes/remote/qemu-server", "$root/nodes/remote/lxc");
my $quorate = 1;
my @mutations;
{
    no strict 'refs'; no warnings 'redefine', 'once';
    ${"${pkg}::_PRUNE_PVE_ROOT"} = $root;
    $INC{'PVE/Cluster.pm'} = __FILE__;
    *PVE::Cluster::check_cfs_quorum = sub { return $quorate };
    *{"${pkg}::_log"} = sub {};
    *{"${pkg}::_defer_after_lock"} = sub {};
    *{"${pkg}::_assert_no_child_datasets"} = sub { 1 };
    *{"${pkg}::_nvme_pending_free_mark"} = sub { push @mutations, 'mark' };
    *{"${pkg}::_nvme_find_device_by_subsystem"} = sub {
        return { selector_outcome => 'publication_mismatch', enumeration_complete => 1 };
    };
    *{"${pkg}::_nvme_delete_namespace"} = sub { push @mutations, 'namespace' };
    *{"${pkg}::_delete_dataset_with_retry"} = sub { push @mutations, 'dataset' };
    *{"${pkg}::_api_call"} = sub { die "unexpected RPC $_[1]" };
}

sub put {
    my ($path, $text) = @_;
    open(my $fh, '>', "$root/$path") or die $!;
    print {$fh} $text;
    close($fh) or die $!;
}
sub guest_index {
    my (%ids) = @_;
    put('.vmlist', encode_json({ version => 1, ids => \%ids }));
}
sub free_volume {
    @mutations = ();
    return $pkg->free_image('store', $scfg, $vol, 0, 'raw');
}

guest_index(900 => { node => 'remote', type => 'qemu' });
put('nodes/remote/qemu-server/900.conf', "name: vm\n[after-backup]\nscsi0: store:$vol,discard=on\n");
ok(!eval { free_volume(); 1 }, '#1 refuses a volume referenced in a remote VM snapshot');
like($@, qr/store:\Q$vol\E.*900.*remote/s, '#1 names the volume, guest and node');
is_deeply(\@mutations, [], '#1 leaves namespace and dataset untouched');

guest_index(901 => { node => 'remote', type => 'lxc' });
put('nodes/remote/lxc/901.conf', "[PENDING]\nmp0: store:vm-101-disk-0,mp=/data\n");
ok(!eval { free_volume(); 1 }, '#1 detects a plain alias in a remote CT pending section');
is_deeply(\@mutations, [], '#1 alias also blocks every mutation');

guest_index(902 => { node => 'remote', type => 'lxc' });
ok(!eval { free_volume(); 1 }, '#1 refuses when a remote config cannot be read');
like($@, qr/could not verify.*902/is, '#1 describes the missing config');
is_deeply(\@mutations, [], '#1 uncertainty blocks every mutation');

guest_index();
$quorate = 0;
ok(!eval { free_volume(); 1 }, '#1 refuses an unquorate cluster view');
is_deeply(\@mutations, [], '#1 lack of quorum blocks every mutation');
$quorate = 1;

my $worker = free_volume();
is(ref($worker), 'CODE', '#1 permits free with a verified empty guest list');
guest_index(900 => { node => 'remote', type => 'qemu' });
ok(!eval { $worker->('UPID:test'); 1 }, '#1 deferred force-delete refuses a reference added after namespace removal');
ok(!grep({ $_ eq 'dataset' } @mutations), '#1 worker leaves the referenced dataset intact');

done_testing;
