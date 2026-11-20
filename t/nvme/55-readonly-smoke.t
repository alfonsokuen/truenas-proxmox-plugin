#!/usr/bin/perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../../lib";
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use IDK::TestNVMeSysfs qw(write_attr nvme_fixture);

my $pkg = 'PVE::Storage::Custom::TrueNASPlugin';
my $nqn = 'nqn.2011-06.com.truenas:uuid:test:pve';
my $vm_uuid = '11111111-2222-3333-4444-555555555555';
my $ct_uuid = 'aaaaaaaa-2222-3333-4444-555555555555';
my $smoke = "$FindBin::Bin/../../tools/idk-readonly-smoke.pl";

sub run_fixture {
    my ($mode) = @_;
    require "$FindBin::Bin/../../TrueNASPlugin.pm";
    my $root = tempdir(CLEANUP => 1);
    nvme_fixture($root, 'nvme0n1', $nqn, nsid => 1, uuid => $vm_uuid, dev => '259:1');
    nvme_fixture($root, 'nvme0c0n1', $nqn, uuid => $vm_uuid, $mode eq 'incomplete' ? () : (nsid => 1));
    nvme_fixture($root, 'nvme0n2', $nqn, nsid => 2, uuid => $ct_uuid, dev => '259:2');
    write_attr("$root/dev/nvme0n1", 'fake block node') if $mode ne 'head-missing';
    write_attr("$root/dev/nvme0n2", 'fake block node');
    write_attr("$root/mountinfo", '40 26 259:2 / /var/lib/lxc/102/rootfs rw - ext4 /dev/nvme0n2 rw');
    make_path("$root/proc");

    no strict 'refs';
    no warnings 'redefine', 'once';
    $INC{$_} = __FILE__ for qw(PVE/Storage.pm PVE/Storage/Custom/TrueNASPlugin.pm
        PVE/Cluster.pm PVE/INotify.pm PVE/QemuConfig.pm PVE/LXC/Config.pm);
    local *PVE::Storage::config = sub { { ids => {
        tn => { type => 'truenasplugin', tn_transport_mode => 'nvme-tcp', tn_subsystem_nqn => $nqn },
        iscsi => { type => 'truenasplugin', tn_transport_mode => 'iscsi' },
    } } };
    local *PVE::Cluster::cfs_update = sub {};
    local *PVE::Cluster::get_vmlist = sub { { ids => {
        101 => { type => 'qemu', node => 'lab' }, 102 => { type => 'lxc', node => 'lab' },
        103 => { type => 'qemu', node => 'lab' }, 104 => { type => 'qemu', node => 'remote' },
    } } };
    local *PVE::INotify::nodename = sub { 'lab' };
    local *PVE::QemuConfig::load_config = sub {
        die 'unexpected config read' unless $_[1] == 101;
        return { scsi0 => "file=tn:vol-vm-101-disk-0-ns$vm_uuid,size=8G",
            description => 'tn:vm-101-disk-42', unused0 => 'tn:vm-101-disk-99' };
    };
    local *PVE::LXC::Config::load_config = sub {
        die 'unexpected config read' unless $_[1] == 102;
        return { rootfs => "tn:vol-vm-102-disk-0-ns$ct_uuid,size=8G" };
    };
    local *PVE::Tools::run_command = sub {
        my ($argv, %opts) = @_;
        die "unexpected command: @$argv" unless @$argv == 3 && $argv->[1] eq 'status'
            && ($argv->[0] eq '/usr/sbin/qm' && $argv->[2] =~ /\A10[13]\z/
                || $argv->[0] eq '/usr/sbin/pct' && $argv->[2] eq '102');
        $opts{outfunc}->($argv->[2] eq '103' ? 'status: stopped' : 'status: running');
        return 0;
    };
    local *{"${pkg}::_api_call"} = sub {
        my (undef, $method) = @_;
        return [{ id => 7 }] if $method eq 'nvmet.subsys.query';
        return [{ subsys => 7, device_uuid => $vm_uuid, nsid => 1 },
            { subsys => 7, device_uuid => $ct_uuid, nsid => 2 }] if $method eq 'nvmet.namespace.query';
        die "unexpected API call: $method";
    };
    local *{"${pkg}::_log"} = sub {};
    local ${"${pkg}::_NVME_SYSFS"} = $root;
    local ${"${pkg}::_NVME_MOUNTINFO"} = "$root/mountinfo";
    local ${"${pkg}::_NVME_PROC_ROOT"} = "$root/proc";
    local ${"${pkg}::_NVME_FUSER_RC"} = sub { $mode eq 'free' ? 1 : 0 };

    do $smoke or BAIL_OUT("cannot load smoke: " . ($@ || $!));
    IDK::ReadOnlySmoke::run(sub { -f "$root$_[0]" });
}

if (@ARGV) {
    Test::More->builder->failure_output(\*STDOUT);
    run_fixture($ARGV[0]);
    exit 0;
}

sub smoke_output {
    my ($mode) = @_;
    open(my $fh, '-|', $^X, $0, $mode) or die "cannot run smoke fixture: $!";
    my $output = do { local $/; <$fh> } // '';
    close($fh);
    return ($? >> 8, $output);
}

my ($exit, $output) = smoke_output('busy');
is($exit, 0, 'read-only smoke passes against two fake namespaces') or diag $output;
like($output, qr/^ok.*tn.*\Q$vm_uuid\E.*\/dev\/nvme0n1/m, 'checks the existing head for the VM namespace');
like($output, qr/^ok.*tn.*\Q$ct_uuid\E.*\/dev\/nvme0n2/m, 'checks the existing head for the CT namespace');
like($output, qr/^ok.*guest 101.*scsi0.*in use/m, 'probes the running VM disk');
like($output, qr/^ok.*guest 102.*rootfs.*in use/m, 'probes the running CT disk');
unlike($output, qr/guest 103|guest 104|unused0|enumeration_failed/, 'ignores nonactive references and sees complete enumeration');

($exit, $output) = smoke_output('free');
isnt($exit, 0, 'a running guest disk reported free fails the smoke');
like($output, qr/^not ok.*guest 101.*scsi0.*in use/m, 'names the guest and disk that appear free');

($exit, $output) = smoke_output('incomplete');
isnt($exit, 0, 'incomplete sysfs fails the smoke');
like($output, qr/^not ok.*enumeration_failed/m, 'reports enumeration_failed in TAP');

($exit, $output) = smoke_output('head-missing');
isnt($exit, 0, 'a sysfs head without a block node fails the smoke');
like($output, qr/^not ok.*\Q$vm_uuid\E.*existing NVMe head \/dev\/nvme0n1/m,
    'the smoke names the missing block node');

done_testing;
