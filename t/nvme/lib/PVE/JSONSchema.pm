package PVE::JSONSchema;

# Minimal stand-in for PVE::JSONSchema (see PVE::Tools stub in this same
# directory for why). TrueNASPlugin.pm only needs get_standard_option() to
# resolve at compile time; its return value is never inspected by these
# tests, since they call the plugin's subs directly rather than going
# through PVE::Storage::Plugin's option-parsing machinery.

use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(get_standard_option get_format);

# The format validators ('pve-storage-server', ...) are registered by the real
# module only; the stand-in has none, and t/nvme/26 skips its format checks
# when this returns undef ("format validators not registered here").
sub get_format {
    return undef;
}

sub get_standard_option {
    my ($name, $override) = @_;
    return { %{ $override // {} } };
}

1;
