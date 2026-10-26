#!/usr/bin/perl
# The plugin parses JSON on every answer from TrueNAS, and so does the broker (several
# passes per answer). JSON::PP is pure Perl: measured on pve2 with a 352 KB answer,
# decode takes 258 ms with JSON::PP and 4.8 ms with JSON::XS. Dataset queries return
# answers of that size.
#
# So the plugin DECODES with JSON::XS when it is installed and falls back to JSON::PP
# when it is not (or when TRUENAS_PLUGIN_JSON_PP is set, as an escape hatch). It still
# ENCODES with JSON::PP: JSON::XS 4.04 on Perl 5.40 sends a number that was ever used
# in a string as a JSON string, which TrueNAS rejects (see the volsize case below).
# What must NOT change is what is sent: booleans built as JSON::PP::true/false still
# encode as true/false, numbers stay numbers, and 64-bit integers, numeric strings and
# UTF-8 survive; the decoded booleans have the same class as before.
#
# Run with:  prove -v -I t/nvme/lib t/nvme/39-json-backend.t
use strict;
use warnings;
use Test::More;
use FindBin;
use JSON::PP ();

my $PLUGIN = "$FindBin::Bin/../../TrueNASPlugin.pm";
unless (eval { require $PLUGIN; 1 }) {
    plan skip_all => "cannot load TrueNASPlugin.pm (needs PVE perl modules): $@";
}
my $PKG = 'PVE::Storage::Custom::TrueNASPlugin';
my $HAVE_XS = eval { require JSON::XS; JSON::XS->VERSION(4.0); 1 } ? 1 : 0;

no strict 'refs';
my $enc = \&{"${PKG}::encode_json"};
my $dec = \&{"${PKG}::decode_json"};
ok(defined &{"${PKG}::encode_json"} && defined &{"${PKG}::decode_json"}, 'the plugin has encode_json and decode_json');

SKIP: {
    skip 'JSON::XS 4.0+ is not installed here', 2 unless $HAVE_XS;
    skip 'TRUENAS_PLUGIN_JSON_PP is set: the pure-Perl backend is forced on purpose', 2 if $ENV{TRUENAS_PLUGIN_JSON_PP};
    is($dec, \&JSON::XS::decode_json, 'JSON::XS is installed: the plugin DECODES with it (that is where the time goes)');
    is($enc, \&JSON::PP::encode_json, 'but ENCODES with JSON::PP: what is sent to TrueNAS must not change');
}

# Why encoding stays with JSON::PP. JSON::XS 4.04 on Perl 5.40 encodes a number that
# was ever interpolated into a string (a log line, a message) as a JSON STRING:
# "1073741824" instead of 1073741824. TrueNAS validates types, so a stringified
# volsize is rejected ("Input should be a valid integer") and no disk can be created.
# Found by allocating a real volume on a node with libjson-xs-perl installed; every
# unit test passed because the fake upstream never validated types.
{
    my $size = 1048576 * 1024;
    my $text = "allocating $size bytes";          # the number is now also a string
    like($enc->({ volsize => $size }), qr/"volsize":1073741824[,}]/,
        'a number that was also used as a string is still sent as a NUMBER');
    my $count = int(2.0);
    my $line = "disks: $count";
    like($enc->([ $count ]), qr/^\[2\]$/, 'int() + interpolation is still a number');
}

# The escape hatch and the fallback, in a clean process so the choice is made at load time.
{
    my $inc = join(' ', map { "-I'$_'" } grep { defined && length } @INC);
    my $probe = q{require $ARGV[0]; my $p = "PVE::Storage::Custom::TrueNASPlugin"; no strict "refs"; print((\&{"${p}::encode_json"} == \&JSON::PP::encode_json) ? "PP" : "OTHER");};
    my $out = `TRUENAS_PLUGIN_JSON_PP=1 $^X $inc -MJSON::PP -e '$probe' '$PLUGIN' 2>&1`;
    is($out, 'PP', 'TRUENAS_PLUGIN_JSON_PP=1 forces the pure-Perl backend');
}

# Same answers whatever the backend: compare the plugin's functions against JSON::PP.
my $corpus = {
    t => JSON::PP::true, f => JSON::PP::false, nothing => undef,
    int => 1024, neg => -5, float => 1.5,
    big => 9223372036854775000,                  # a zvol size in bytes, above 2**53
    numstr => '1024', zero_str => '0', empty => '',
    utf8 => "caf\x{e9} \x{4e2d}\x{6587}",
    nested => { list => [ 1, 'a', JSON::PP::true, { deep => [ undef, '2' ] } ] },
};
my $json = JSON::PP->new->canonical->utf8->encode($corpus);

my $back = $dec->($json);
is_deeply([ map { ref(\$back->{$_}) } qw(int) ], ['SCALAR'], 'decoded ints are plain scalars');
is($back->{big}, '9223372036854775000', 'a 64-bit integer survives a decode untouched');
is($back->{numstr}, '1024', 'a numeric string stays a string');
ok(ref($back->{t}) eq ref(JSON::PP::decode_json('{"x":true}')->{x}), 'decoded booleans have the same class as JSON::PP produces');
ok($back->{t} && !$back->{f}, 'decoded booleans keep their truth value');
ok(!defined $back->{nothing}, 'null decodes to undef');
is($back->{utf8}, $corpus->{utf8}, 'UTF-8 survives a decode');

my $again = JSON::PP->new->canonical->utf8->decode($enc->($corpus));
is_deeply($again, JSON::PP::decode_json($json), 'what the plugin encodes, JSON::PP decodes to the same structure');
like($enc->({ a => JSON::PP::true, b => JSON::PP::false }), qr/"a":true/, 'JSON::PP::true is encoded as true');
like($enc->({ a => JSON::PP::true, b => JSON::PP::false }), qr/"b":false/, 'JSON::PP::false is encoded as false');
like($enc->({ s => '1024', i => 1024 }), qr/"s":"1024"/, 'a numeric string is encoded as a string');
like($enc->({ s => '1024', i => 1024 }), qr/"i":1024/, 'an integer is encoded as a number');
like($enc->({ v => 9223372036854775000 }), qr/"v":9223372036854775000/, 'a 64-bit integer is encoded exactly');

done_testing;
