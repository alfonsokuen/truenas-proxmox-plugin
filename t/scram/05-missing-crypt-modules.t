use strict;
use warnings;
use Test::More;
use FindBin;

# A node whose tree was copied rather than installed from the .deb can lack
# the SCRAM Depends (Crypt::PBKDF2, Crypt::URandom). The broker loads
# TrueNAS::SCRAM late, so it starts; the question is what a login does then.
#
#   auto (or unset) + tn_api_username: the server offers SCRAM, but this node
#     cannot speak it. That is not a reason to take the storage down: fall back
#     to API_KEY_PLAIN (legacy below it), and say so in the log, once.
#   explicit scram / scram-plus: the operator asked for SCRAM, so no fallback;
#     the error names the module that is missing.
#
# Each scenario runs in its own perl: a require that failed cannot be retried
# in the same process (perl answers "Attempt to reload"), so the broker caches
# the first answer, and a test sharing one process would only see that one.
# The missing module is simulated with an @INC hook; the ones the scenario
# does not remove are replaced by stand-ins, so the test does not depend on
# what the host has installed.

my $ROOT   = "$FindBin::Bin/../..";
my $BROKER = "$ROOT/tools/truenas-plugin-broker";

my $DRIVER = <<'PERL';
use strict;
use warnings;
my ($broker, $missing, $mech, $runs) = @ARGV;
my %STAND_IN = (
    'Crypt/PBKDF2.pm'               => 'package Crypt::PBKDF2; sub new { bless {}, shift } 1;',
    'Crypt/PBKDF2/Hash/HMACSHA2.pm' => 'package Crypt::PBKDF2::Hash::HMACSHA2; 1;',
    'Crypt/URandom.pm'              => q{package Crypt::URandom; use Exporter 'import';
                                         our @EXPORT_OK = ('urandom'); sub urandom { 'r' x $_[0] } 1;},
);
(my $missing_file = "$missing.pm") =~ s{::}{/}g;
unshift @INC, sub {
    my (undef, $file) = @_;
    my $src;
    if ($file eq $missing_file) {
        $src = qq{die "Can't locate $file in \\\@INC (you may need to install the $missing module)\\n";};
    } elsif (exists $STAND_IN{$file}) {
        $src = $STAND_IN{$file};
    } else {
        return;
    }
    open my $fh, '<', \$src or die;
    return $fh;
};
require $broker;
no warnings qw(redefine once);
my (@warns, @methods);
*main::linfo = sub { };
*main::lwarn = sub { push @warns, $_[0] };
*main::_extract_tls_server_end_point = sub { ('c' x 32, undef) };
*main::ws_rpc = sub {
    my ($conn, $req) = @_;
    my $m = $req->{method};
    $m .= '/' . $req->{params}[0]{mechanism} if $m eq 'auth.login_ex';
    push @methods, $m;
    return { result => ['SCRAM', 'API_KEY_PLAIN'] } if $m eq 'auth.mechanism_choices';
    return { result => { response_type => 'SUCCESS' } } if $m eq 'auth.login_ex/API_KEY_PLAIN';
    return { result => 1 } if $m eq 'auth.login_with_api_key';
    die "unexpected call $m\n";
};
for my $i (1 .. $runs) {
    @methods = ();
    my $scfg = { api_key => '1-k', api_username => 'alice',
                 ($mech eq 'unset' ? () : (auth_mechanism => $mech)) };
    my $ok = eval { main::_authenticate({ sock => undef, next_id => 1 }, $scfg); 1 };
    (my $err = $@ // '') =~ s/\n/ /g;
    print "RUN $i ", ($ok ? 'ok' : "die $err"), "\n";
    print "CALLS $i @methods\n";
}
print "WARN $_\n" for @warns;
PERL

sub scenario {
    my ($missing, $mech, $runs) = @_;
    open(my $fh, '-|', $^X, "-I$ROOT/lib", '-e', $DRIVER, $BROKER, $missing, $mech, $runs)
        or die "cannot run perl: $!";
    my @out = <$fh>;
    close $fh;
    chomp @out;
    my (%run, %calls, @warns);
    for (@out) {
        if    (/^RUN (\d+) (.*)$/)   { $run{$1} = $2 }
        elsif (/^CALLS (\d+) ?(.*)$/) { $calls{$1} = $2 }
        elsif (/^WARN (.*)$/)        { push @warns, $1 }
    }
    diag(join "\n", @out) if !%run;
    return (\%run, \%calls, \@warns);
}

for my $missing (qw(Crypt::PBKDF2 Crypt::URandom)) {
    for my $mech (qw(auto unset)) {
        my ($run, $calls, $warns) = scenario($missing, $mech, 2);
        is($run->{1}, 'ok', "$missing missing, mechanism $mech: login succeeds");
        is($calls->{1}, 'auth.mechanism_choices auth.login_ex/API_KEY_PLAIN',
            '  ...by API_KEY_PLAIN, without sending a SCRAM message');
        is($run->{2}, 'ok', '  ...and again on the next connection');
        my @fallback = grep { /SCRAM/ && /\Q$missing\E/ && /API_KEY_PLAIN/ } @$warns;
        is(scalar(@fallback), 1, '  ...logging the fallback once, naming the module')
            or diag(join "\n", @$warns);
    }
    for my $mech (qw(scram scram-plus)) {
        my ($run, $calls) = scenario($missing, $mech, 2);
        like($run->{1} // '', qr/^die /, "$missing missing, mechanism $mech: login fails");
        like($run->{1} // '', qr/\Q$missing\E/, '  ...naming the missing module');
        unlike($calls->{1} // '', qr/API_KEY_PLAIN|login_with_api_key/, '  ...with no weaker login tried');
        # perl refuses a second require of a file that failed to compile
        # ("Attempt to reload"), which would hide the module from then on.
        like($run->{2} // '', qr/\Q$missing\E/, '  ...and the next connection still names it');
    }
}

# The legacy floor below API_KEY_PLAIN still works: a pre-25.10 server
# (no login_ex) behind the same fallback ends on login_with_api_key. Covered
# by t/scram/02 for the T2 -> T3 step; nothing SCRAM-specific to add here.

done_testing;
