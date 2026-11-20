package IDK::TestNVMeSysfs;

use strict;
use warnings;
use Exporter qw(import);
use File::Path qw(make_path);

our @EXPORT_OK = qw(write_attr nvme_fixture);

sub write_attr {
    my ($path, $value) = @_;
    (my $dir = $path) =~ s{/[^/]+$}{};
    make_path($dir);
    open(my $fh, '>', $path) or die "$path: $!";
    print {$fh} "$value\n";
    close($fh) or die "$path: $!";
}

sub nvme_fixture {
    my ($root, $name, $nqn, %attrs) = @_;
    my ($subsys, $ctrl) = $name =~ /^nvme(\d+)(?:c(\d+))?n\d+$/ or die $name;
    my $block = "$root/block/$name";
    my $subsystem = "$root/class/nvme-subsystem/nvme-subsys$subsys";
    write_attr("$subsystem/subsysnqn", $nqn);
    my $target = $subsystem;
    if (defined $ctrl) {
        $target = "$root/devices/virtual/nvme-fabrics/ctl/nvme$ctrl";
        make_path("$target/$name");
        write_attr("$target/$_->[0]", $_->[1]) for (
            ['subsysnqn', $nqn], ['cntlid', $ctrl + 1], ['hostnqn', 'nqn.test:host'],
            ['address', 'traddr=192.0.2.1,trsvcid=4420'], ['transport', 'tcp'], ['state', 'live'],
        );
        $attrs{hidden} //= 1;
    }
    make_path("$block/holders");
    # Git for Windows emulates symlinks by copying their target. Either form
    # has subsysnqn below device/ and has no subsysnqn in its parent.
    symlink($target, "$block/device") or die "link $block/device to $target: $!";
    write_attr("$block/$_", $attrs{$_}) for keys %attrs;
}

1;
