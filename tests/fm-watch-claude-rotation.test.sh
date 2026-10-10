#!/usr/bin/env bash
# The watcher's half of automatic Claude account rotation (bin/fm-watch.sh
# claude_limit_check and claude_validation_tick): which windows reach the
# rotation, with what evidence, and how its verdict becomes one wake, an absorb
# that skips ordinary stale triage, or a pass that leaves triage unchanged.
#
# A real fm-watch.sh subprocess polls a fake tmux pane. FM_CLAUDE_ROTATE_BIN
# points at a recorder that logs every call and answers the verdict the case
# sets, so these cases pin the watcher's routing; the rotation's own decisions
# are pinned by tests/fm-claude-account-rotation.test.sh.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-claude-rotation)
LIMIT_PANE=$'Working on the tests.\n\n  ⎿  You\'ve hit your session limit · resets 3pm (UTC)\n\n╭──────╮\n│ >    │\n╰──────╯'

# rotation_case <name> <harness> -> sets DIR STATE FAKEBIN WINDOW KEY PANE
rotation_case() {
  DIR=$(make_case "$1")
  STATE="$DIR/state"
  FAKEBIN="$DIR/fakebin"
  WINDOW="test:fm-rot"
  KEY=$(printf '%s' "$WINDOW" | tr ':/.' '___')
  PANE="$DIR/pane.txt"
  mkdir -p "$DIR/config"
  printf '%s\n' "$LIMIT_PANE" > "$PANE"
  printf 'window=%s\nkind=ship\nharness=%s\n' "$WINDOW" "$2" > "$STATE/rot.meta"
  printf 'working: implementing\n' > "$STATE/rot.status"
  prime_status_seen "$STATE" "$STATE/rot.status"
  printf '/pool/a\n/pool/b\n' > "$DIR/config/claude-account"
  cat > "$FAKEBIN/rotate" <<'SH'
#!/usr/bin/env bash
printf 'captures=%s %s\n' "$(cat "$FM_FAKE_TMUX_CAPTURE_COUNT_FILE" 2>/dev/null || echo 0)" "$*" >> "$FM_TEST_ROTATE_LOG"
case "${1:-}" in
  observe) printf '%s\n' "$FM_TEST_ROTATE_VERDICT" ;;
  validation-scan) [ -z "${FM_TEST_ROTATE_SCAN:-}" ] || printf '%s\n' "$FM_TEST_ROTATE_SCAN" ;;
esac
SH
  chmod +x "$FAKEBIN/rotate"
  : > "$DIR/rotate.log"
  : > "$DIR/captures"
}

# Prime the pane as already seen once, so the first poll reads a stable hash.
prime_stable() {
  printf '%s' "$(hash_text "$(cat "$PANE")")" > "$STATE/.hash-$KEY"
  printf '1\n' > "$STATE/.count-$KEY"
}

# watch_run <out> [env...]: start the watcher in the background as WPID.
watch_run() {
  local out=$1
  shift
  PATH="$FAKEBIN:$PATH" FM_FAKE_TMUX_WINDOW="$WINDOW" FM_FAKE_TMUX_CAPTURE="$PANE" \
    FM_FAKE_TMUX_CAPTURE_COUNT_FILE="$DIR/captures" \
    FM_STATE_OVERRIDE="$STATE" FM_CONFIG_OVERRIDE="$DIR/config" FM_CREW_STATE_BIN="$FAKEBIN/fm-crew-state.sh" \
    FM_CLAUDE_ROTATE_BIN="$FAKEBIN/rotate" FM_TEST_ROTATE_LOG="$DIR/rotate.log" \
    FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_SECONDMATE_LIVENESS_SECS=99999999 FM_CLAUDE_ROTATE_VALIDATION_SECS=99999999 \
    env "$@" "$WATCH" > "$out" &
  WPID=$!
}

# The budget is generous because fm-watch.sh does bounded startup work before
# its first poll; a longer wait only removes false negatives on a loaded host.
wait_exit() {  # <pid> -> 0 when it exited within ~30s
  local i=0
  while [ "$i" -lt 300 ]; do
    kill -0 "$1" 2>/dev/null || { wait "$1" 2>/dev/null; return 0; }
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

stop_watch() {
  kill "$WPID" 2>/dev/null
  wait "$WPID" 2>/dev/null
}

# wait_captures <n>: wait until the watcher has captured the pane <n> times,
# one capture per poll of this single window.
wait_captures() {
  local i=0 n
  while [ "$i" -lt 300 ]; do
    n=$(cat "$DIR/captures" 2>/dev/null) || n=
    [ "${n:-0}" -ge "$1" ] && return 0
    kill -0 "$WPID" 2>/dev/null || return 1
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

drained() {
  FM_STATE_OVERRIDE="$STATE" "$DRAIN" 2>/dev/null
}

test_wake_verdict_is_queued_and_surfaced() {
  local out reason="check: claude account rotated: rot relaunched on /pool/b (b@example.com) after a@example.com hit its usage limit"
  rotation_case wake claude
  prime_stable
  out="$DIR/watch.out"
  watch_run "$out" FM_TEST_ROTATE_VERDICT="wake	$reason"
  wait_exit "$WPID" || { stop_watch; fail "a wake verdict must exit the watcher cycle"; }
  assert_equals "$reason" "$(cat "$out")" "the watcher should print the rotation's reason as the wake"
  assert_contains "$(drained)" "$reason" "the rotation wake should be queued durably"
  assert_contains "$(cat "$DIR/rotate.log")" "observe rot --pane-hash $(cat "$STATE/.hash-$KEY")" \
    "the stable limit pane should be observed with its hash"
  assert_contains "$(cat "$DIR/rotate.log")" "--pane-line You've hit your session limit · resets 3pm (UTC)" \
    "the observed evidence should carry the limit line the pane shows"
  pass "a rotation wake verdict is queued and surfaced as one check wake"
}

test_absorb_verdict_skips_stale_triage() {
  local out
  rotation_case absorb claude
  prime_stable
  out="$DIR/watch.out"
  export FM_FAKE_CREW_STATE='state: unknown · source: none · stopped'
  watch_run "$out" FM_TEST_ROTATE_VERDICT="absorb	waiting for a Claude usage reset"
  wait_captures 3 || fail "an absorbed limit must not surface the stopped pane as stale: $(cat "$out")"
  stop_watch
  unset FM_FAKE_CREW_STATE
  assert_equals "" "$(cat "$out")" "an absorbed limit must print no wake"
  [ "$(grep -c ' observe rot' "$DIR/rotate.log")" -ge 2 ] || fail "an absorbed window should be re-observed every poll: $(cat "$DIR/rotate.log")"
  assert_grep "absorbed claude usage limit for rot: waiting for a Claude usage reset" "$STATE/.watch-triage.log" \
    "the absorb should be logged"
  pass "an absorb verdict keeps a limited worker out of ordinary stale triage and is re-observed each poll"
}

test_pass_verdict_falls_through_once() {
  local out
  rotation_case pass claude
  prime_stable
  out="$DIR/watch.out"
  export FM_FAKE_CREW_STATE='state: unknown · source: none · stopped'
  watch_run "$out" FM_TEST_ROTATE_VERDICT="pass	the recorded account is not limited"
  wait_exit "$WPID" || { stop_watch; fail "a passed window should reach ordinary stale triage: $(cat "$out"; tail -n 5 "$STATE/.watch-triage.log" 2>/dev/null)"; }
  unset FM_FAKE_CREW_STATE
  assert_equals "stale: $WINDOW" "$(cat "$out")" "ordinary stale triage should surface the stopped pane"
  [ "$(cat "$STATE/.claude-limit-pass-$KEY")" = "$(cat "$STATE/.hash-$KEY")" ] ||
    fail "the passed pane hash should be remembered"
  FM_STATE_OVERRIDE="$STATE" "$DRAIN" > /dev/null 2> "$DIR/drain.err"
  ack_drain_err "$STATE" "$DIR/drain.err" >/dev/null || fail "the surfaced stale wake should acknowledge"
  : > "$DIR/rotate.log"
  : > "$DIR/captures"
  export FM_FAKE_CREW_STATE='state: unknown · source: none · stopped'
  watch_run "$out" FM_TEST_ROTATE_VERDICT="pass	again"
  wait_captures 3 || fail "an already surfaced stale pane should keep the watcher polling: $(cat "$out")"
  stop_watch
  unset FM_FAKE_CREW_STATE
  assert_no_grep "observe" "$DIR/rotate.log" "the same passed pane must not be observed again"
  pass "a pass verdict leaves stale triage unchanged and is not re-observed for the same pane"
}

test_only_stable_claude_ships_reach_the_rotation() {
  local out
  rotation_case codex codex
  prime_stable
  out="$DIR/watch.out"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  watch_run "$out" FM_TEST_ROTATE_VERDICT="wake	check: must not happen"
  wait_captures 3 || fail "the watcher should keep polling a provably working pane: $(cat "$out")"
  stop_watch
  assert_no_grep "observe" "$DIR/rotate.log" "a non-Claude worker must never reach the Claude rotation"

  rotation_case unstable claude
  out="$DIR/watch.out"
  printf 'some-other-hash' > "$STATE/.hash-$KEY"
  watch_run "$out" FM_TEST_ROTATE_VERDICT="absorb	held"
  wait_captures 3 || fail "an absorbed window should keep the watcher polling: $(cat "$out")"
  stop_watch
  assert_contains "$(head -n 1 "$DIR/rotate.log")" "captures=2 observe rot --pane-hash" \
    "a limit line is observed only once the pane held one hash across two polls, never on its first sight"

  rotation_case quiet claude
  printf 'Working on the tests.\n' > "$PANE"
  prime_stable
  out="$DIR/watch.out"
  watch_run "$out" FM_TEST_ROTATE_VERDICT="wake	check: must not happen"
  wait_captures 3 || fail "a quiet provably working pane should keep the watcher polling: $(cat "$out")"
  stop_watch
  assert_no_grep "observe" "$DIR/rotate.log" "a stable pane with no limit line must not reach the rotation"
  [ "$(cat "$STATE/.claude-limit-pass-$KEY" 2>/dev/null)" = "$(cat "$STATE/.hash-$KEY")" ] ||
    fail "a stable pane read without a limit line should be remembered so it is not re-read every poll"

  rotation_case no-pool claude
  printf '/pool/a\n' > "$DIR/config/claude-account"
  prime_stable
  out="$DIR/watch.out"
  watch_run "$out" FM_TEST_ROTATE_VERDICT="wake	check: must not happen"
  wait_captures 3 || fail "the watcher should keep polling a provably working pane: $(cat "$out")"
  stop_watch
  unset FM_FAKE_CREW_STATE
  assert_no_grep "observe" "$DIR/rotate.log" "a home without a rotation pool must never reach the rotation"
  pass "only a stable limit pane of a Claude ship or scout in a home with a pool reaches the rotation"
}

test_stop_failure_record_reaches_the_rotation_without_a_pane_line() {
  local out
  rotation_case stop-failure claude
  printf 'Working on the tests.\n' > "$PANE"
  printf '%s\tgen-1\trate_limit\tAPI Error\n' "$(date +%s)" > "$STATE/rot.api-error"
  out="$DIR/watch.out"
  watch_run "$out" FM_TEST_ROTATE_VERDICT="wake	check: claude account rotated: rot"
  wait_exit "$WPID" || { stop_watch; fail "a StopFailure record should reach the rotation"; }
  assert_equals "captures=1 observe rot" "$(head -n 1 "$DIR/rotate.log")" "a StopFailure record is observed without pane evidence"
  pass "a StopFailure record reaches the rotation even when the pane shows no limit line"
}

test_validation_scan_wakes_once_per_report() {
  local out reason="check: no-mistakes validation RUN1 for rot failed when its Claude agent hit the usage limit"
  rotation_case validation claude
  printf 'Working on the tests.\n' > "$PANE"
  out="$DIR/watch.out"
  watch_run "$out" FM_TEST_ROTATE_VERDICT="pass	none" FM_CLAUDE_ROTATE_VALIDATION_SECS=1 \
    FM_TEST_ROTATE_SCAN="wake	$reason"
  wait_exit "$WPID" || { stop_watch; fail "a validation report should wake the watcher"; }
  assert_equals "$reason" "$(cat "$out")" "the validation report should be the wake"
  assert_contains "$(drained)" "$reason" "the validation report should be queued durably"

  rotation_case validation-off claude
  printf '/pool/a\n' > "$DIR/config/claude-account"
  out="$DIR/watch.out"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  watch_run "$out" FM_TEST_ROTATE_VERDICT="pass	none" FM_CLAUDE_ROTATE_VALIDATION_SECS=1 \
    FM_TEST_ROTATE_SCAN="wake	$reason"
  wait_captures 3 || fail "a home without a pool should keep polling without a validation wake: $(cat "$out")"
  stop_watch
  unset FM_FAKE_CREW_STATE
  assert_no_grep "validation-scan" "$DIR/rotate.log" "a home without a rotation pool must not scan validation runs"
  pass "the validation scan runs only with a pool and each report wakes once"
}

test_wake_verdict_is_queued_and_surfaced
test_absorb_verdict_skips_stale_triage
test_pass_verdict_falls_through_once
test_only_stable_claude_ships_reach_the_rotation
test_stop_failure_record_reaches_the_rotation_without_a_pane_line
test_validation_scan_wakes_once_per_report

echo "# all fm-watch-claude-rotation tests passed"
