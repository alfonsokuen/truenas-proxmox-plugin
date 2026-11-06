use strict;
use warnings;
use Test::More;
use FindBin;

# t/scram/05 covers the one case where auto may log in without SCRAM although
# the server offers it: a SCRAM module that is simply NOT INSTALLED on this
# node (Crypt::PBKDF2, Crypt::URandom, or TrueNAS::SCRAM itself). Nothing was
# sent, the package's Depends were just not installed, falling back is safe.
#
# Any other load failure is a different thing: a module that is there but does
# not compile, an import that fails, a dependency of those modules that is not
# one of the three. That is a broken node, not a missing package, and a login
# that quietly downgrades past it would hide it. The login fails, in auto too,
# with a message that says SCRAM is broken here and why.
#
# Same harness as t/scram/05: one perl per scenario, modules replaced through
# an @INC hook so the result does not depend on what the host has installed.

my $ROOT   = "$FindBin::Bin/../..";
my $BROKER = "$ROOT/tools/truenas-plugin-broker";

my $DRIVER = <<'PERL';
use strict;
use warnings;
my ($broker, $scenario, $mech) = @ARGV;
my $GOOD_SCRAM = q{package TrueNAS::SCRAM; use Exporter 'import';
    our @EXPORT_OK = qw(scram_split_api_key scram_client_first scram_process_server_first
                        scram_client_final scram_verify_server_final);
    require Crypt::PBKDF2; require Crypt::URandom; 1;};
my %SRC = (
    'Crypt/PBKDF2.pm'               => 'package Crypt::PBKDF2; sub new { bless {}, shift } 1;',
    'Crypt/PBKDF2/Hash/HMACSHA2.pm' => 'package Crypt::PBKDF2::Hash::HMACSHA2; 1;',
    'Crypt/URandom.pm'              => q{package Crypt::URandom; use Exporter 'import';
                                         our @EXPORT_OK = ('urandom'); sub urandom { 'r' x $_[0] } 1;},
    'TrueNAS/SCRAM.pm'              => $GOOD_SCRAM,
);
my %SCENARIO = (
    scram_missing     => { 'TrueNAS/SCRAM.pm' => undef },
    scram_syntax      => { 'TrueNAS/SCRAM.pm' => 'package TrueNAS::SCRAM; sub broken { 1; 1;' },
    pbkdf2_compile    => { 'Crypt/PBKDF2.pm' => 'package Crypt::PBKDF2; my $x = ; 1;' },
    urandom_dies      => { 'Crypt/URandom.pm' => 'package Crypt::URandom; die "cannot open /dev/urandom\n";' },
    import_fails      => { 'TrueNAS/SCRAM.pm' => q{package TrueNAS::SCRAM; use Exporter 'import';
                                                   our @EXPORT_OK = (); 1;} },
    unlisted_dep      => { 'Crypt/PBKDF2.pm' => 'package Crypt::PBKDF2; require Some::Unlisted::Dep; 1;' },
);
my $over = $SCENARIO{$scenario} or die "unknown scenario $scenario\n";
@SRC{keys %$over} = values %$over;
unshift @INC, sub {
    my (undef, $file) = @_;
    return if !exists $SRC{$file} && $file ne 'Some/Unlisted/Dep.pm';
    my $src = $SRC{$file};
    $src = qq{die "Can't locate $file in \\\@INC (you may need to install it)\\n";} if !defined $src;
    open my $fh, '<', \$src or die;
    return $fh;
};
require $broker;
no warnings qw(redefine once);
my (@warns, @methods);
*main::linfo = sub { };
*main::lwarn = sub { push @warns, $_[0] };
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
for my $i (1 .. 2) {
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
    my ($name, $mech) = @_;
    open(my $fh, '-|', $^X, "-I$ROOT/lib", '-e', $DRIVER, $BROKER, $name, $mech)
        or die "cannot run perl: $!";
    my @out = <$fh>;
    close $fh;
    chomp @out;
    my (%run, %calls, @warns);
    for (@out) {
        if    (/^RUN (\d+) (.*)$/)    { $run{$1} = $2 }
        elsif (/^CALLS (\d+) ?(.*)$/) { $calls{$1} = $2 }
        elsif (/^WARN (.*)$/)         { push @warns, $1 }
    }
    diag(join "\n", @out) if !%run;
    return (\%run, \%calls, \@warns);
}

# Missing, and one of the three: auto falls back as in t/scram/05.
for my $mech (qw(auto unset)) {
    my ($run, $calls, $warns) = scenario('scram_missing', $mech);
    is($run->{1}, 'ok', "TrueNAS::SCRAM not installed, mechanism $mech: login succeeds");
    is($calls->{1}, 'auth.mechanism_choices auth.login_ex/API_KEY_PLAIN', '  ...by API_KEY_PLAIN');
    is(scalar(grep { /TrueNAS::SCRAM/ && /missing/ && /API_KEY_PLAIN/ } @$warns), 1,
        '  ...logging the fallback once, naming the module') or diag(join "\n", @$warns);
}

# Present but broken: no fallback, in any mechanism.
my %broken = (
    scram_syntax   => qr/TrueNAS::SCRAM|TrueNAS\/SCRAM/,
    pbkdf2_compile => qr/Crypt\/PBKDF2|syntax error/,
    urandom_dies   => qr/urandom/,
    import_fails   => qr/not exported|import/,
    unlisted_dep   => qr/Some\/Unlisted\/Dep/,
);
for my $name (sort keys %broken) {
    for my $mech (qw(auto unset scram)) {
        my ($run, $calls) = scenario($name, $mech);
        like($run->{1} // '', qr/^die /, "$name, mechanism $mech: login fails");
        like($run->{1} // '', qr/SCRAM .*broken/i, '  ...saying SCRAM is broken on this node');
        like($run->{1} // '', $broken{$name}, '  ...and why');
        unlike($run->{1} // '', qr/is missing/, '  ...not calling it a missing module');
        unlike($calls->{1} // '', qr/API_KEY_PLAIN|login_with_api_key/, '  ...with no weaker login tried');
        like($run->{2} // '', $broken{$name}, '  ...and the next connection still says why');
    }
}

done_testing;
