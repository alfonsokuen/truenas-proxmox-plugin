package PVE::Tools;

# Minimal stand-in for the real PVE::Tools module, which ships only as part
# of a Proxmox VE host install (libpve-storage-perl) and is not available on
# a plain Perl toolchain. TrueNASPlugin.pm only needs these two symbols to
# resolve at compile time (`use PVE::Tools qw(run_command trim)`); nothing in
# t/nvme exercises run_command, since every test replaces the plugin's own
# API/CLI call points with mocks before it runs.

use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(run_command trim file_set_contents file_get_contents file_read_firstline);

sub run_command {
    die "PVE::Tools::run_command is a compile-time stub; no test should call it\n";
}

# Real behaviour, on purpose: the plugin writes its sensitive-property files
# through this and t/nvme/24 asserts the mode and the replace-by-rename, so a
# no-op stand-in would make that test pass or fail for the wrong reason.
sub file_set_contents {
    my ($filename, $data, $perm, $force) = @_;
    $perm = 0644 if !defined $perm;
    my $tmp = "$filename.tmp.$$";
    open(my $fh, '>', $tmp) or die "unable to open file '$tmp' - $!\n";
    chmod($perm, $fh);
    print {$fh} $data or die "unable to write '$tmp' - $!\n";
    close($fh) or die "unable to close '$tmp' - $!\n";
    rename($tmp, $filename) or die "unable to rename '$tmp' to '$filename' - $!\n";
    return;
}

sub file_read_firstline {
    my ($filename) = @_;
    open(my $fh, '<', $filename) or return undef;
    my $line = <$fh>;
    close($fh);
    chomp($line) if defined $line;
    return $line;
}

sub file_get_contents {
    my ($filename, $max) = @_;
    open(my $fh, '<', $filename) or die "unable to open file '$filename' - $!\n";
    local $/;
    my $data = <$fh>;
    close($fh);
    $data = substr($data, 0, $max) if defined $max && length($data) > $max;
    return $data;
}

sub trim {
    my ($s) = @_;
    return undef if !defined $s;
    $s =~ s/^\s+|\s+$//g;
    return $s;
}

1;
