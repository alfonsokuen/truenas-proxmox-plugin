#!/usr/bin/perl
use strict;
use warnings;
use Errno ();
use File::Temp qw(tempdir);
use IO::Socket::UNIX ();
use Socket qw(SOCK_STREAM);
use Test::More;

# The broker refuses connections during its drain with shutdown(SHUT_RD) on
# the shared listener. That relies on Linux af_unix: connect() to a listener
# whose receive side is shut down fails at once with ECONNREFUSED, which the
# plugin client retries (t/broker/10). Other kernels are not the target.
plan skip_all => 'AF_UNIX listener shutdown semantics are Linux kernel behaviour' unless $^O eq 'linux';

my $dir = tempdir(CLEANUP => 1);
my $path = "$dir/broker.sock";
my $srv = IO::Socket::UNIX->new(Local => $path, Listen => 5, Type => SOCK_STREAM) or die "listen: $!";
ok(IO::Socket::UNIX->new(Peer => $path, Type => SOCK_STREAM), 'a listening socket accepts a connect');
ok($srv->shutdown(0), 'shutdown(SHUT_RD) on the listener succeeds');
my $client = IO::Socket::UNIX->new(Peer => $path, Type => SOCK_STREAM);
my $refused = !$client && $!{ECONNREFUSED};
ok($refused, 'a connect after the shutdown is refused at once (ECONNREFUSED)');
ok(-S $path, 'the path stays published while the drain runs');
done_testing;
