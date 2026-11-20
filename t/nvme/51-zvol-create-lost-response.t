#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use FindBin;

require "$FindBin::Bin/../../TrueNASPlugin.pm";
my $pkg = 'PVE::Storage::Custom::TrueNASPlugin';
my $cfg = { tn_dataset => 'tank/pve' };
my $dest = 'tank/pve/vm-100-disk-0';
my $source = 'tank/pve/vm-99-disk-0';
my $snapshot = "$source\@snap";
my $lost = "broker: read timeout\n";
my (@calls, $created, $scenario);

no strict 'refs';
no warnings 'redefine';
local *{"${pkg}::_log"} = sub {};
local *{"${pkg}::_preflight_check_alloc"} = sub { [] };
local *{"${pkg}::_find_free_disk_name"} = sub { 'vm-100-disk-0' };
local *{"${pkg}::_invalidate_status_capacity_cache"} = sub {};
local *{"${pkg}::_alloc_image_iscsi"} = sub { push @calls, ['expose']; return $_[2] };
local *{"${pkg}::_api_call"} = sub {
    my (undef, $method, $params, $opts) = @_;
    push @calls, [$method, $params, $opts];
    if ($method eq 'pool.dataset.create') {
        my $payload = $params->[0];
        die "dataset already exists\n" if $scenario eq 'explicit-exists' && $payload->{name} eq $dest;
        return {} if $scenario eq 'explicit-exists';
        $created = { id => $payload->{name}, type => 'VOLUME', volsize => { parsed => $payload->{volsize} },
            comments => { parsed => $scenario eq 'foreign' ? 'another creator' : ($payload->{comments} // '') } };
        die $lost;
    }
    if ($method eq 'pool.snapshot.clone') {
        my $payload = $params->[0];
        die "dataset already exists\n" if $scenario eq 'explicit-exists';
        $created = { id => $payload->{dataset_dst}, type => 'VOLUME',
            origin => { parsed => $scenario eq 'foreign' ? "$source\@other" : $payload->{snapshot} } };
        die $lost;
    }
    if ($method eq 'pool.dataset.get_instance') {
        die "readback unavailable\n" if $scenario eq 'unreadable';
        return $created;
    }
    die "unexpected API method $method\n";
};

sub run_alloc {
    ($scenario) = @_;
    @calls = ();
    my $vol = eval { $pkg->alloc_image('store', $cfg, 100, 'raw', undef, 16) };
    return ($vol, $@);
}

my ($vol, $error) = run_alloc('lost');
is($vol, 'vm-100-disk-0', 'allocation adopts the exact zvol after its reply is lost') or diag $error;
is_deeply([map { $_->[0] } @calls], ['pool.dataset.create', 'pool.dataset.get_instance', 'expose'],
    'allocation sends one mutation, verifies and exposes the original name');
is($calls[0][2]{retry_opts}{retry_max}, 0, 'pool.dataset.create disables automatic replay');
is($calls[1][1][0], $dest, 'allocation verifies the exact destination');

for my $case (qw(foreign unreadable)) {
    ($vol, $error) = run_alloc($case);
    ok(!defined($vol), "$case readback refuses to adopt the zvol");
    like($error, qr/\Q$dest\E.*read timeout/s, "$case readback keeps the original destination and failure");
    is_deeply([map { $_->[0] } @calls], ['pool.dataset.create', 'pool.dataset.get_instance'],
        "$case readback neither creates another name nor destroys the existing zvol");
}

($vol, $error) = run_alloc('explicit-exists');
is($vol, 'vm-100-disk-1', 'a definitive already-exists reply still selects the next disk name') or diag $error;
is_deeply([map { $_->[0] } @calls], ['pool.dataset.create', 'pool.dataset.create', 'expose'],
    'definitive conflict takes the existing alternate-name path');

my $backup = "$dest-vzdump";
for my $case (qw(lost foreign explicit-exists)) {
    $scenario = $case;
    @calls = ();
    my $ok = eval { $pkg->can('_clone_snapshot_zvol')->($cfg, $source, 'snap', $backup); 1 };
    $error = $@;
    if ($case eq 'foreign') {
        ok(!$ok, 'temporary clone with wrong origin is not adopted');
        like($error, qr/\Q$backup\E.*read timeout/s, 'temporary clone failure includes its destination');
    } else {
        ok($ok, "$case temporary clone with the expected origin or deterministic existing name is reusable") or diag $error;
    }
    is($calls[0][2]{retry_opts}{retry_max}, 0, 'pool.snapshot.clone disables automatic replay');
    is_deeply([map { $_->[0] } @calls], $case eq 'explicit-exists'
        ? ['pool.snapshot.clone'] : ['pool.snapshot.clone', 'pool.dataset.get_instance'],
        "$case clone performs only the expected readback after one mutation");
}

for my $transport ('iscsi', 'nvme-tcp') {
    $scenario = 'lost';
    @calls = ();
    my $srcvol = $transport eq 'iscsi' ? 'vol-vm-99-disk-0-lun0'
        : 'vol-vm-99-disk-0-ns11111111-2222-3333-4444-555555555555';
    my $ok = eval { $pkg->clone_image({%$cfg, tn_transport_mode => $transport}, 'store', $srcvol, 100, 'snap'); 1 };
    $error = $@;
    ok(!$ok, "$transport permanent clone keeps an ambiguous result closed even with a matching origin");
    like($error, qr/\Q$dest\E.*read timeout/s, "$transport permanent clone failure identifies the exact destination");
    is_deeply([map { $_->[0] } @calls], ['pool.snapshot.clone', 'pool.dataset.get_instance'],
        "$transport permanent clone checks the original target and stops without replay or cleanup");
}
done_testing;
