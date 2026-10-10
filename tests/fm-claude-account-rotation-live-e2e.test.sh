#!/usr/bin/env bash
# Opt-in live guard for automatic Claude account rotation
# (bin/fm-claude-account-rotate.sh) against the real installed claude CLI.
#
# Both signals the rotation acts on come from vendor output, so a fake can only
# restate the assumption written into it:
#   - the live probe's verdict comes from the stream-json rate_limit_event of a
#     minimal `claude -p` turn; this guard runs the rotation's own probe against
#     a signed-in account and requires a verdict whose reset was read from that
#     event, so a renamed or missing event fails here instead of silently
#     reading every account as unusable;
#   - the structural limit evidence is Claude's StopFailure hook payload; this
#     guard wires the rotation's own recorder as a StopFailure hook, provokes a
#     token-free API error (an unknown model), and requires the record to carry
#     a documented error type, proving the hook fires and its `error` field is
#     what the recorder reads.
# The probe submits a prompt and spends about a thousand tokens, so the guard
# is opt-in: set FM_CLAUDE_ROTATION_LIVE_E2E=1 and FM_CLAUDE_ROTATION_LIVE_ROOT
# to a signed-in Claude config directory, or `ordinary` for the default login;
# FM_CLAUDE_ROTATION_LIVE_MODEL optionally names the probe's model. Run it after
# every Claude upgrade and before trusting the "Claude account rotation probe
# and StopFailure record" entry in docs/verification/runtime-backends.md.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_CLAUDE_ROTATION_LIVE_E2E claude jq perl

ROTATE="$ROOT/bin/fm-claude-account-rotate.sh"
TMP_ROOT=$(fm_test_tmproot fm-claude-account-rotation-live)
ACCOUNT=${FM_CLAUDE_ROTATION_LIVE_ROOT:-}
VERSION=$(claude --version 2>/dev/null | head -1)
unset ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN

case "$ACCOUNT" in
  ordinary) CONFIG_DIR= ;;
  /*) CONFIG_DIR=$ACCOUNT ;;
  *) fail "set FM_CLAUDE_ROTATION_LIVE_ROOT to a signed-in Claude config directory, or 'ordinary' for the default login" ;;
esac
[ -z "$CONFIG_DIR" ] || [ -d "$CONFIG_DIR" ] || fail "FM_CLAUDE_ROTATION_LIVE_ROOT '$CONFIG_DIR' is not a directory"
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state" "$TMP_ROOT/cwd"

probe_reads_the_rate_limit_event() {
  local out reset
  out=$(FM_HOME="$HOME_DIR" "$ROTATE" probe "$ACCOUNT" ${FM_CLAUDE_ROTATION_LIVE_MODEL:+--model "$FM_CLAUDE_ROTATION_LIVE_MODEL"})
  case "$out" in
    "allowed "* | "rejected "*) ;;
    *) fail "claude $VERSION: the rotation probe read no verdict for $ACCOUNT: $out" ;;
  esac
  reset=${out#* }
  [ "$reset" -gt 0 ] 2>/dev/null ||
    fail "claude $VERSION: the probe answered '$out' with no resetsAt, so no rate_limit_event was read; revisit probe_account in bin/fm-claude-account-rotate.sh"
  pass "claude $VERSION: the rotation probe reads '$out' for $ACCOUNT from the stream's rate_limit_event"
}

stop_failure_records_the_error_type() {
  local settings record error
  local -a run=(env -i "HOME=$HOME" "PATH=$PATH" "TMPDIR=${TMPDIR:-/tmp}" "USER=${USER:-}")
  [ -z "$CONFIG_DIR" ] || run+=("CLAUDE_CONFIG_DIR=$CONFIG_DIR")
  settings=$(jq -cn --arg c "'$ROTATE' record-stop-failure '$HOME_DIR/state' live-task --gen live-gen" \
    '{hooks: {StopFailure: [{hooks: [{type: "command", command: $c}]}]}}')
  (cd "$TMP_ROOT/cwd" && "${run[@]}" claude -p --output-format stream-json --verbose --tools "" \
    --setting-sources "" --strict-mcp-config --no-session-persistence --settings "$settings" \
    --model claude-fm-nonexistent-model OK </dev/null >"$TMP_ROOT/stop-failure.jsonl" 2>&1) || true
  record="$HOME_DIR/state/live-task.api-error"
  [ -s "$record" ] ||
    fail "claude $VERSION: an API error turn wrote no StopFailure record, so the hook no longer fires or no longer runs under -p: $(tail -c 400 "$TMP_ROOT/stop-failure.jsonl")"
  [ "$(cut -f2 "$record")" = live-gen ] || fail "claude $VERSION: the record lost its incarnation: $(cat "$record")"
  error=$(cut -f3 "$record")
  case "$error" in
    rate_limit | overloaded | authentication_failed | oauth_org_not_allowed | account_on_hold | billing_error | \
      invalid_request | model_not_found | server_error | max_output_tokens | cloud_credential_error) ;;
    *) fail "claude $VERSION: the StopFailure payload's error field read '$error', not a documented error type; revisit record-stop-failure" ;;
  esac
  pass "claude $VERSION: a StopFailure turn records error type '$error' for the current incarnation"
}

probe_reads_the_rate_limit_event
stop_failure_records_the_error_type
echo "# claude account rotation live guard checked: claude $VERSION"
