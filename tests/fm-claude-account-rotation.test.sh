#!/usr/bin/env bash
# Behavior tests for automatic Claude account rotation
# (bin/fm-claude-account-rotate.sh over the worker account pin's rotation pool
# in bin/fm-worker-account-lib.sh).
#
# Each case builds a home whose config/claude-account lists a pool of fake
# Claude roots. Every root carries a .claude.json naming its account email and,
# when signed in, a .credentials.json. The fake claude answers `auth status`
# from that login and answers the rotation's live probe with the stream-json a
# real `claude -p` prints, allowed or rejected per the root's `probe` file, and
# logs which root and model each probe used. Rotations drive the REAL
# bin/fm-control.sh relaunch and bin/fm-spawn.sh --relaunch through a tmux stub
# that models the agent lifecycle, so a relaunch is proven by the task record,
# the instructions the replacement reads, and the account it launched on.
# tests/fm-claude-account-rotation-live-e2e.test.sh proves the probe and the
# StopFailure record against the real runner.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-worker-account-lib.sh
. "$ROOT/bin/fm-worker-account-lib.sh"

ROTATE="$ROOT/bin/fm-claude-account-rotate.sh"
TMP_ROOT=$(fm_test_tmproot fm-claude-account-rotation)
unset ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN
FUTURE=4102444800

# make_fakes <case-dir>: fake claude and the agent-lifecycle tmux stub.
make_fakes() {
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/claude" <<SH
#!/usr/bin/env bash
root=\${CLAUDE_CONFIG_DIR:-\$HOME/.claude}
case "\${1:-}" in
  auth) [ -f "\$root/.credentials.json" ]; exit ;;
  -p)
    model=none prev=
    for a in "\$@"; do [ "\$prev" != --model ] || model=\$a; prev=\$a; done
    printf '%s %s\n' "\${CLAUDE_CONFIG_DIR-unset}" "\$model" >> '$dir/probes'
    verdict=\$(head -n 1 "\$root/probe" 2>/dev/null || echo allowed)
    case "\$verdict" in
      rejected*)
        printf '{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":%s,"rateLimitType":"five_hour"}}\n' "\${verdict#rejected }"
        printf '{"type":"result","is_error":true,"api_error_status":429,"result":"You%sve hit your session limit · resets 3pm (UTC)"}\n' "'"
        exit 1 ;;
      error) printf 'Network unreachable\n'; exit 1 ;;
      *)
        printf '{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":$FUTURE}}\n'
        printf '{"type":"result","is_error":false,"subtype":"success","result":"OK"}\n'
        exit 0 ;;
    esac ;;
esac
exit 0
SH
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    payload=${1:-}
    if [ "$literal" = 1 ]; then
      case "$payload" in
        ". '"*"'") staged=${payload#". '"}; staged=${staged%"'"}; [ ! -f "$staged" ] || payload=$(cat "$staged") ;;
      esac
      printf '%s\n' "$payload" >> "$D/literal"
      case "$payload" in
        /exit|/quit) printf 'zsh' > "$D/command" ;;
        *'Firstmate operational input waiting: read'*) printf 'claude' > "$D/command" ;;
      esac
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*) cat "$D/command"; printf '\n'; exit 0 ;;
        *pane_current_path*) cat "$D/cwd"; printf '\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) cat "$D/windows"; exit 0 ;;
esac
exit 0
SH
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/claude" "$fb/tmux" "$fb/sleep"
}

# claude_root <dir> <email> [signed-in|signed-out] [probe-verdict]
claude_root() {
  mkdir -p "$1"
  printf '{"oauthAccount":{"emailAddress":"%s"}}\n' "$2" > "$1/.claude.json"
  [ "${3:-signed-in}" = signed-out ] || printf '{}\n' > "$1/.credentials.json"
  printf '%s\n' "${4:-allowed}" > "$1/probe"
}

# new_case <name> -> sets CASE HOME_DIR STATE ID WT; a live Claude ship whose
# record names account=$CASE/a. Roots a, b, and c are signed in with distinct
# allowed emails; the pool lists a then b.
new_case() {
  CASE="$TMP_ROOT/$1"
  HOME_DIR="$CASE/home"
  STATE="$HOME_DIR/state"
  ID=rot-$1
  WT="$CASE/wt"
  mkdir -p "$STATE" "$HOME_DIR/data/$ID" "$HOME_DIR/config" "$CASE/fake" "$CASE/user-home"
  make_fakes "$CASE"
  fm_git_worktree "$CASE/proj" "$WT" "task-$ID"
  claude_root "$CASE/a" a@example.com
  claude_root "$CASE/b" b@example.com
  claude_root "$CASE/c" c@example.com
  printf '%s\n%s\n' "$CASE/a" "$CASE/b" > "$HOME_DIR/config/claude-account"
  printf 'a@example.com\nB@Example.com\nc@example.com\n' > "$HOME_DIR/config/claude-account-allowlist"
  printf '# Task\n## Captain'"'"'s intent\nKeep working.\n\n## Firstmate spec\nPreserve the task across relaunches.\n' > "$HOME_DIR/data/$ID/brief.md"
  printf '%s\n' "$(fm_test_task_tmp_root "$ID")" >> "$TMP_ROOT/task-tmps"
  fm_write_meta "$STATE/$ID.meta" \
    "window=fmses:fm-$ID" "endpoint_task_id=$ID" "worktree=$WT" "project=$CASE/proj" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off" "branch=fm/$ID" \
    "tasktmp=$(fm_test_task_tmp_root "$ID")" "model=opus" "effort=high" "account=$CASE/a"
  printf 'gen-1\n' > "$STATE/$ID.busy-gen"
  printf 'working [at=1]: implementing\n' > "$STATE/$ID.status"
  printf 'claude' > "$CASE/fake/command"
  printf 'fm-%s\n' "$ID" > "$CASE/fake/windows"
  printf '%s' "$WT" > "$CASE/fake/cwd"
  : > "$CASE/fake/literal"
  : > "$CASE/probes"
}

rotate() {  # <args...>
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH \
    -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u CLAUDE_CONFIG_DIR \
    PATH="$CASE/fakebin:$PATH" FM_HOME="$HOME_DIR" FM_FAKE_DIR="$CASE/fake" HOME="$CASE/user-home" \
    FM_SPAWN_NO_GUARD=1 FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
    "$ROTATE" "$@"
}

observe_pane() {  # [hash]
  rotate observe "$ID" --pane-hash "${1:-h1}" --pane-line "You've hit your session limit · resets 3pm (UTC)"
}

# start_daemon_stand_in <claude-root> -> DAEMON_PID, DAEMON_ENV_VISIBLE
# A long-running process whose environment names <claude-root>, standing in
# for the no-mistakes daemon. macOS hides the environment of Apple platform
# binaries from ps, so a node process is preferred where one is installed.
start_daemon_stand_in() {
  local env_text
  DAEMON_ENV_VISIBLE=0
  if command -v node >/dev/null 2>&1; then
    env CLAUDE_CONFIG_DIR="$1" HOME="$CASE/user-home" node -e 'setTimeout(() => {}, 30000)' &
  else
    env CLAUDE_CONFIG_DIR="$1" HOME="$CASE/user-home" /bin/sleep 30 &
  fi
  DAEMON_PID=$!
  sleep 0.5
  if [ -r "/proc/$DAEMON_PID/environ" ]; then
    env_text=$(tr '\0' '\n' < "/proc/$DAEMON_PID/environ")
  else
    env_text=$(ps eww -o command= -p "$DAEMON_PID" | tr ' ' '\n')
  fi
  printf '%s\n' "$env_text" | grep -qx "CLAUDE_CONFIG_DIR=$1" && DAEMON_ENV_VISIBLE=1
  return 0
}

meta_field() {  # <key>
  grep "^$1=" "$STATE/$ID.meta" | tail -1 | cut -d= -f2-
}

probe_count() {
  grep -c . "$CASE/probes" || true
}

assert_not_relaunched() {  # <msg>
  assert_equals "$CASE/a" "$(meta_field account)" "$1: the task record must keep its account"
  assert_no_grep "Firstmate operational input waiting" "$CASE/fake/literal" "$1: no replacement may launch"
  assert_no_grep "## Progress note" "$HOME_DIR/data/$ID/brief.md" "$1: the instructions must stay untouched"
}

test_no_pool_passes_untouched() {
  local out
  new_case no-pool
  printf '%s\n' "$CASE/a" > "$HOME_DIR/config/claude-account"
  out=$(observe_pane)
  assert_equals pass "${out%%$'\t'*}" "a single pin is no rotation pool"
  rm "$HOME_DIR/config/claude-account"
  out=$(observe_pane)
  assert_equals pass "${out%%$'\t'*}" "an absent pin is no rotation pool"
  assert_equals 0 "$(probe_count)" "no pool must never probe an account"
  assert_not_relaunched "without a pool"
  pass "observe leaves a home without a rotation pool exactly as it was"
}

test_confirmed_limit_relaunches_on_the_next_account() {
  local out note
  new_case rotate
  printf 'rejected 1900000000\n' > "$CASE/a/probe"
  out=$(observe_pane)
  assert_equals wake "${out%%$'\t'*}" "a confirmed limit with a usable next account must surface once: $out"
  assert_contains "$out" "check: claude account rotated: $ID relaunched on $CASE/b (b@example.com) after a@example.com hit its usage limit" \
    "the wake should name the task, the new account, and the limited one"
  assert_equals "$CASE/b" "$(meta_field account)" "the relaunched task record should carry the new account"
  assert_equals opus "$(meta_field model)" "the relaunch should keep the task's model"
  assert_equals high "$(meta_field effort)" "the relaunch should keep the task's effort"
  assert_equals "$WT" "$(meta_field worktree)" "the relaunch should keep the task's worktree"
  assert_grep "Firstmate operational input waiting" "$CASE/fake/literal" "a replacement worker should launch"
  note=$(cat "$HOME_DIR/data/$ID/brief.md")
  assert_contains "$note" "## Progress note" "the replacement's instructions should carry a progress note"
  assert_contains "$note" "usage limit of a@example.com" "the note should name the limited account"
  assert_contains "$note" "relaunched it on $CASE/b (b@example.com)" "the note should name the new account"
  assert_equals "$CASE/b" "$(head -n 1 "$STATE/claude-account-rotation/selected")" \
    "the rotation should make the new account the selection new spawns use"
  assert_grep "a@example.com	1900000000	" "$STATE/claude-account-rotation/limited" \
    "the limited account should be recorded with its reset"
  assert_equals "$CASE/a opus
$CASE/b opus" "$(cat "$CASE/probes")" "the probes should confirm the old account and clear the new one with the task's model"
  pass "a confirmed usage limit relaunches the worker on the next usable account and records it"
}

test_unlimited_account_dismisses_the_evidence() {
  local out
  new_case dismiss
  out=$(observe_pane h1)
  assert_equals pass "${out%%$'\t'*}" "an account the service still allows is no usage limit: $out"
  assert_not_relaunched "a dismissed limit"
  assert_equals 1 "$(probe_count)" "the dismissal should cost one probe"
  out=$(observe_pane h1)
  assert_equals pass "${out%%$'\t'*}" "the same dismissed evidence must pass again"
  assert_equals 1 "$(probe_count)" "the same dismissed evidence must not be probed again"
  printf 'rejected 1900000000\n' > "$CASE/a/probe"
  out=$(observe_pane h2)
  assert_equals wake "${out%%$'\t'*}" "new evidence that the service confirms must rotate: $out"
  pass "a limit line the service does not confirm is dismissed once and never relaunches"
}

test_every_account_limited_declares_one_timed_wait() {
  local out status until_iso
  new_case all-limited
  printf 'rejected 1900000600\n' > "$CASE/a/probe"
  printf 'rejected 1900000000\n' > "$CASE/b/probe"
  out=$(observe_pane)
  assert_equals wake "${out%%$'\t'*}" "an all-limited pool must surface once: $out"
  assert_contains "$out" "check: claude usage limit: $ID stopped on a@example.com and every pool account is limited" \
    "the wake should say every account is limited"
  until_iso=$(date -u -r 1900000060 +%Y-%m-%dT%H:%MZ 2>/dev/null || date -u -d @1900000060 +%Y-%m-%dT%H:%MZ)
  assert_contains "$out" "retries at $until_iso" "the wait should end at the earliest known reset"
  assert_not_relaunched "an all-limited pool"
  status=$(tail -n 1 "$STATE/$ID.status")
  assert_contains "$status" "paused [key=claude-usage-limit] [at=" "the wait should be declared as a keyed pause"
  assert_contains "$status" "until $until_iso" "the declared pause should carry its UTC clearing time"
  out=$(observe_pane)
  assert_equals absorb "${out%%$'\t'*}" "a standing wait must not alarm again: $out"
  assert_equals 2 "$(probe_count)" "a standing wait must not probe again"
  assert_equals 1 "$(grep -c 'paused \[key=claude-usage-limit\]' "$STATE/$ID.status")" "the wait must be declared once"
  pass "an all-limited pool keeps the worker in place and declares one wait until the earliest reset"
}

test_expired_wait_resumes_and_resolves_the_pause() {
  local out
  new_case resume
  printf 'rejected 1900000600\n' > "$CASE/a/probe"
  printf 'rejected 1900000000\n' > "$CASE/b/probe"
  out=$(observe_pane)
  assert_equals wake "${out%%$'\t'*}" "the first sight should surface the wait: $out"
  # The reset has passed: both accounts answer allowed and the recorded resets
  # are in the past.
  printf 'allowed\n' > "$CASE/a/probe"
  printf 'allowed\n' > "$CASE/b/probe"
  printf 'a@example.com\t1000\t900\nb@example.com\t1000\t900\n' > "$STATE/claude-account-rotation/limited"
  sed -i.bak 's/^until=.*/until=1000/' "$STATE/claude-account-rotation/episode-$ID" && rm -f "$STATE/claude-account-rotation/episode-$ID.bak"
  out=$(rotate observe "$ID")
  assert_equals wake "${out%%$'\t'*}" "an expired wait with a usable account must resume the worker: $out"
  assert_contains "$out" "check: claude account rotated: $ID relaunched on $CASE/a (a@example.com)" \
    "the worker should resume on the first usable account from the selection"
  assert_equals "$CASE/a" "$(meta_field account)" "the resumed task record should carry its account"
  assert_contains "$(tail -n 1 "$STATE/$ID.status")" "resolved [key=claude-usage-limit] [at=" \
    "resuming should resolve the declared pause"
  assert_absent "$STATE/claude-account-rotation/episode-$ID" "a resumed episode should be closed"
  pass "an expired wait retries, resumes the worker when an account frees, and resolves its pause"
}

test_same_email_directories_are_one_account() {
  local out
  new_case same-email
  claude_root "$CASE/a2" a@example.com signed-in allowed
  printf '%s\n%s\n%s\n' "$CASE/a" "$CASE/a2" "$CASE/b" > "$HOME_DIR/config/claude-account"
  printf 'rejected 1900000000\n' > "$CASE/a/probe"
  out=$(observe_pane)
  assert_equals wake "${out%%$'\t'*}" "rotation should proceed past the shared account: $out"
  assert_equals "$CASE/b" "$(meta_field account)" "a second directory of the limited email must be skipped"
  assert_no_grep "$CASE/a2 " "$CASE/probes" "a directory sharing the limited email must not be probed"
  pass "directories signed in to one email share its limit and are skipped together"
}

test_signed_out_and_unprobeable_accounts_are_skipped() {
  local out
  new_case skip
  printf '%s\n%s\n%s\n' "$CASE/a" "$CASE/b" "$CASE/c" > "$HOME_DIR/config/claude-account"
  rm "$CASE/b/.credentials.json"
  printf 'rejected 1900000000\n' > "$CASE/a/probe"
  out=$(observe_pane)
  assert_equals "$CASE/c" "$(meta_field account)" "a signed-out account must be skipped: $out"
  assert_no_grep "$CASE/b " "$CASE/probes" "a signed-out account must not be probed"

  new_case skip-error
  printf '%s\n%s\n%s\n' "$CASE/a" "$CASE/b" "$CASE/c" > "$HOME_DIR/config/claude-account"
  printf 'rejected 1900000000\n' > "$CASE/a/probe"
  printf 'error\n' > "$CASE/b/probe"
  out=$(observe_pane)
  assert_equals "$CASE/c" "$(meta_field account)" "an account whose probe fails must be skipped: $out"
  pass "signed-out accounts and failed probes are skipped for the next usable account"
}

test_unlisted_account_stops_the_rotation() {
  local out
  new_case unlisted
  claude_root "$CASE/b" intruder@example.org
  printf 'rejected 1900000000\n' > "$CASE/a/probe"
  out=$(observe_pane)
  assert_equals wake "${out%%$'\t'*}" "an unlisted pool account must surface as a blocker: $out"
  assert_contains "$out" "check: claude account rotation stopped: pool entry $CASE/b is signed in as intruder@example.org, which config/claude-account-allowlist does not list" \
    "the blocker should name the entry and its account"
  assert_not_relaunched "an unlisted pool account"
  assert_equals 0 "$(probe_count)" "a blocked rotation must not probe any account"
  out=$(observe_pane)
  assert_equals absorb "${out%%$'\t'*}" "a standing block must not alarm again: $out"
  claude_root "$CASE/b" b@example.com
  sed -i.bak 's/^until=.*/until=1000/' "$STATE/claude-account-rotation/episode-$ID" && rm -f "$STATE/claude-account-rotation/episode-$ID.bak"
  out=$(observe_pane)
  assert_equals wake "${out%%$'\t'*}" "a fixed pool should rotate on the retry: $out"
  assert_equals "$CASE/b" "$(meta_field account)" "the retry should relaunch on the fixed account"
  assert_absent "$STATE/claude-account-rotation/blocked" "a fixed pool should clear the standing block"

  new_case no-allowlist
  rm "$HOME_DIR/config/claude-account-allowlist"
  out=$(observe_pane)
  assert_contains "$out" "config/claude-account-allowlist is missing" "a pool without an allowlist must stop the rotation"
  assert_not_relaunched "a pool without an allowlist"
  pass "an account outside the allowlist, or a missing allowlist, stops the rotation once until the pool is fixed"
}

test_unconfirmed_probe_surfaces_without_acting() {
  local out
  new_case unconfirmed
  printf 'error\n' > "$CASE/a/probe"
  out=$(observe_pane)
  assert_equals wake "${out%%$'\t'*}" "a limit the probe cannot confirm should surface: $out"
  assert_contains "$out" "check: claude usage limit unconfirmed for $ID" "the wake should say the limit is unconfirmed"
  assert_not_relaunched "an unconfirmed limit"
  out=$(observe_pane h2)
  assert_equals pass "${out%%$'\t'*}" "an unconfirmed episode must not alarm again: $out"
  pass "a limit the live probe cannot confirm surfaces once and relaunches nothing"
}

test_stop_failure_record_is_structural_evidence() {
  local out
  new_case stop-failure
  printf 'rejected 1900000000\n' > "$CASE/a/probe"
  printf '{"hook_event_name":"StopFailure","error":"rate_limit","last_assistant_message":"You%sve hit your session limit\\n· resets 3pm"}\n' "'" |
    "$ROTATE" record-stop-failure "$STATE" "$ID" --gen gen-0
  [ "$(cut -f2,3 "$STATE/$ID.api-error")" = "gen-0	rate_limit" ] || fail "the hook should record its generation and error: $(cat "$STATE/$ID.api-error")"
  out=$(rotate observe "$ID")
  assert_equals pass "${out%%$'\t'*}" "a record from an earlier agent incarnation is no evidence: $out"
  assert_absent "$STATE/$ID.api-error" "an observed record should be consumed"
  printf '{"error":"overloaded"}\n' | "$ROTATE" record-stop-failure "$STATE" "$ID" --gen gen-1
  out=$(rotate observe "$ID")
  assert_equals pass "${out%%$'\t'*}" "an API error other than rate_limit is no usage-limit evidence: $out"
  printf '{"error":"rate_limit","last_assistant_message":"API Error"}\n' | "$ROTATE" record-stop-failure "$STATE" "$ID" --gen gen-1
  out=$(rotate observe "$ID")
  assert_equals wake "${out%%$'\t'*}" "a rate_limit record of the current agent should rotate without any pane line: $out"
  assert_equals "$CASE/b" "$(meta_field account)" "the StopFailure-evidenced rotation should relaunch on the next account"
  printf 'not json' | "$ROTATE" record-stop-failure "$STATE" ../escape --gen x
  expect_code 0 $? "the hook must never fail Claude's lifecycle"
  pass "a StopFailure rate_limit record of the current agent is evidence on its own, and a stale or unrelated one is not"
}

test_default_model_probes_with_the_root_settings_model() {
  local out
  new_case default-model
  sed -i.bak 's/^model=opus$/model=default/' "$STATE/$ID.meta" && rm -f "$STATE/$ID.meta.bak"
  printf '{"model":"sonnet[1m]"}\n' > "$CASE/a/settings.json"
  printf 'rejected 1900000000\n' > "$CASE/a/probe"
  out=$(observe_pane)
  assert_equals wake "${out%%$'\t'*}" "a default-model task should still rotate: $out"
  assert_equals "$CASE/a sonnet[1m]
$CASE/b none" "$(cat "$CASE/probes")" \
    "a default-model probe should use the model each root's settings name, and no model when none is named"
  pass "a task on the default model is probed with the model each account's settings choose"
}

test_status_and_select() {
  local out
  new_case status
  out=$(rotate status)
  assert_contains "$out" "pool: 2 entries; selected $CASE/a" "status should show the pool and the selection"
  assert_contains "$out" "* $CASE/a  a@example.com allowed" "status should mark the selected entry"
  assert_contains "$out" "  $CASE/b  b@example.com allowed" "status should list every entry with its email"
  out=$(rotate select "$CASE/b")
  assert_contains "$out" "selected $CASE/b" "select should record a pool entry"
  assert_equals "$CASE/b" "$(head -n 1 "$STATE/claude-account-rotation/selected")" "select should write the selection"
  out=$(rotate select "$CASE/c" 2>&1)
  expect_code 1 $? "select must refuse an entry outside the pool"
  assert_contains "$out" "is not an entry of config/claude-account" "the refusal should say why"
  pass "status reports the pool and select records only a pool entry"
}

test_validation_scan_reports_a_daemon_limit_once() {
  local out nm sleeper
  new_case validation
  if ! command -v sqlite3 >/dev/null 2>&1; then
    echo "skip-case: sqlite3 is not installed, so the no-mistakes state database cannot be built"
    return 0
  fi
  nm="$CASE/nm"
  mkdir -p "$nm/logs/RUN1" "$nm/logs/RUN2"
  sqlite3 "$nm/state.sqlite" "
    create table runs (id text primary key, branch text, status text, error text, updated_at integer);
    create table step_results (id text primary key, run_id text, step_name text, step_order integer, status text, log_path text);
    insert into runs values ('RUN1', 'fm/$ID', 'failed', 'step test failed: agent run tests: claude exited: exit status 1: ', $(date +%s));
    insert into step_results values ('s1', 'RUN1', 'test', 3, 'failed', '');
    insert into runs values ('RUN2', 'fm/$ID', 'failed', 'step lint failed: lint exited 2', $(date +%s));
    insert into step_results values ('s2', 'RUN2', 'lint', 2, 'failed', '');
    insert into runs values ('RUN3', 'fm/other-home-task', 'failed', 'agent: claude exited', $(date +%s));"
  printf 'claude started pid=1\n\nYou%sve hit your session limit · resets 7:40pm (America/Montevideo)\nclaude exited pid=1 error=claude exited: exit status 1:\n' "'" > "$nm/logs/RUN1/test.log"
  printf 'lint failed\n' > "$nm/logs/RUN2/lint.log"
  printf 'rejected 1900000000\n' > "$CASE/a/probe"
  start_daemon_stand_in "$CASE/a"
  sleeper=$DAEMON_PID
  printf '%s\n' "$sleeper" > "$nm/daemon.pid"
  out=$(NM_HOME="$nm" rotate validation-scan)
  kill "$sleeper" 2>/dev/null
  wait "$sleeper" 2>/dev/null
  assert_equals 1 "$(printf '%s\n' "$out" | grep -c '^wake')" "exactly one run hit the usage limit: $out"
  assert_contains "$out" "check: no-mistakes validation RUN1 for $ID failed when its Claude agent hit the usage limit in the test step (You've hit your session limit · resets 7:40pm (America/Montevideo))" \
    "the report should name the run, the task, the step, and the limit line"
  if [ "$DAEMON_ENV_VISIBLE" = 1 ]; then
    assert_contains "$out" "the shared no-mistakes daemon runs Claude on $CASE/a (a@example.com), limited until" \
      "the report should name the daemon's account and its reset"
  else
    echo "skip-case: no stand-in process on this host exposes its environment, so only the unreadable-account wording is checked"
    assert_contains "$out" "the shared no-mistakes daemon's Claude account could not be read from its process" \
      "an unreadable daemon environment should be reported as unknown, never guessed"
  fi
  assert_contains "$out" "next usable pool account: $CASE/b (b@example.com)" "the report should name the next usable account"
  assert_not_contains "$out" RUN3 "a run on another home's branch must not be reported"
  out=$(NM_HOME="$nm" rotate validation-scan)
  assert_equals "" "$out" "a reported run must not be reported again"
  assert_not_relaunched "a validation scan"

  claude_root "$CASE/outside" outside@example.org
  sqlite3 "$nm/state.sqlite" "
    insert into runs values ('RUN4', 'fm/$ID', 'failed', 'agent review: claude exited: exit status 1: ', $(date +%s));
    insert into step_results values ('s4', 'RUN4', 'review', 2, 'failed', '');"
  mkdir -p "$nm/logs/RUN4"
  printf 'You%sve hit your session limit · resets 9pm (UTC)\n' "'" > "$nm/logs/RUN4/review.log"
  start_daemon_stand_in "$CASE/outside"
  sleeper=$DAEMON_PID
  printf '%s\n' "$sleeper" > "$nm/daemon.pid"
  out=$(NM_HOME="$nm" rotate validation-scan)
  kill "$sleeper" 2>/dev/null
  wait "$sleeper" 2>/dev/null
  if [ "$DAEMON_ENV_VISIBLE" = 1 ]; then
    assert_contains "$out" "(outside@example.org), an account config/claude-account-allowlist does not list, so it was not probed" \
      "a daemon account outside the allowlist should be named and never probed"
  fi
  assert_no_grep "$CASE/outside " "$CASE/probes" "a daemon account outside the allowlist must never be probed"
  pass "a no-mistakes run that died at its daemon agent's usage limit is reported once with the daemon's account and the next usable one"
}

test_limit_line_matcher() {
  local line
  for line in "  ⎿  You've hit your session limit · resets 1:40am (America/Montevideo)" \
    "│ You’ve hit your weekly limit · resets Oct 12 │" \
    "Claude AI usage limit reached|1752339600" \
    "● 5-hour limit reached ∙ resets 3pm" \
    "Running tests now.You've hit your session limit · resets 1pm (America/Montevideo)"; do
    fm_worker_account_claude_limit_line "$line" >/dev/null || fail "should match a usage-limit line: $line"
  done
  [ "$(fm_worker_account_claude_limit_line "● 5-hour limit reached ∙ resets 3pm")" = "5-hour limit reached ∙ resets 3pm" ] ||
    fail "the matched line should be trimmed of bullets and borders"
  for line in "Approaching usage limit · resets at 3pm" "> fix the rate limit bug" "limit: 35"; do
    if fm_worker_account_claude_limit_line "$line" >/dev/null; then
      fail "should not match: $line"
    fi
  done
  if fm_worker_account_claude_limit_line "You've hit your session limit
$(seq 1 20)"; then
    fail "a limit line scrolled above the last 15 non-blank lines is history, not the current state"
  fi
  pass "the usage-limit matcher reads several phrasings near the bottom and ignores warnings and history"
}

test_no_pool_passes_untouched
test_confirmed_limit_relaunches_on_the_next_account
test_unlimited_account_dismisses_the_evidence
test_every_account_limited_declares_one_timed_wait
test_expired_wait_resumes_and_resolves_the_pause
test_same_email_directories_are_one_account
test_signed_out_and_unprobeable_accounts_are_skipped
test_unlisted_account_stops_the_rotation
test_unconfirmed_probe_surfaces_without_acting
test_stop_failure_record_is_structural_evidence
test_default_model_probes_with_the_root_settings_model
test_status_and_select
test_validation_scan_reports_a_daemon_limit_once
test_limit_line_matcher

if [ -f "$TMP_ROOT/task-tmps" ]; then
  while IFS= read -r d; do
    [ -n "$d" ] && rm -rf "$d"
  done < "$TMP_ROOT/task-tmps"
fi
echo "# all fm-claude-account-rotation tests passed"
