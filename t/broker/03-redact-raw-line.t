#!/usr/bin/perl
# K6 (Kimi, QA round 3): the broker's own redaction of a raw, possibly
# malformed request line (used only on the "scfg missing api_host/api_key"
# diagnostic path, logged to the journal) covered `api_key` alone - any of
# password/dhchap_key/dhchap_ctrl_key/secret/token in a malformed request
# would have reached the journal in the clear. Extended to the same key
# list TrueNASPlugin.pm's own $TN_LOG_REDACT_KEYS uses, and to a value
# pattern that survives an escaped quote inside the value (a naive
# `[^"]*` stops there and leaves the rest exposed - the same bug class
# fixed in TrueNASPlugin.pm's _tn_redact_for_log(), see
# t/nvme/24-sensitive-secrets.t's R5 tests).
#
# The broker is a standalone daemon script (parses argv and daemonizes at
# the top level when run directly - see t/broker/01-upstream-deadline.t,
# which execs it as a whole process for exactly that reason), so this
# extracts just the pure, side-effect-free redact_raw_line() function (and
# the two patterns it depends on) out of the CURRENT source text and evals
# that snippet alone - testing the real, current implementation without
# starting the daemon.
#
# Run with:  prove -v t/broker/03-redact-raw-line.t

use strict;
use warnings;
use Test::More;
use FindBin;

my $BROKER = "$FindBin::Bin/../../tools/truenas-plugin-broker";
plan skip_all => "broker not found at $BROKER" unless -f $BROKER;

open(my $fh, '<', $BROKER) or die "cannot read $BROKER: $!";
my $source = do { local $/; <$fh> };
close($fh);

my ($snippet) = $source =~
    /(my \$REDACT_KEYS\s*=.*?sub\s+redact_raw_line\s*\{.*?\n\})/s;
unless ($snippet) {
    plan tests => 1;
    fail('could not extract redact_raw_line() and its patterns from the broker source '
       . '- the surrounding code shape changed; update this test\'s extraction regex');
    exit 1;
}

package BrokerRedact;
eval $snippet or die "extracted snippet failed to compile: $@\n$snippet";
package main;

# ---------------------------------------------------------------------
{
    my $redacted = BrokerRedact::redact_raw_line(
        '{"api_key":"1-verysecret","dhchap_key":"DHHC-1:01:xyz:",'
      . '"dhchap_ctrl_key":"DHHC-1:01:abc:","password":"plain-secret",'
      . '"host":"192.0.2.1"}');
    unlike($redacted, qr/verysecret/, 'redact_raw_line: strips api_key');
    unlike($redacted, qr/DHHC-1:01:xyz/, '  ...strips dhchap_key');
    unlike($redacted, qr/DHHC-1:01:abc/, '  ...strips dhchap_ctrl_key');
    unlike($redacted, qr/plain-secret/, '  ...strips password (K6: previously only api_key was covered)');
    like($redacted, qr/"host":"192\.0\.2\.1"/, '  ...and leaves a non-sensitive field alone');
}
{
    # R5-class bug, same fix applied here: an escaped quote inside the
    # value must not stop the redaction early.
    my $redacted = BrokerRedact::redact_raw_line(qq({"password":"a\\"SECRET","host":"h"}));
    unlike($redacted, qr/SECRET/, 'redact_raw_line: an escaped quote inside the value does not leak the rest');
    like($redacted, qr/"host":"h"/, '  ...and a field after it is still left alone');
}
{
    is(BrokerRedact::redact_raw_line(undef), undef,
        'redact_raw_line: passes undef through instead of dying');
}

done_testing();
