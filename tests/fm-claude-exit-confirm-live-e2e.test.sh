#!/usr/bin/env bash
# Opt-in live guard for the control plane's answer to Claude's exit
# confirmation (bin/fm-control-lib.sh's fm_control_exit_confirm_signal and
# fm_control_exit_confirm_choice) against the real installed claude CLI.
#
# A Claude agent with background work alive does not exit on /exit: it renders
# a "Background work is running" dialog and waits. Whether that dialog renders,
# what it says, and where its selection starts are vendor output, so the
# hermetic model in tests/fm-control.test.sh can only restate the assumption
# written into it. This guard launches the real claude in a pane of a private
# Herdr lab session (never the default one), has it start a background shell,
# and then:
#   1. types /exit itself and requires the real dialog to carry a recognition
#      signal and the selected `Exit and stop tasks` row the control plane
#      presses Enter on, then runs `fm-control.sh <id> exit` against that open
#      dialog;
#   2. launches a second agent the same way and runs `fm-control.sh <id> exit`
#      from its idle composer.
# Each run must report the agent stopped and leave its background shell gone.
# Each agent's one turn submits a prompt and spends tokens, so the guard is
# opt-in: set FM_CLAUDE_EXIT_CONFIRM_LIVE=1 (FM_LIVE=1 also forces it).
# FM_CLAUDE_EXIT_CONFIRM_LIVE_MODEL names the model (default haiku). The
# scratch worktree's trust is pre-registered through bin/fm-claude-trust.sh,
# exactly as a real spawn does, in the operator's current Claude config. Run it
# after every Claude upgrade and before trusting the "Claude exit confirmation"
# entry in docs/verification/runtime-backends.md.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_CLAUDE_EXIT_CONFIRM_LIVE claude herdr jq git

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

VERSION=$(claude --version 2>/dev/null | head -1)
MODEL=${FM_CLAUDE_EXIT_CONFIRM_LIVE_MODEL:-haiku}
SESSION="fm-lab-exit-confirm-$$"
export HERDR_SESSION="$SESSION"
MARK="fm-exit-confirm-$$"
SCRATCH=
cleanup_all() {
  pkill -f -- "$MARK" >/dev/null 2>&1 || true
  herdr_safe_stop_and_delete "$SESSION"
  [ -z "$SCRATCH" ] || rm -rf "$SCRATCH"
}
trap cleanup_all EXIT
vfail() {  # <message>
  fail "claude $VERSION: $1"
}
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare isolated Herdr lab session"

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-exit-confirm.XXXXXX")
SCRATCH=$(cd "$SCRATCH" && pwd)
HOME_DIR="$SCRATCH/home"
PROJ="$SCRATCH/proj"
WT="$SCRATCH/wt"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/xconfirm" "$PROJ"
printf '# brief\n' > "$HOME_DIR/data/xconfirm/brief.md"
git -C "$PROJ" init -q
printf '# proj\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
git -C "$PROJ" worktree add --quiet -b xconfirm "$WT"
"$ROOT/bin/fm-claude-trust.sh" "$WT" "$PROJ" >/dev/null || fail "could not pre-register Claude trust for the scratch worktree"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"
CONTAINER_RAW=$(fm_backend_herdr_container_ensure "$WT") || fail "container_ensure failed"
CONTAINER=${CONTAINER_RAW%%$'\t'*}
TASK_IDS=$(fm_backend_herdr_create_task "$CONTAINER" fm-xconfirm "$WT" "${CONTAINER_RAW#*$'\t'}") \
  || fail "create_task failed"
read -r TAB_ID PANE_ID <<EOF
$TASK_IDS
EOF
[ -n "$TAB_ID" ] && [ -n "$PANE_ID" ] || fail "create_task did not return tab/pane ids"
T="$SESSION:$PANE_ID"
{
  echo "window=$T"
  echo "endpoint_task_id=xconfirm"
  echo "worktree=$WT"
  echo "project=$PROJ"
  echo "harness=claude"
  echo "kind=ship"
  echo "mode=no-mistakes"
  echo "yolo=off"
  echo "model=$MODEL"
  echo "effort=default"
  echo "backend=herdr"
  echo "herdr_session=$SESSION"
  echo "herdr_workspace_id=${CONTAINER#*:}"
  echo "herdr_tab_id=$TAB_ID"
  echo "herdr_pane_id=$PANE_ID"
} > "$HOME_DIR/state/xconfirm.meta"

screen() {
  fm_backend_visible_capture herdr "$T" 2>/dev/null || true
}

wait_for() {  # <seconds> <command...>: poll until the command succeeds
  local deadline=$(($(date +%s) + $1))
  shift
  until "$@"; do
    [ "$(date +%s)" -lt "$deadline" ] || return 1
    sleep 0.5
  done
}

# The agent's own argv carries the prompt and so the marker too; only a
# process that is not the agent is its background shell.
shell_alive() {  # <mark>
  ps -axo comm=,args= | grep -F -- "$1" | awk '$1 !~ /(claude|node|grep)$/' | grep -q .
}
shell_gone() { ! shell_alive "$1"; }
turn_done() { [ "$(fm_backend_busy_state herdr "$T")" = idle ] && screen | grep -q 'shell'; }
# The rows the control plane reads the confirmation from.
confirm_rows() { screen | grep -v '^[[:space:]]*$' | tail -n "$(fm_control_exit_confirm_rows claude)"; }
dialog_shown() { confirm_rows | grep -Eq "$(fm_control_exit_confirm_signal claude)"; }

printf -v WT_Q '%q' "$WT"
# launch_with_shell <mark>: start a real claude in the pane and wait until its
# one turn has left a background shell running and settled idle.
launch_with_shell() {  # <mark>
  local prompt_q
  printf -v prompt_q '%q' "Use the Bash tool with run_in_background set to true to run exactly: while :; do sleep 3; done; : $1   Then reply with only the word OK."
  fm_backend_herdr_send_text_line "$T" "cd -- $WT_Q && env CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --model $MODEL --dangerously-skip-permissions --setting-sources '' $prompt_q" \
    || fail "could not launch claude in the lab pane"
  wait_for 120 shell_alive "$1" || vfail "the agent never started its background shell; screen: $(screen | tail -n 15)"
  wait_for 60 turn_done || vfail "the agent's turn never settled idle with its shell listed; screen: $(screen | tail -n 15)"
}

# control_exit <mark> <what>: fm-control exit must report the agent stopped and
# its background shell must be gone.
control_exit() {  # <mark> <what>
  local out
  out=$(env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" FM_CONTROL_EXIT_WAIT=30 \
    "$ROOT/bin/fm-control.sh" xconfirm exit 2>&1) \
    || vfail "fm-control exit did not stop an agent with $2: $out. Screen: $(screen | tail -n 15)"
  case "$out" in
    "stopped xconfirm"*) ;;
    *) vfail "fm-control exit reported '$out' rather than stopped, for an agent with $2" ;;
  esac
  wait_for 10 shell_gone "$1" || vfail "the agent with $2 stopped but its background shell is still running"
}

# 1. The real dialog carries what the control plane reads, and one an exit
# left open is answered without retyping.
launch_with_shell "$MARK-a"
fm_backend_herdr_send_literal "$T" /exit || fail "could not type /exit"
sleep 1
fm_backend_send_key herdr "$T" Enter || fail "could not submit /exit"
wait_for 15 dialog_shown || vfail "/exit with a background shell rendered no recognized exit confirmation; revisit fm_control_exit_confirm_signal. Screen: $(screen | tail -n 15)"
confirm_rows | grep -Eq "$(fm_control_exit_confirm_choice claude)" \
  || vfail "the exit confirmation's selection is not on 'Exit and stop tasks', so fm-control would refuse it; revisit fm_control_exit_confirm_choice. Screen: $(screen | tail -n 15)"
pass "claude $VERSION: /exit with a background shell renders the confirmation selected on 'Exit and stop tasks'"
control_exit "$MARK-a" "its exit confirmation already open"
pass "claude $VERSION: fm-control exit answers an open confirmation, stopping the agent and its background shell"

# 2. The whole exit path, from an idle composer. The first agent's answered
# dialog can stay in the terminal above this one, which must not be taken for
# a dialog of the second agent's own.
launch_with_shell "$MARK-b"
if screen | grep -Eq "$(fm_control_exit_confirm_signal claude)"; then
  echo "# the first agent's answered confirmation is still on screen above the second agent"
fi
control_exit "$MARK-b" "a background shell"
pass "claude $VERSION: fm-control exit types /exit and answers the confirmation, stopping the agent and its background shell"
echo "# claude exit confirmation live guard checked: claude $VERSION"
