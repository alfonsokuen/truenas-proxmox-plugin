#!/usr/bin/perl
# Write and verify a self-describing block pattern, and localise any damage.
#
# Silent corruption is only detectable by comparison, so this fills a device
# with content that can be regenerated exactly from (seed, offset) and later
# checked block by block. Every 4 KiB block carries its own offset in a header,
# which means a block that arrives at the wrong place is caught as well as one
# whose bytes changed - and NSID recycling, the failure mode that would hand a
# mover the wrong device entirely, shows up as every block being wrong with a
# coherent offset field belonging to some other volume.
#
# The body is a fixed pseudo-random buffer XORed with the block's own offset.
# That keeps it incompressible and undedupable, so ZFS cannot quietly turn the
# write into metadata and skip the transport we are trying to test.
#
# When blocks do differ, the offsets are reported modulo the transfer sizes that
# matter. A fault that lands only on multiples of max_sectors_kb is a very
# different bug from one scattered at random, and that distinction is the whole
# reason this exists rather than a plain sha256sum.
#
#   i32-blockverify.pl write  <path> <bytes|4G> [seed]
#   i32-blockverify.pl verify <path> <bytes|4G> [seed]
#
# Exit: 0 clean, 1 mismatches found, 2 usage or I/O error.

use strict;
use warnings;
use IO::Handle;

use constant BLK   => 4096;
use constant CHUNK => 256;            # blocks built per syswrite/sysread
use constant MAGIC => 'IDK32BLK';     # exactly 8 bytes
use constant HDR   => 32;

my ($mode, $path, $size, $seed) = @ARGV;
usage() unless defined $mode && defined $path && defined $size;
$seed = 0 unless defined $seed;
die "seed must be a non-negative integer\n" unless $seed =~ /\A[0-9]+\z/;

my $bytes = parse_size($size);
die "size must be a positive multiple of " . BLK . "\n"
    if $bytes <= 0 || $bytes % BLK;

my $nblocks = $bytes / BLK;

# One fixed noise buffer, derived from the seed. xorshift64 is not a good
# random number generator and does not need to be: it only has to be identical
# on both sides of the copy and hard to compress.
my $NOISE = do {
    # The 64-bit literals below are only "non-portable" on a 32-bit perl, which
    # no Proxmox node has. Silencing it keeps the run's output free of noise
    # that has nothing to do with what we are measuring.
    no warnings 'portable';
    my $s = ($seed ^ 0x9E3779B97F4A7C15) & 0xFFFFFFFFFFFFFFFF;
    $s = 1 unless $s;
    my $buf = '';
    for (1 .. BLK / 8) {
        $s ^= ($s << 13) & 0xFFFFFFFFFFFFFFFF;
        $s ^= ($s >> 7);
        $s ^= ($s << 17) & 0xFFFFFFFFFFFFFFFF;
        $buf .= pack('Q<', $s);
    }
    $buf;
};
my $NOISE_BODY = substr($NOISE, HDR);          # BLK - HDR bytes

# The mask must differ from its neighbours in every byte, not just the low ones.
# Packing the raw offset looks offset-dependent but is not: offsets step by 4096,
# so the top five bytes are constant over any realistic device and consecutive
# blocks differ in about one byte in eight. Two things break because of that.
# ZFS compresses the volume roughly 2:1 at a 64K volblocksize, so the transport
# under test never carries the bytes we think it does; and a whole foreign 4 KiB
# buffer landing at the wrong offset reads out as ~12% of bytes differing, which
# looks like light bit-rot rather than the misplaced buffer #45 predicts.
# Hashing the offset first makes every mask byte vary between neighbours.
sub mask_for {
    no warnings 'portable';
    my ($off) = @_;
    my $m = ($off ^ 0xD6E8FEB86659FD93) & 0xFFFFFFFFFFFFFFFF;
    $m ^= ($m << 13) & 0xFFFFFFFFFFFFFFFF;
    $m ^= ($m >> 7);
    $m ^= ($m << 17) & 0xFFFFFFFFFFFFFFFF;
    return pack('Q<', $m & 0xFFFFFFFFFFFFFFFF);
}

sub block_at {
    my ($off) = @_;
    my $hdr  = MAGIC . pack('Q<Q<Q<', $off, $seed, $nblocks);
    my $mask = mask_for($off) x ((BLK - HDR) / 8);
    return $hdr . ($NOISE_BODY ^ $mask);
}

sub chunk_at {
    my ($off, $n) = @_;
    my $out = '';
    $out .= block_at($off + $_ * BLK) for 0 .. $n - 1;
    return $out;
}

# ---------------------------------------------------------------------------

if ($mode eq 'write') {
    # +< only, never >. The target is always a volume that already exists, so a
    # create-or-truncate fallback could not help - but it could hurt: if the
    # device node vanished between the caller's check and this open (a pool
    # suspending, a concurrent destroy, udev lag), > would silently create a
    # regular file at the device's path in devtmpfs and pour gigabytes of
    # pattern into RAM on a hypervisor. Failing is the correct answer.
    open(my $fh, '+<', $path)
        or die "cannot open $path for writing: $!\n"
             . "(this tool never creates its target; the volume must exist already)\n";
    binmode $fh;
    my $off = 0;
    while ($off < $bytes) {
        my $n = CHUNK;
        my $left = ($bytes - $off) / BLK;
        $n = $left if $left < $n;
        my $buf = chunk_at($off, $n);
        my $w = 0;
        while ($w < length($buf)) {
            my $r = syswrite($fh, $buf, length($buf) - $w, $w);
            die "write failed at offset " . ($off + $w) . ": $!\n" unless defined $r;
            die "short write at offset " . ($off + $w) . "\n" if $r == 0;
            $w += $r;
        }
        $off += $n * BLK;
    }
    # A pattern sitting in page cache proves nothing about the transport.
    my $ok = eval { $fh->sync; 1 };
    unless ($ok) {
        system('sync') == 0 or warn "sync(1) failed; data may still be cached\n";
    }
    close($fh) or die "close failed: $!\n";
    printf "wrote %d block(s), %d byte(s), seed %s\n", $nblocks, $bytes, $seed;
    exit 0;
}

usage() unless $mode eq 'verify';

my ($nbad, $bad, $hist) = scan();

if (!$nbad) {
    printf "verified %d block(s), %d byte(s), seed %s: clean\n", $nblocks, $bytes, $seed;
    exit 0;
}

printf "MISMATCH: %d of %d block(s) differ (%.4f%%)\n",
    $nbad, $nblocks, 100 * $nbad / $nblocks;

print "\nfirst mismatching blocks:\n";
print "  $_\n" for @$bad;
printf "  ... and %d more\n", $nbad - scalar(@$bad) if $nbad > scalar(@$bad);

# Where the damage lands is the diagnosis - but only once there is enough of it
# to have a shape. With one or two bad blocks every transfer size trivially
# shows a single residue, which says nothing at all; printing it anyway would
# manufacture a pattern out of a sample of one.
if ($nbad < 3) {
    print "\nToo few mismatches to say anything about alignment; read the lines above.\n";
    exit 1;
}

print "\noffset alignment of mismatching blocks:\n";
my ($period, $period_at, $period_span);
for my $sz (sort { $a <=> $b } keys %$hist) {
    my $distinct = scalar keys %{ $hist->{$sz}{residue} };
    my $span     = scalar keys %{ $hist->{$sz}{span} };
    # Sharing a residue is only meaningful if the damage recurs across several
    # periods. Three bad blocks inside one megabyte trivially share a residue
    # modulo 4M, and calling that "periodic" would invent a pattern.
    my $real = ($distinct == 1 && $span >= 3);
    if ($real) {
        ($period_at) = keys %{ $hist->{$sz}{residue} };
        $period = $sz;                 # keep the largest that still qualifies
        $period_span = $span;
    }
    printf "  %-5s : %d distinct residue(s) of %d possible, across %d period(s)%s\n",
        human($sz), $distinct, $sz / BLK, $span,
        ($distinct == 1 ? ($real ? '   <-- periodic' : '   (one residue, too few periods)') : '');
}

if (defined $period) {
    printf <<'PERIODIC', human($period), $period_at, human($period_at), $period_span, human($period);

Every mismatching block sits at the same offset within each %s - byte %d (%s)
into the period - and it recurs across %d of them. That is a periodic fault,
which is what a transport splitting I/O on a boundary looks like: the shape
described in issue #45. Compare %s against max_sectors_kb on the initiator
before concluding anything.
PERIODIC
} else {
    print "\nNo transfer size groups the mismatches, so they are not periodic.\n";
    print "That argues against a boundary-splitting fault and towards damage that\n";
    print "followed the data - read the per-block lines above.\n";
}
exit 1;

# ---------------------------------------------------------------------------

sub scan {
    open(my $fh, '<', $path) or die "cannot open $path for reading: $!\n";
    binmode $fh;
    my (@bad, %hist);
    my $n_bad = 0;
    my $off = 0;
    while ($off < $bytes) {
        my $n = CHUNK;
        my $left = ($bytes - $off) / BLK;
        $n = $left if $left < $n;
        my $want = $n * BLK;
        my $got = '';
        while (length($got) < $want) {
            my $r = sysread($fh, my $b, $want - length($got));
            die "read failed at offset " . ($off + length($got)) . ": $!\n"
                unless defined $r;
            die sprintf("short device: wanted %d byte(s), reached end at %d\n",
                $bytes, $off + length($got)) if $r == 0;
            $got .= $b;
        }
        if ($got ne chunk_at($off, $n)) {
            for my $i (0 .. $n - 1) {
                my $o = $off + $i * BLK;
                my $g = substr($got, $i * BLK, BLK);
                next if $g eq block_at($o);
                $n_bad++;
                push @bad, describe($o, $g) if @bad < 40;
                for my $sz (64*1024, 128*1024, 256*1024, 512*1024, 1024*1024, 4*1024*1024) {
                    $hist{$sz}{residue}{ $o % $sz } = 1;
                    # Which period the block falls in, not just where inside it.
                    # Damage confined to one period shares a residue trivially
                    # and says nothing about periodicity.
                    $hist{$sz}{span}{ int($o / $sz) } = 1;
                }
            }
        }
        $off += $want;
    }
    close($fh);
    return ($n_bad, \@bad, \%hist);
}

sub describe {
    my ($o, $g) = @_;
    my $magic = substr($g, 0, 8);
    if ($magic ne MAGIC) {
        my $what = ($g !~ tr/\0//c) ? 'block reads back as all zeroes'
                                    : 'unrecognised data, no header of ours';
        return sprintf("offset %d (%s): %s", $o, human($o), $what);
    }
    my ($gotoff, $gotseed) = unpack('Q<Q<', substr($g, 8, 16));
    if ($gotoff != $o) {
        return sprintf("offset %d (%s): holds the block written at offset %d - data landed in the wrong place",
            $o, human($o), $gotoff);
    }
    if ($gotseed != $seed) {
        return sprintf("offset %d (%s): carries seed %s, not %s - this is another run's data",
            $o, human($o), $gotseed, $seed);
    }
    my $x = substr($g, HDR) ^ substr(block_at($o), HDR);
    my $diff = ($x =~ tr/\0//c);
    return sprintf("offset %d (%s): header intact, %d of %d body byte(s) differ",
        $o, human($o), $diff, BLK - HDR);
}

sub parse_size {
    my ($s) = @_;
    die "size '$s' is not a number, optionally suffixed K/M/G/T\n"
        unless $s =~ /\A([0-9]+)([KMGT])?B?\z/i;
    my ($n, $u) = ($1, $2);
    return $n * ({ K => 1024, M => 1024**2, G => 1024**3, T => 1024**4 }->{uc $u})
        if defined $u;
    return $n;
}

sub human {
    my ($n) = @_;
    return sprintf("%dG", $n / 1024**3) if $n >= 1024**3 && $n % 1024**3 == 0;
    return sprintf("%dM", $n / 1024**2) if $n >= 1024**2 && $n % 1024**2 == 0;
    return sprintf("%dK", $n / 1024)    if $n >= 1024    && $n % 1024 == 0;
    return "$n";
}

sub usage {
    print STDERR "usage: $0 write  <path> <bytes|4G> [seed]\n";
    print STDERR "       $0 verify <path> <bytes|4G> [seed]\n";
    exit 2;
}
