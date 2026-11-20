#!/usr/bin/perl
use strict;
use warnings;
use FindBin;
use File::Temp qw(tempfile);
use Test::More;

plan skip_all => 'bash not available' if system('command -v bash >/dev/null 2>&1') != 0;

my $postinst = "$FindBin::Bin/../../debian/postinst";
open(my $input, '<', $postinst) or die "cannot read $postinst: $!";
my $source = do { local $/; <$input> };
close $input;
my ($unit) = $source =~ /^(BROKER_UNIT=.*)$/m;
my ($function) = $source =~ /^(enable_broker\(\) \{.*?^\})/ms;
die 'could not extract enable_broker and its unit' unless $function && $unit;

my ($script_fh, $script_path) = tempfile(UNLINK => 1);
print {$script_fh} "set -e\nexec 2>&1 3>&1\n$unit\n$function\n";
print {$script_fh} <<'SH';
have_systemd() { return 0; }
sleep() { :; }

old="$1"
enabled="$2"
active_before="$3"
active_after="$4"
action_rc="$5"
socket="$6"
reload_rc="${7:-0}"
attempted=0

systemctl() {
    echo "systemctl $*" >&3
    case "$1" in
        is-enabled)
            if [ "$enabled" = enabled ]; then echo "$enabled"; return 0; fi
            echo "$enabled"
            return 1
            ;;
        is-active)
            if [ "$attempted" = 0 ]; then return "$active_before"; fi
            return "$active_after"
            ;;
        start|try-restart)
            attempted=1
            return "$action_rc"
            ;;
        enable) return 0;;
        daemon-reload) return "$reload_rc";;
        *) exit 127;;
    esac
}

# Simulate the state of the persisted Unix socket independently of systemd.
function [ {
    if builtin [ "$1" = -S ]; then return "$socket"; fi
    if builtin [ "$1" = '!' ] && builtin [ "$2" = -S ]; then return "$((1 - socket))"; fi
    builtin [ "$@"
}

enable_broker "$old"
SH
close $script_fh;

sub configure_broker {
    open(my $shell, '-|', 'bash', $script_path, @_) or die "cannot start bash: $!";
    my $output = do { local $/; <$shell> };
    close $shell;
    return ($? >> 8, $output);
}

my $broker_unit = 'truenas-plugin-broker.service';
subtest 'upgrade only restarts a broker that is enabled and active' => sub {
    my ($exit_status, $output) = configure_broker('1:2.1.24+idk30', 'disabled', 0, 0, 0, 0);
    is($exit_status, 0, 'an intentionally disabled broker is left alone');
    like($output, qr/^systemctl is-enabled \Q$broker_unit\E$/m, 'checks enablement');
    unlike($output, qr/^systemctl (?:enable|start|try-restart) /m, 'no lifecycle action on disabled upgrade');

    ($exit_status, $output) = configure_broker('1:2.1.24+idk30', 'enabled', 0, 0, 0, 0);
    is($exit_status, 0, 'healthy upgrade succeeds');
    like($output, qr/^systemctl try-restart \Q$broker_unit\E$/m, 'active and enabled broker picks up the new binary');
    unlike($output, qr/^systemctl (?:enable|start) /m, 'upgrade leaves enablement unchanged');

    ($exit_status, $output) = configure_broker('1:2.1.24+idk30', 'enabled', 3, 0, 0, 0);
    is($exit_status, 0, 'enabled broker comes back online');
    like($output, qr/^systemctl start \Q$broker_unit\E$/m, 'inactive broker is started');
    unlike($output, qr/^systemctl try-restart /m, 'no restart while inactive');

    ($exit_status, $output) = configure_broker('1:2.1.24+idk30', 'masked', 3, 3, 0, 0);
    is($exit_status, 0, 'an intentionally masked broker is left alone');
    unlike($output, qr/^systemctl (?:enable|start|try-restart) /m, 'no lifecycle action on masked upgrade');
};

subtest 'a stale socket cannot hide failed startup or an inactive service' => sub {
    my ($exit_status, $output) = configure_broker('1:2.1.24+idk30', 'enabled', 3, 3, 1, 0);
    is($exit_status, 0, 'failed startup leaves package configuration successful');
    like($output, qr/WARNING: .*\Q$broker_unit\E/, 'failed startup names the broker unit');

    ($exit_status, $output) = configure_broker('1:2.1.24+idk30', 'enabled', 0, 3, 0, 0);
    is($exit_status, 0, 'inactive broker with a stale socket leaves configuration successful');
    like($output, qr/WARNING: .*\Q$broker_unit\E/, 'inactive service is diagnosed');

    ($exit_status, $output) = configure_broker('1:2.1.24+idk30', 'not-found', 3, 3, 0, 0);
    is($exit_status, 0, 'missing systemd unit with a stale socket leaves configuration successful');
    like($output, qr/WARNING: .*\Q$broker_unit\E/, 'missing unit is diagnosed');

    ($exit_status, $output) = configure_broker('1:2.1.24+idk30', 'enabled', 3, 3, 0, 0, 1);
    is($exit_status, 0, 'failed daemon-reload leaves configuration successful');
    like($output, qr/WARNING: .*\Q$broker_unit\E/, 'failed daemon-reload names the broker unit');

    ($exit_status, $output) = configure_broker('', 'disabled', 3, 0, 0, 0);
    is($exit_status, 0, 'first installation enables and starts the broker');
    like($output, qr/^systemctl enable \Q$broker_unit\E$/m, 'enables on fresh install');
    like($output, qr/^systemctl start \Q$broker_unit\E$/m, 'starts on fresh install');
};

done_testing();
