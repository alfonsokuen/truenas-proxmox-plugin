#!/usr/bin/perl
# volume_import's stream copy: a stream shorter than its header announced must
# fail (dd reported success), zero runs are skipped, and the device path is
# untainted under perl -T.
#
# Run with:  prove -v t/nvme/27-volume-stream.t
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
my $copy = $PKG->can('_stream_to_device') or BAIL_OUT('no _stream_to_device');
my $dir = tempdir(CLEANUP => 1);

sub run_copy {
    my ($data, $bytes, $preload) = @_;
    my $dev = "$dir/dev.img";
    open(my $d, '>:raw', $dev) or die; print $d ($preload // ("\xAA" x $bytes)); close $d;
    my $src = "$dir/stream.bin";
    open(my $w, '>:raw', $src) or die; print $w $data; close $w;
    open(my $in, '<:raw', $src) or die;
    my $ok = eval { $copy->($in, $dev, $bytes); 1 };
    my $err = $@;
    open(my $r, '<:raw', $dev) or die; local $/; my $got = <$r>; close $r;
    return ($ok, $err, $got);
}

{
    my $data = join '', map { chr(65 + $_ % 26) } 0 .. 9999;
    my ($ok, $err, $got) = run_copy($data, 10000);
    ok($ok, 'a complete stream copies') or diag($err);
    ok($got eq $data, '  ...byte for byte');
}
{
    my ($ok, $err, $got) = run_copy('x' x 5000, 10000);
    ok(!$ok, 'a truncated stream FAILS (the old dd path reported success)');
    like($err, qr/ended after 5000 of 10000 bytes/, '  ...saying how much arrived');
}
{
    my $zeros = "\0" x (5 * 1024 * 1024);
    my ($ok, undef, $got) = run_copy($zeros, length $zeros, "\xAA" x length $zeros);
    ok($ok, 'zero stream copies');
    is($got, "\xAA" x length($zeros), '  ...zero runs are skipped by seeking, like conv=sparse');
}
{
    my $data = ('a' x 4194304) . ('b' x 100);
    my ($ok, undef, $got) = run_copy($data . 'TRAILING', length $data);
    ok($got eq $data, 'bytes beyond the announced size are not written');
}

# taint: run under -T with the device path coming from the environment
{
    my $script = q{use strict; use Scalar::Util qw(tainted);
        require 'TrueNASPlugin.pm';
        my $f = PVE::Storage::Custom::TrueNASPlugin->can('_real_dev_path');
        my $in = $ENV{DEVPATH};
        my $out = $f->($in);
        print((tainted($in) ? 'in-tainted ' : 'in-clean '), (tainted($out) ? 'out-tainted' : 'out-clean'), "\n");};
    local $ENV{PLUGIN} = $PLUGIN; local $ENV{DEVPATH} = '/dev/null';
    my $sf = "$dir/taint.pl";
    open(my $o, '>', $sf) or die; print $o $script; close $o;
    my $res = `$^X -T -I$FindBin::Bin/../.. $sf 2>&1`;
    like($res, qr/in-tainted out-clean/, '_real_dev_path returns an untainted path under perl -T');
}

done_testing;
