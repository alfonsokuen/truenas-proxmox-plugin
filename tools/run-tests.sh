#!/usr/bin/env bash
#
# Test runner that refuses to report a green it cannot justify.
#
# The suite skips cleanly when its environment is missing, which is good hygiene
# and a trap for CI: a plain `prove -r t/` on a bare container exits 0 having
# exercised nothing. Measured 2026-08-19 on a clean checkout: of 28 files, 15
# could not load the plugin, one hung forever, and the rest died on absent env
# vars -- while the harness would still have reported success.
#
# So a pass here has to survive three independent checks, because any one of
# them alone can be satisfied while proving nothing:
#
#   1. every expected file was DISCOVERED   (a deleted directory is not a pass)
#   2. enough files EXECUTED                (a skipped suite is not a pass)
#   3. enough real assertions RAN           (13 files asserting nothing is not a pass)
#
# Usage:
#   tools/run-tests.sh unit          # no cabinet needed; needs PVE perl modules
#   tools/run-tests.sh integration   # needs a real TrueNAS (TN_HOST/TN_API_KEY/STORAGE_ID)
#   tools/run-tests.sh all
#
# Tunables (all must be non-negative integers; floors must be > 0):
#   MIN_UNIT_TESTS / MIN_UNIT_ASSERTS
#   MIN_INTEGRATION_TESTS / MIN_INTEGRATION_ASSERTS
#   TEST_TIMEOUT   per-file seconds, must be > 0

set -uo pipefail

SUITE="${1:-unit}"
if [ "$#" -gt 1 ]; then
  echo "unexpected argument: $2" >&2
  echo "usage: $0 [unit|integration|all]" >&2
  exit 2
fi

TEST_TIMEOUT="${TEST_TIMEOUT:-120}"

# Floors are observations, not aspirations: the counts seen when the environment
# is correct. Raise them when tests are added; never lower one to make a red
# build green -- and the validation below makes "0" impossible, so that rule is
# enforced rather than merely written down.
#
# unit: measured 2026-08-19 on a PVE 9.2.4 node -- 13 files, 263 assertions.
MIN_UNIT_TESTS="${MIN_UNIT_TESTS:-13}"
MIN_UNIT_ASSERTS="${MIN_UNIT_ASSERTS:-263}"
# integration: NOT calibrated -- no lab cabinet has run this suite end to end.
# The defaults below are deliberately impossible to satisfy by accident; set
# them explicitly from a measured run before wiring this suite into CI.
MIN_INTEGRATION_TESTS="${MIN_INTEGRATION_TESTS:-15}"
MIN_INTEGRATION_ASSERTS="${MIN_INTEGRATION_ASSERTS:-1}"

# --- validate tunables before anything else -----------------------------------
# `[ "$x" -lt "$y" ]` with a non-integer returns 2, and `if` treats any non-zero
# as "condition false" -- which silently turns the floor check into a no-op and
# reports PASS. Reject bad values up front instead.
for var in MIN_UNIT_TESTS MIN_UNIT_ASSERTS MIN_INTEGRATION_TESTS \
           MIN_INTEGRATION_ASSERTS TEST_TIMEOUT; do
  value="${!var}"
  if ! [[ "$value" =~ ^[0-9]+$ ]]; then
    echo "FATAL: $var='$value' is not an integer; refusing to run with a floor" \
         "that cannot be compared." >&2
    exit 2
  fi
  if [ "$value" -le 0 ]; then
    echo "FATAL: $var=$value -- a zero floor or timeout disables the guard." >&2
    exit 2
  fi
done

case "$SUITE" in
  unit)        DIRS=(t/nvme) ;;
  integration) DIRS=(t/rate-limit t/broker) ;;
  all)         DIRS=(t/nvme t/rate-limit t/broker) ;;
  *) echo "usage: $0 [unit|integration|all]" >&2; exit 2 ;;
esac

# A missing directory must be an error, not a smaller suite. Without this,
# renaming t/broker leaves the integration floor satisfied by t/rate-limit
# alone and the run goes green without ever mentioning the absence.
for dir in "${DIRS[@]}"; do
  if [ ! -d "$dir" ]; then
    echo "FATAL: expected test directory '$dir' does not exist." >&2
    exit 2
  fi
done

mapfile -d '' -t FILES < <(find "${DIRS[@]}" -name '*.t' -type f -print0 | sort -z)
if [ "${#FILES[@]}" -eq 0 ]; then
  echo "FATAL: no .t files found under ${DIRS[*]}." >&2
  exit 2
fi

ran=0 skipped=0 failed=0 hung=0 total_asserts=0
failed_names=() skipped_names=() hung_names=()

tmp_out="$(mktemp)"
trap 'rm -f "$tmp_out"' EXIT

for file in "${FILES[@]}"; do
  name=${file#t/}

  # Redirect to a file rather than capturing with $( ): command substitution
  # blocks until every inherited descriptor closes, so a test that forks a
  # daemon keeping stdout open would hang past the timeout and still report
  # rc=0. Writing to a file decouples the exit status from pipe closure.
  # -k sends SIGKILL to anything that ignores SIGTERM; </dev/null stops a test
  # from blocking on input that will never arrive.
  timeout -k 10 "$TEST_TIMEOUT" perl -I. "$file" </dev/null >"$tmp_out" 2>&1
  rc=$?
  output="$(cat "$tmp_out")"

  if [ $rc -eq 124 ] || [ $rc -eq 137 ]; then
    hung=$((hung + 1)); hung_names+=("$name")
    printf 'HUNG    %-42s (exceeded %ss)\n' "$name" "$TEST_TIMEOUT"
    continue
  fi

  # Count first, classify second. Doing it the other way round lets a file that
  # merely CONTAINS the text "# SKIP" -- in a diag line, an error message, or an
  # indented subtest plan -- be filed as skipped, discarding its failures.
  asserts=$(grep -cE '^(ok|not ok) ' <<<"$output")
  bad=$(grep -cE '^not ok ' <<<"$output")

  # Assertions marked skipped inside the file (Test::More's `skip "...", N`)
  # print lowercase `ok N # skip ...`. They match the assertion pattern above
  # but exercised no code, so they must not count toward the assertion floor.
  skipped_asserts=$(grep -cE '^ok [0-9]+ *# *skip' <<<"$output")
  real_asserts=$((asserts - skipped_asserts))

  # An honest whole-file skip is a complete top-level plan line. Anchored, and
  # only trusted when the file also produced no failures.
  if [ "$bad" -eq 0 ] && grep -qE '^1\.\.0( +# +SKIP.*)?$' <<<"$output"; then
    skipped=$((skipped + 1)); skipped_names+=("$name")
    printf 'skip    %-42s %s\n' "$name" \
      "$(grep -oE '# SKIP.*' <<<"$output" | head -1 | cut -c1-58)"
    continue
  fi

  if [ "$bad" -gt 0 ]; then
    failed=$((failed + 1)); failed_names+=("$name")
    printf 'FAIL    %-42s %s of %s assertions failed\n' "$name" "$bad" "$asserts"
    continue
  fi

  # A plan was announced but nothing was asserted, or the file exited non-zero:
  # it died before testing. Never mistake that for a pass just because no
  # "not ok" was printed.
  if [ "$real_asserts" -eq 0 ] || [ $rc -ne 0 ]; then
    failed=$((failed + 1)); failed_names+=("$name")
    reason=$(grep -m1 -E "Missing required|Can't locate|Cannot |error" <<<"$output" | cut -c1-58)
    printf 'DIED    %-42s rc=%s %s\n' "$name" "$rc" \
      "${reason:-no real assertions emitted}"
    continue
  fi

  # Every file here uses done_testing(), which emits its plan last. No plan
  # means the process was truncated -- POSIX::_exit, a stray exec, a forked
  # child stealing the stream -- which would otherwise read as partial success.
  plan=$(grep -oE '^1\.\.[0-9]+$' <<<"$output" | tail -1)
  if [ -z "$plan" ]; then
    failed=$((failed + 1)); failed_names+=("$name")
    printf 'DIED    %-42s rc=%s TAP has no plan line (truncated)\n' "$name" "$rc"
    continue
  fi
  if [ "${plan#1..}" -ne "$asserts" ]; then
    failed=$((failed + 1)); failed_names+=("$name")
    printf 'FAIL    %-42s plan says %s, %s assertions emitted\n' \
      "$name" "${plan#1..}" "$asserts"
    continue
  fi

  ran=$((ran + 1))
  total_asserts=$((total_asserts + real_asserts))
  if [ "$skipped_asserts" -gt 0 ]; then
    printf 'ok      %-42s %s assertions (%s skipped inside)\n' \
      "$name" "$real_asserts" "$skipped_asserts"
  else
    printf 'ok      %-42s %s assertions\n' "$name" "$real_asserts"
  fi
done

case "$SUITE" in
  unit)        floor=$MIN_UNIT_TESTS;        assert_floor=$MIN_UNIT_ASSERTS ;;
  integration) floor=$MIN_INTEGRATION_TESTS; assert_floor=$MIN_INTEGRATION_ASSERTS ;;
  all)         floor=$((MIN_UNIT_TESTS + MIN_INTEGRATION_TESTS))
               assert_floor=$((MIN_UNIT_ASSERTS + MIN_INTEGRATION_ASSERTS)) ;;
esac

echo
echo "suite=$SUITE  discovered=${#FILES[@]}  ran=$ran  skipped=$skipped" \
     "failed=$failed  hung=$hung"
echo "floors: files>=$floor  assertions>=$assert_floor  (got $total_asserts)"

verdict=0

if [ "$failed" -gt 0 ] || [ "$hung" -gt 0 ]; then
  echo
  for n in ${failed_names+"${failed_names[@]}"}; do echo "  failed: $n"; done
  for n in ${hung_names+"${hung_names[@]}"};   do echo "  hung:   $n"; done
  verdict=1
fi

# The point of the whole script: everything above can pass while proving nothing.
if [ "$ran" -lt "$floor" ]; then
  echo
  echo "only $ran file(s) executed assertions, floor is $floor."
  echo "The environment is incomplete, so the suite was never really exercised."
  echo "Fix the environment; do not lower the floor."
  for n in ${skipped_names+"${skipped_names[@]}"}; do echo "  skipped: $n"; done
  verdict=1
fi

# Files can execute while asserting almost nothing -- for instance when a
# renamed helper turns a whole SKIP: block into no-ops. Counting files alone
# would not notice.
if [ "$total_asserts" -lt "$assert_floor" ]; then
  echo
  echo "only $total_asserts real assertion(s) ran, floor is $assert_floor."
  echo "Files executed but exercised far less than expected; a helper was"
  echo "probably renamed or removed, turning SKIP: blocks into no-ops."
  verdict=1
fi

if [ "$verdict" -ne 0 ]; then
  echo "RESULT: FAIL"
  exit 1
fi

echo "RESULT: PASS"
