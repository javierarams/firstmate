#!/usr/bin/env bash
# fm-claude-account-rotate.sh - automatic Claude worker account rotation over
# the worker account pin's rotation pool.
#
# Usage: fm-claude-account-rotate.sh status
#        fm-claude-account-rotate.sh select <entry>
#        fm-claude-account-rotate.sh probe <entry> [--model <model>]
#        fm-claude-account-rotate.sh observe <task-id> [--pane-hash <hash>] [--pane-line <text>]
#        fm-claude-account-rotate.sh validation-scan
#        fm-claude-account-rotate.sh record-stop-failure <state-dir> <task-id> --gen <gen>
#
# docs/configuration.md "Worker account pin" owns the operator contract: the
# pool is a config/claude-account listing two or more entries, the allowlist is
# config/claude-account-allowlist, and bin/fm-worker-account-lib.sh owns their
# parsing, the selected-entry lookup every launch performs, and the sign-in
# check. With no pool every subcommand except status and record-stop-failure
# does nothing. Requires an explicit FM_HOME, like bin/fm-control.sh.
#
# status         Print the pool in order with each entry's account email and
#                allowlist verdict, the selected entry, the accounts known to
#                be limited and until when, a standing block, and every task
#                waiting on a limit.
# select         Record <entry> as the selection new launches use, after the
#                allowlist and sign-in checks pass.
# probe          Ask the live service whether <entry>'s account can run a turn
#                now, and print `allowed <reset>`, `rejected <reset>`, or
#                `error <detail>` (reset is an epoch, or 0 when unknown). The
#                probe is one minimal `claude -p` turn (no tools, a one-line
#                system prompt, no settings, MCP, skills, or session file) on
#                the given model, else the model the root's settings.json
#                names, in the sign-in check's cleared environment, read from its
#                stream-json output: the rate_limit_event's
#                rate_limit_info.status ("rejected" with resetsAt) is the
#                structural verdict; an is_error result whose text is a usage
#                limit also reads rejected; a clean result reads allowed. A
#                rejected turn spends no tokens, an allowed one about a
#                thousand.
# observe        The watcher's entry point when a Claude ship or scout shows a
#                usage limit (bin/fm-watch.sh owns the evidence read). The
#                evidence is either the task's StopFailure record (below) with
#                error rate_limit for the current agent incarnation, or the
#                stable pane hash plus the limit line the watcher matched with
#                fm_worker_account_claude_limit_line. Prints exactly one line:
#                  wake<TAB><check reason>  the watcher queues and surfaces it
#                  absorb<TAB><why>         handled; skip ordinary stale triage
#                  pass<TAB><why>           not ours; ordinary triage continues
#                One episode is one agent incarnation (state/<id>.busy-gen, else
#                the record's busy_gen or spawn_gen): it surfaces exactly once
#                when it rotates, waits, fails, or is blocked, and stays silent
#                while it waits. The episode:
#                1. Validates the whole pool: every entry must be a readable
#                   directory whose account email is readable and allowlisted.
#                   Any violation stops rotation for the whole home (one wake
#                   per distinct reason) and launches nothing; the next
#                   episode or retry after the pool is fixed clears it.
#                2. Confirms the limit by probing the task's own recorded
#                   account (account= in its record) with the task's model. An
#                   allowed answer is no limit: the evidence is dismissed and
#                   ordinary triage continues, except when this episode was
#                   already waiting on a reset, which is then over. A failed
#                   probe surfaces once as unconfirmed and acts on nothing.
#                   A recorded account whose email the allowlist does not list
#                   surfaces once naming it and acts on nothing. Without a
#                   recorded, readable account only a StopFailure record
#                   confirms the limit; pane evidence alone surfaces once as
#                   unconfirmed and acts on nothing.
#                3. Records every rejected account email with its reset in
#                   state/claude-account-rotation/limited. Directories signed
#                   in to one email are one account: one limited email skips
#                   all of them.
#                4. Walks the pool cyclically from the current selection,
#                   skipping limited emails, and takes the first entry that
#                   passes the sign-in check and a probe with the task's model.
#                   It records that entry as the selection, so new spawns use
#                   it, and relaunches the task on it through
#                   `fm-control.sh <id> relaunch --note-file`, which keeps the
#                   worktree, brief, model, and effort and records the account
#                   in the task record.
#                5. When no entry is usable, keeps the worker where it is and
#                   declares the wait in its status log - one self-announced
#                   `paused [key=claude-usage-limit]: ... until <UTC>` line,
#                   renewed only when the time changes - until the earliest
#                   known reset (FM_CLAUDE_ROTATE_UNKNOWN_RESET_SECS after the
#                   observation when an account reported none), then retries.
#                   The wait records the task's busy record (seq and state,
#                   bin/fm-busy-lib.sh); the retry needs a fresh pane limit
#                   line or that record still idle at the same seq, and a
#                   worker that took a turn meanwhile ends the wait with
#                   nothing relaunched. Either end appends the matching
#                   `resolved` line.
#                A failed relaunch or an unconfirmed limit surfaces once and
#                then passes the window back to ordinary stale triage for the
#                rest of that incarnation; a block is retried every
#                FM_CLAUDE_ROTATE_RETRY_SECS.
# validation-scan
#                Reports, once per run, a failed no-mistakes run on one of this
#                home's ship or scout branches whose error names a claude agent
#                exit and whose failing step's log ends with a usage-limit line.
#                Each report is one `wake` line naming the run, the shared
#                daemon's Claude account (read from the daemon process's own
#                CLAUDE_CONFIG_DIR) and its reset, and the next usable pool
#                account. The daemon's account is probed only when the
#                allowlist lists it. It never stops, restarts, or reconfigures
#                the daemon.
#                Only runs updated within FM_CLAUDE_ROTATE_VALIDATION_WINDOW_SECS
#                are considered.
# record-stop-failure
#                Claude's StopFailure hook, wired by bin/fm-spawn.sh: reads the
#                hook payload on stdin and replaces state/<id>.api-error with
#                one line "<epoch><TAB><gen><TAB><error><TAB><message>". It
#                always exits 0 so it can never disturb Claude's lifecycle.
#
# Runtime records live in state/claude-account-rotation/: selected, limited,
# blocked, episode-<id>, validation-<run>, log, a probe working directory, and
# the lock serializing every subcommand that probes or writes them.
#
# Environment knobs:
#   FM_CLAUDE_ROTATE_PROBE_SECONDS         bound on one probe (60)
#   FM_CLAUDE_ROTATE_UNKNOWN_RESET_SECS    assumed limit when no reset is known (1800)
#   FM_CLAUDE_ROTATE_RETRY_SECS            retry cadence for a blocked episode (600)
#   FM_CLAUDE_ROTATE_VALIDATION_WINDOW_SECS  failed-run lookback (86400)
#   FM_CLAUDE_ROTATE_LOCK_SECONDS          wait for the rotation lock (30)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

die() {
  echo "error: $1" >&2
  exit 1
}

if [ "${1:-}" = record-stop-failure ]; then
  state=${2:-} id=${3:-} gen=
  [ "${4:-}" != --gen ] || gen=${5:-}
  case "$id" in '' | .* | *[!A-Za-z0-9._-]*) exit 0 ;; esac
  [ -d "$state" ] || exit 0
  case "$gen" in *[!A-Za-z0-9._-]*) gen= ;; esac
  line=$(jq -r '[(.error // "unknown" | tostring), (.last_assistant_message // .error_details // "" | tostring)]
    | map(gsub("[\\t\\r\\n]+"; " ")) | join("\t")' 2>/dev/null | head -c 600) || line=
  [ -n "$line" ] || line=$'unknown\t'
  tmp="$state/.$id.api-error.$$"
  printf '%s\t%s\t%s\n' "$(date +%s)" "${gen:-none}" "$line" > "$tmp" 2>/dev/null &&
    mv -f "$tmp" "$state/$id.api-error" 2>/dev/null
  rm -f "$tmp" 2>/dev/null
  exit 0
fi

case "${1:-}" in
-h | --help | '')
  usage
  exit 0
  ;;
esac

if [ -z "${FM_HOME:-}" ]; then
  die "FM_HOME is not set; fm-claude-account-rotate refuses to act without an explicit firstmate home"
fi
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
[ -d "$STATE" ] || die "state dir '$STATE' is missing for FM_HOME '$FM_HOME'"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-worker-account-lib.sh
. "$SCRIPT_DIR/fm-worker-account-lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"

PROBE_SECONDS=${FM_CLAUDE_ROTATE_PROBE_SECONDS:-60}
UNKNOWN_RESET_SECS=${FM_CLAUDE_ROTATE_UNKNOWN_RESET_SECS:-1800}
RETRY_SECS=${FM_CLAUDE_ROTATE_RETRY_SECS:-600}
VALIDATION_WINDOW_SECS=${FM_CLAUDE_ROTATE_VALIDATION_WINDOW_SECS:-86400}
LOCK_SECONDS=${FM_CLAUDE_ROTATE_LOCK_SECONDS:-30}
WAIT_KEY=claude-usage-limit
R=$(fm_worker_account_rotation_dir "$STATE")
NOW=$(date +%s)

iso_of() {  # <epoch>
  date -u -r "$1" +%Y-%m-%dT%H:%MZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%MZ
}

one_line() {  # <text> -> first line, tabs folded, bounded
  printf '%s' "$1" | head -n 1 | tr '\t' ' ' | cut -c1-240
}

log_event() {  # <text>
  printf '%s\t%s\n' "$(iso_of "$NOW")" "$1" >> "$R/log" 2>/dev/null || true
}

write_file() {  # <path> <content>
  printf '%s' "$2" > "$1.tmp.$$" && mv -f "$1.tmp.$$" "$1"
}

LOCKED=0
lock_rotation() {
  mkdir -p "$R" || die "cannot create $R"
  fm_lock_acquire_wait_max "$R/lock" "$LOCK_SECONDS" || return 1
  LOCKED=1
  trap 'unlock_rotation' EXIT
}

unlock_rotation() {
  [ "$LOCKED" = 1 ] || return 0
  fm_lock_release "$R/lock" || true
  LOCKED=0
}

# --- pool ---------------------------------------------------------------------

POOL=()
POOL_ENTRIES=
load_pool() {  # returns 1 with no pool; dies on a malformed pin
  local entries entry
  entries=$(fm_worker_account_entries claude "$CONFIG") || exit 1
  POOL=()
  [ -n "$entries" ] || return 1
  while IFS= read -r entry; do
    POOL+=("$entry")
  done <<EOF
$entries
EOF
  [ "${#POOL[@]}" -ge 2 ] || return 1
  POOL_ENTRIES=$entries
}

# validate_pool: BLOCK_REASON names the first violation; returns 1 on one.
BLOCK_REASON=
ALLOWED=
declare -a POOL_EMAILS=()
validate_pool() {
  local allow rc i entry root email
  BLOCK_REASON=
  ALLOWED=
  POOL_EMAILS=()
  allow=$(fm_worker_account_allowlist "$CONFIG" 2>&1)
  rc=$?
  if [ "$rc" -eq 3 ]; then
    BLOCK_REASON="config/claude-account lists a rotation pool but config/claude-account-allowlist is missing"
    return 1
  elif [ "$rc" -ne 0 ]; then
    BLOCK_REASON=$(one_line "${allow#error: }")
    return 1
  fi
  ALLOWED=$allow
  for i in "${!POOL[@]}"; do
    entry=${POOL[i]}
    root=$(fm_worker_account_claude_root "$entry")
    if [ -n "$root" ] && { [ ! -d "$root" ] || [ ! -r "$root" ] || [ ! -x "$root" ]; }; then
      BLOCK_REASON="pool entry $entry is not a readable directory"
      return 1
    fi
    if ! email=$(fm_worker_account_claude_email "$root"); then
      BLOCK_REASON="pool entry $entry has no readable account email (oauthAccount.emailAddress in its .claude.json)"
      return 1
    fi
    if ! printf '%s\n' "$allow" | grep -Fxq -- "$email"; then
      BLOCK_REASON="pool entry $entry is signed in as $email, which config/claude-account-allowlist does not list"
      return 1
    fi
    POOL_EMAILS[i]=$email
  done
  return 0
}

pool_index_of() {  # <entry> -> index, or 1
  local i
  for i in "${!POOL[@]}"; do
    [ "${POOL[i]}" != "$1" ] || { printf '%s\n' "$i"; return 0; }
  done
  return 1
}

selected_entry() {
  fm_worker_account_claude_selected "$POOL_ENTRIES" "$STATE"
}

# --- limited-account ledger -------------------------------------------------

limited_until() {  # <email> -> epoch the email stays limited until; 1 when free
  local email reset observed until
  [ -f "$R/limited" ] || return 1
  while IFS=$'\t' read -r email reset observed; do
    [ "$email" = "$1" ] || continue
    case "$reset" in '' | *[!0-9]*) reset=0 ;; esac
    case "$observed" in '' | *[!0-9]*) observed=0 ;; esac
    if [ "$reset" -gt 0 ]; then
      until=$reset
    else
      until=$((observed + UNKNOWN_RESET_SECS))
    fi
    [ "$until" -gt "$NOW" ] || return 1
    printf '%s\n' "$until"
    return 0
  done < "$R/limited"
  return 1
}

limited_without() {  # <email> -> the ledger's other rows, each newline-terminated
  [ -f "$R/limited" ] || return 0
  awk -F '\t' -v e="$1" 'NF && $1 != e' "$R/limited"
}

mark_limited() {  # <email> <reset-epoch-or-0>
  write_file "$R/limited" "$(limited_without "$1")
$1	$2	$NOW
"
  sed -i.bak '/^$/d' "$R/limited" && rm -f "$R/limited.bak"
}

clear_limited() {  # <email>
  [ -f "$R/limited" ] || return 0
  write_file "$R/limited" "$(limited_without "$1")
"
  sed -i.bak '/^$/d' "$R/limited" && rm -f "$R/limited.bak"
}

# --- live probe ---------------------------------------------------------------

PROBE_VERDICT=
PROBE_RESET=0
PROBE_DETAIL=
probe_account() {  # <root> <model>
  local root=$1 model=$2 out name parsed
  local -a clean=(env -i "HOME=${HOME:-}" "PATH=${PATH:-}") args
  for name in TMPDIR USER LOGNAME; do
    [ -z "${!name:-}" ] || clean+=("$name=${!name}")
  done
  [ -z "$root" ] || clean+=("CLAUDE_CONFIG_DIR=$root")
  case "$model" in
  '' | default) model=$(jq -r '.model // empty | strings' "${root:-${HOME:-}/.claude}/settings.json" 2>/dev/null) || model= ;;
  esac
  args=(-p --output-format stream-json --verbose --tools "" --system-prompt "Reply with the single word OK."
    --setting-sources "" --strict-mcp-config --no-session-persistence --disable-slash-commands)
  [ -z "$model" ] || args+=(--model "$model")
  mkdir -p "$R/probe"
  out=$(cd "$R/probe" && fm_run_timed "$PROBE_SECONDS" "${clean[@]}" claude "${args[@]}" OK 2>/dev/null </dev/null)
  parsed=$(printf '%s\n' "$out" | jq -rs '
    (map(objects | select(.type == "rate_limit_event") | .rate_limit_info) | last) as $rl
    | (map(objects | select(.type == "result")) | last) as $res
    | ($rl.resetsAt // 0 | if type == "number" then floor else 0 end) as $reset
    | if ($rl.status // "") == "rejected" then "rejected\t\($reset)\t"
      elif $res == null then "error\t0\tno result from the probe"
      elif ($res.is_error // false) | not then "allowed\t\($reset)\t"
      else "failed\t\($reset)\t\($res.result // $res.subtype // "error" | tostring | gsub("[\\t\\r\\n]+"; " "))"
      end' 2>/dev/null) || parsed=
  PROBE_VERDICT=${parsed%%$'\t'*}
  parsed=${parsed#*$'\t'}
  PROBE_RESET=${parsed%%$'\t'*}
  PROBE_DETAIL=${parsed#*$'\t'}
  case "$PROBE_RESET" in '' | *[!0-9]*) PROBE_RESET=0 ;; esac
  case "$PROBE_VERDICT" in
  allowed | rejected | error) ;;
  failed)
    if fm_worker_account_claude_limit_line "$PROBE_DETAIL" >/dev/null; then
      PROBE_VERDICT=rejected
    else
      PROBE_VERDICT=error
    fi
    ;;
  *)
    PROBE_VERDICT=error
    PROBE_RESET=0
    PROBE_DETAIL="the probe printed no readable stream-json"
    ;;
  esac
  PROBE_DETAIL=$(one_line "$PROBE_DETAIL")
}

# choose_account <model> <skip-email> -> CHOSEN_* or 1, with NOTES explaining
CHOSEN_ENTRY=
CHOSEN_EMAIL=
NOTES=
choose_account() {
  local model=$1 skip=$2 start i n idx entry root email limited_emails=$'\n'
  CHOSEN_ENTRY='' CHOSEN_EMAIL='' NOTES=''
  start=$(pool_index_of "$(selected_entry)") || start=0
  n=${#POOL[@]}
  for ((i = 0; i < n; i++)); do
    idx=$(((start + i) % n))
    entry=${POOL[idx]}
    email=${POOL_EMAILS[idx]}
    root=$(fm_worker_account_claude_root "$entry")
    [ "$email" != "$skip" ] || continue
    case "$limited_emails" in *$'\n'"$email"$'\n'*) continue ;; esac
    if limited_until "$email" >/dev/null; then
      limited_emails="$limited_emails$email"$'\n'
      continue
    fi
    if ! fm_worker_account_check claude "$entry" "$root" claude 2>/dev/null; then
      NOTES="${NOTES:+$NOTES; }$entry is not signed in"
      continue
    fi
    probe_account "$root" "$model"
    case "$PROBE_VERDICT" in
    allowed)
      CHOSEN_ENTRY=$entry CHOSEN_EMAIL=$email
      return 0
      ;;
    rejected)
      mark_limited "$email" "$PROBE_RESET"
      limited_emails="$limited_emails$email"$'\n'
      ;;
    *) NOTES="${NOTES:+$NOTES; }$entry probe failed: $PROBE_DETAIL" ;;
    esac
  done
  return 1
}

earliest_reset() {  # -> epoch any pool account frees, or now + unknown span
  local i until best=
  for i in "${!POOL_EMAILS[@]}"; do
    until=$(limited_until "${POOL_EMAILS[i]}") || continue
    if [ -z "$best" ] || [ "$until" -lt "$best" ]; then best=$until; fi
  done
  printf '%s\n' "${best:-$((NOW + UNKNOWN_RESET_SECS))}"
}

describe_entry() {  # <entry> <email>
  if [ "$1" = ordinary ]; then
    printf 'the default login (%s)' "$2"
  else
    printf '%s (%s)' "$1" "$2"
  fi
}

# --- standing block -----------------------------------------------------------

# block_surface <reason> -> 0 when the reason is new and must wake
block_surface() {
  local prior
  prior=$(cat "$R/blocked" 2>/dev/null || true)
  [ "$prior" != "$1" ] || return 1
  write_file "$R/blocked" "$1"
  log_event "blocked: $1"
  return 0
}

block_clear() {
  [ -e "$R/blocked" ] || return 0
  rm -f "$R/blocked"
  log_event "block cleared"
}

# --- episodes -----------------------------------------------------------------

EP_GEN='' EP_OUTCOME='' EP_EVIDENCE='' EP_UNTIL='' EP_DECLARED='' EP_BUSY=''
episode_read() {  # <task>
  local line
  EP_GEN='' EP_OUTCOME='' EP_EVIDENCE='' EP_UNTIL='' EP_DECLARED='' EP_BUSY=''
  [ -f "$R/episode-$1" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
    gen=*) EP_GEN=${line#gen=} ;;
    outcome=*) EP_OUTCOME=${line#outcome=} ;;
    evidence=*) EP_EVIDENCE=${line#evidence=} ;;
    until=*) EP_UNTIL=${line#until=} ;;
    declared=*) EP_DECLARED=${line#declared=} ;;
    busy=*) EP_BUSY=${line#busy=} ;;
    esac
  done < "$R/episode-$1"
  case "$EP_UNTIL" in '' | *[!0-9]*) EP_UNTIL=0 ;; esac
  return 0
}

episode_write() {  # <task> <gen> <outcome> <evidence> <until> [declared] [busy]
  write_file "$R/episode-$1" "gen=$2
outcome=$3
evidence=$4
until=$5
declared=${6:-}
busy=${7:-}
"
}

busy_mark() {  # <task> -> "<seq> <state>" of the task's busy record, or empty
  local rec state seq
  rec=$(fm_busy_record_read "$STATE" "$1") || return 0
  read -r state _ _ seq <<< "$rec"
  printf '%s %s\n' "$seq" "$state"
}

task_gen() {  # <task> <meta>
  local gen
  gen=$(head -n 1 "$STATE/$1.busy-gen" 2>/dev/null) || gen=
  [ -n "$gen" ] || gen=$(fm_meta_get "$2" busy_gen)
  [ -n "$gen" ] || gen=$(fm_meta_get "$2" spawn_gen)
  printf '%s\n' "${gen:-none}"
}

status_append() {  # <task> <line>
  local rc=0
  fm_wake_status_append_self_announced "$STATE" "$STATE/$1.status" "$2" || rc=$?
  [ "$rc" -ne 2 ] || echo "warning: could not append to $STATE/$1.status" >&2
}

emit() {  # <verdict> <text>
  printf '%s\t%s\n' "$1" "$(printf '%s' "$2" | tr '\t\n\r' '   ')"
}

relaunch_task() {  # <task> <note> -> CONTROL_OUT
  local note_file="$R/note-$1"
  printf '%s\n' "$2" > "$note_file" || return 1
  CONTROL_OUT=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-control.sh" "$1" relaunch --note-file "$note_file" 2>&1)
  local rc=$?
  rm -f "$note_file"
  return "$rc"
}

observe() {
  local task=$1 pane_hash=$2 pane_line=$3 meta gen evidence detail own own_root own_email model
  local rec rec_gen rec_error rec_msg until was_waiting=0 confirmed note from
  fm_task_id_path_safe "$task" || die "invalid task id '$task'"
  meta="$STATE/$task.meta"
  [ -f "$meta" ] || { emit pass "no task record"; return 0; }
  case "$(fm_meta_get "$meta" kind)" in ship | scout) ;; *) emit pass "not a ship or scout"; return 0 ;; esac
  [ "$(fm_meta_get "$meta" harness)" = claude ] || { emit pass "not a Claude worker"; return 0; }
  load_pool || { emit pass "no rotation pool"; return 0; }
  lock_rotation || { emit absorb "another rotation holds the lock"; return 0; }
  gen=$(task_gen "$task" "$meta")

  evidence='' detail=''
  rec="$STATE/$task.api-error"
  if [ -f "$rec" ]; then
    IFS=$'\t' read -r _ rec_gen rec_error rec_msg < "$rec" || true
    rm -f "$rec"
    if [ "$rec_gen" = "$gen" ] && [ "$rec_error" = rate_limit ]; then
      evidence="stop-failure:$gen"
      detail=$rec_msg
    fi
  fi
  if [ -z "$evidence" ] && [ -n "$pane_hash" ] && [ -n "$pane_line" ]; then
    evidence="pane:$pane_hash"
    detail=$pane_line
  fi

  if episode_read "$task" && [ "$EP_GEN" = "$gen" ]; then
    case "$EP_OUTCOME" in
    waiting)
      if [ "$NOW" -lt "$EP_UNTIL" ]; then
        emit absorb "waiting for a Claude usage reset until $(iso_of "$EP_UNTIL")"
        return 0
      fi
      was_waiting=1
      ;;
    failed | unconfirmed)
      emit pass "this usage-limit episode already surfaced as $EP_OUTCOME"
      return 0
      ;;
    blocked)
      if [ "$NOW" -lt "$EP_UNTIL" ]; then
        emit absorb "account rotation is blocked: $(cat "$R/blocked" 2>/dev/null || true)"
        return 0
      fi
      ;;
    dismissed)
      if [ -z "$evidence" ] || [ "$evidence" = "$EP_EVIDENCE" ]; then
        emit pass "this limit evidence was already dismissed"
        return 0
      fi
      ;;
    esac
  else
    EP_DECLARED=
  fi
  if [ -z "$evidence" ] && [ "$was_waiting" = 1 ]; then
    case "$EP_BUSY" in
    *' idle')
      [ "$(busy_mark "$task")" != "$EP_BUSY" ] || evidence=$EP_EVIDENCE
      ;;
    esac
    if [ -z "$evidence" ]; then
      episode_write "$task" "$gen" dismissed "$EP_EVIDENCE" 0
      [ -z "$EP_DECLARED" ] || status_append "$task" "resolved [key=$WAIT_KEY]: the worker took a turn while it waited on the Claude usage limit; nothing was relaunched"
      log_event "$task: wait ended; the worker's busy record moved past $EP_BUSY; nothing relaunched"
      emit pass "the worker took a turn while it waited on the usage limit"
      return 0
    fi
  fi
  if [ -z "$evidence" ]; then
    emit pass "no usage-limit evidence for the current agent"
    return 0
  fi

  if ! validate_pool; then
    episode_write "$task" "$gen" blocked "$evidence" "$((NOW + RETRY_SECS))" "$EP_DECLARED"
    if block_surface "$BLOCK_REASON"; then
      emit wake "check: claude account rotation stopped: $BLOCK_REASON; $task stays stopped on its current account and nothing launches on the pool until config/claude-account and config/claude-account-allowlist agree"
    else
      emit absorb "account rotation is blocked: $BLOCK_REASON"
    fi
    return 0
  fi
  block_clear

  model=$(fm_meta_get "$meta" model)
  own=$(fm_meta_get "$meta" account)
  own_email=
  if [ -n "$own" ]; then
    own_root=$(fm_worker_account_claude_root "$own")
    own_email=$(fm_worker_account_claude_email "$own_root") || own_email=
  fi
  if [ -n "$own_email" ] && ! printf '%s\n' "$ALLOWED" | grep -Fxq -- "$own_email"; then
    episode_write "$task" "$gen" unconfirmed "$evidence" 0 "$EP_DECLARED"
    log_event "$task: runs on $own_email, which is not on the allowlist; nothing relaunched"
    emit wake "check: claude account rotation stopped: $task runs on $own_email ($own), which is not in config/claude-account-allowlist; stop its work; nothing was relaunched"
    return 0
  fi
  confirmed=$was_waiting
  case "$evidence" in stop-failure:*) confirmed=1 ;; esac
  if [ -n "$own_email" ]; then
    probe_account "$own_root" "$model"
    case "$PROBE_VERDICT" in
    rejected)
      mark_limited "$own_email" "$PROBE_RESET"
      confirmed=1
      ;;
    allowed)
      clear_limited "$own_email"
      if [ "$was_waiting" = 0 ]; then
        episode_write "$task" "$gen" dismissed "$evidence" 0
        log_event "$task: dismissed $evidence; $own_email answers allowed"
        emit pass "the recorded account $own_email is not limited"
        return 0
      fi
      ;;
    *)
      if [ "$was_waiting" = 0 ]; then
        episode_write "$task" "$gen" unconfirmed "$evidence" 0
        log_event "$task: unconfirmed $evidence: $PROBE_DETAIL"
        emit wake "check: claude usage limit unconfirmed for $task: the pane shows '$(one_line "$detail")' but the account probe of $own_email failed ($PROBE_DETAIL); nothing was relaunched"
        return 0
      fi
      ;;
    esac
  fi
  if [ "$confirmed" = 0 ]; then
    episode_write "$task" "$gen" unconfirmed "$evidence" 0
    log_event "$task: unconfirmed $evidence: no readable account to probe"
    emit wake "check: claude usage limit unconfirmed for $task: the pane shows '$(one_line "$detail")' but its account is not recorded or readable, so no probe could confirm the limit; nothing was relaunched"
    return 0
  fi

  from=${own_email:-an unrecorded account}
  if choose_account "$model" ""; then
    write_file "$(fm_worker_account_rotation_dir "$STATE")/selected" "$CHOSEN_ENTRY
"
    note="This worker stopped at the Claude usage limit of $from (it showed: $(one_line "${detail:-usage limit}")). Firstmate's automatic account rotation relaunched it on $(describe_entry "$CHOSEN_ENTRY" "$CHOSEN_EMAIL"). Inspect git status and git log in the local copy, then continue the task from where it stopped."
    if relaunch_task "$task" "$note"; then
      rm -f "$R/episode-$task" "$STATE/$task.api-error"
      [ -z "$EP_DECLARED" ] || status_append "$task" "resolved [key=$WAIT_KEY]: Claude usage limit cleared; relaunched on $CHOSEN_EMAIL"
      log_event "$task: rotated from $from to $CHOSEN_ENTRY ($CHOSEN_EMAIL)"
      emit wake "check: claude account rotated: $task relaunched on $(describe_entry "$CHOSEN_ENTRY" "$CHOSEN_EMAIL") after $from hit its usage limit"
    else
      episode_write "$task" "$gen" failed "$evidence" 0 "$EP_DECLARED"
      log_event "$task: relaunch on $CHOSEN_ENTRY failed: $(one_line "$CONTROL_OUT")"
      emit wake "check: claude account rotation failed for $task: relaunch on $(describe_entry "$CHOSEN_ENTRY" "$CHOSEN_EMAIL") did not complete: $(one_line "$(printf '%s\n' "$CONTROL_OUT" | grep -m 1 '^error:' || printf '%s' "$CONTROL_OUT")")"
    fi
    return 0
  fi

  until=$(($(earliest_reset) + 60))
  if [ "$EP_DECLARED" != "$until" ]; then
    status_append "$task" "paused [key=$WAIT_KEY]: every Claude pool account is at its usage limit; waiting on $from until $(iso_of "$until")"
  fi
  episode_write "$task" "$gen" waiting "$evidence" "$until" "$until" "$(busy_mark "$task")"
  log_event "$task: waiting until $(iso_of "$until")${NOTES:+ ($NOTES)}"
  if [ "$was_waiting" = 1 ]; then
    emit absorb "still waiting for a Claude usage reset until $(iso_of "$until")"
  else
    emit wake "check: claude usage limit: $task stopped on $from and every pool account is limited${NOTES:+ ($NOTES)}; it stays put and retries at $(iso_of "$until")"
  fi
}

# --- no-mistakes daemon -------------------------------------------------------

nm_home() {
  local root=${NM_HOME:-$HOME/.no-mistakes}
  printf '%s\n' "$root"
}

# daemon_account -> DAEMON_ROOT (empty for the default login), DAEMON_KNOWN
DAEMON_ROOT=
DAEMON_KNOWN=0
daemon_account() {
  local pid env_text
  DAEMON_ROOT='' DAEMON_KNOWN=0
  pid=$(head -n 1 "$(nm_home)/daemon.pid" 2>/dev/null) || return 0
  case "$pid" in '' | *[!0-9]*) return 0 ;; esac
  if [ -r "/proc/$pid/environ" ]; then
    env_text=$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null) || env_text=
  else
    env_text=$(ps eww -o command= -p "$pid" 2>/dev/null | tr ' ' '\n') || env_text=
  fi
  printf '%s\n' "$env_text" | grep -q '^HOME=' || return 0
  DAEMON_KNOWN=1
  DAEMON_ROOT=$(printf '%s\n' "$env_text" | sed -n 's/^CLAUDE_CONFIG_DIR=//p' | head -n 1)
}

sql_quote() {
  printf "'%s'" "${1//\'/\'\'}"
}

validation_scan() {
  local db logs meta task branch in_list='' since run run_branch run_error step log text line
  local daemon_desc daemon_email next_desc reason pairs=$'\n'
  load_pool || return 0
  db="$(nm_home)/state.sqlite"
  logs="$(nm_home)/logs"
  [ -r "$db" ] || return 0
  command -v sqlite3 >/dev/null 2>&1 || return 0
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    case "$(fm_meta_get "$meta" kind)" in ship | scout) ;; *) continue ;; esac
    branch=$(fm_meta_get "$meta" branch)
    [ -n "$branch" ] || continue
    task=${meta##*/}
    task=${task%.meta}
    pairs="$pairs$branch"$'\t'"$task"$'\n'
    in_list="${in_list:+$in_list,}$(sql_quote "$branch")"
  done
  [ -n "$in_list" ] || return 0
  lock_rotation || return 0
  since=$((NOW - VALIDATION_WINDOW_SECS))
  while IFS=$'\t' read -r run run_branch run_error; do
    [ -n "$run" ] || continue
    case "$run" in *[!A-Za-z0-9]*) continue ;; esac
    [ ! -e "$R/validation-$run" ] || continue
    case "$run_error" in *claude*) ;; *) write_file "$R/validation-$run" "other" && continue ;; esac
    step=$(sqlite3 "file:$db?mode=ro" "select step_name from step_results where run_id = $(sql_quote "$run") and status = 'failed' order by step_order desc limit 1" 2>/dev/null </dev/null) || step=
    case "$step" in '' | *[!A-Za-z0-9_-]*) write_file "$R/validation-$run" "other"; continue ;; esac
    log="$logs/$run/$step.log"
    text=$(tail -n 80 "$log" 2>/dev/null) || text=
    if ! line=$(fm_worker_account_claude_limit_line "$text"); then
      write_file "$R/validation-$run" "other"
      continue
    fi
    task=$(printf '%s' "$pairs" | awk -F '\t' -v b="$run_branch" '$1 == b { print $2; exit }')
    validate_pool || {
      write_file "$R/validation-$run" "limit"
      emit wake "check: no-mistakes validation $run for $task failed at the Claude usage limit in its $step step ($line); no next pool account is named because rotation is blocked: $BLOCK_REASON"
      continue
    }
    daemon_account
    daemon_email=
    if [ "$DAEMON_KNOWN" = 1 ]; then
      daemon_email=$(fm_worker_account_claude_email "$DAEMON_ROOT") || daemon_email=
      PROBE_VERDICT=unprobed
      if [ -n "$daemon_email" ] && printf '%s\n' "$ALLOWED" | grep -Fxq -- "$daemon_email"; then
        probe_account "$DAEMON_ROOT" ""
      fi
      [ "$PROBE_VERDICT" != rejected ] || [ -z "$daemon_email" ] || mark_limited "$daemon_email" "$PROBE_RESET"
      daemon_desc="the shared no-mistakes daemon runs Claude on ${DAEMON_ROOT:-the default login} (${daemon_email:-unknown email})"
      if [ "$PROBE_VERDICT" = rejected ]; then
        if [ "$PROBE_RESET" -gt 0 ]; then
          daemon_desc="$daemon_desc, limited until $(iso_of "$PROBE_RESET")"
        else
          daemon_desc="$daemon_desc, still limited"
        fi
      elif [ "$PROBE_VERDICT" = allowed ]; then
        daemon_desc="$daemon_desc, usable again now"
      elif [ "$PROBE_VERDICT" = unprobed ]; then
        daemon_desc="$daemon_desc, an account config/claude-account-allowlist does not list, so it was not probed"
      fi
    else
      daemon_desc="the shared no-mistakes daemon's Claude account could not be read from its process"
    fi
    if choose_account "" "$daemon_email"; then
      next_desc="next usable pool account: $(describe_entry "$CHOSEN_ENTRY" "$CHOSEN_EMAIL")"
    else
      next_desc="no pool account is usable before $(iso_of "$(earliest_reset)")"
    fi
    write_file "$R/validation-$run" "limit"
    log_event "validation $run ($task): usage limit; $daemon_desc; $next_desc"
    reason="check: no-mistakes validation $run for ${task:-$run_branch} failed when its Claude agent hit the usage limit in the $step step ($line); $daemon_desc; $next_desc; the daemon is shared, so switching its account is firstmate's call"
    emit wake "$reason"
  done < <(sqlite3 -separator $'\t' "file:$db?mode=ro" \
    "select id, branch, replace(replace(coalesce(error, ''), char(9), ' '), char(10), ' ') from runs where status = 'failed' and updated_at >= $since and branch in ($in_list) order by updated_at" 2>/dev/null)
}

# --- status, select, probe ----------------------------------------------------

show_status() {
  local entries i entry root email allow mark until rc f task
  entries=$(fm_worker_account_entries claude "$CONFIG") || exit 1
  if [ -z "$entries" ]; then
    echo "pool: none (config/claude-account is absent)"
    return 0
  fi
  load_pool || {
    echo "pool: none (config/claude-account pins one account: $entries)"
    return 0
  }
  allow=$(fm_worker_account_allowlist "$CONFIG" 2>&1)
  rc=$?
  echo "pool: ${#POOL[@]} entries; selected $(selected_entry)"
  [ "$rc" -eq 0 ] || echo "allowlist: ${allow:-config/claude-account-allowlist is missing}"
  for i in "${!POOL[@]}"; do
    entry=${POOL[i]}
    root=$(fm_worker_account_claude_root "$entry")
    mark=' '
    [ "$entry" != "$(selected_entry)" ] || mark='*'
    if email=$(fm_worker_account_claude_email "$root"); then
      if [ "$rc" -eq 0 ] && printf '%s\n' "$allow" | grep -Fxq -- "$email"; then
        if until=$(limited_until "$email"); then
          email="$email allowed, limited until $(iso_of "$until")"
        else
          email="$email allowed"
        fi
      else
        email="$email NOT ALLOWED"
      fi
    else
      email="no readable account email"
    fi
    printf '%s %s  %s\n' "$mark" "$entry" "$email"
  done
  [ ! -s "$R/blocked" ] || echo "blocked: $(cat "$R/blocked")"
  for f in "$R"/episode-*; do
    [ -f "$f" ] || continue
    task=${f##*/episode-}
    episode_read "$task" || continue
    case "$EP_OUTCOME" in
    waiting) echo "waiting: $task until $(iso_of "$EP_UNTIL")" ;;
    failed | unconfirmed | blocked) echo "$EP_OUTCOME: $task" ;;
    esac
  done
}

select_entry() {
  local entry=$1 root
  load_pool || die "config/claude-account lists no rotation pool"
  pool_index_of "$entry" >/dev/null || die "'$entry' is not an entry of config/claude-account"
  root=$(fm_worker_account_claude_root "$entry")
  fm_worker_account_claude_allowed "$CONFIG" "$entry" "$root" "${#POOL[@]}" || exit 1
  fm_worker_account_check claude "$entry" "$root" claude || exit 1
  lock_rotation || die "another rotation holds $R/lock"
  write_file "$R/selected" "$entry
"
  log_event "selected $entry by hand"
  echo "selected $entry"
}

probe_entry() {
  local entry=$1 model=$2 root
  root=$(fm_worker_account_claude_root "$entry")
  [ -z "$root" ] || [ -d "$root" ] || die "'$entry' is not a directory"
  mkdir -p "$R"
  probe_account "$root" "$model"
  case "$PROBE_VERDICT" in
  error) printf 'error %s\n' "$PROBE_DETAIL" ;;
  *) printf '%s %s\n' "$PROBE_VERDICT" "$PROBE_RESET" ;;
  esac
}

cmd=$1
shift
case "$cmd" in
status) show_status ;;
select)
  [ $# -eq 1 ] || die "usage: fm-claude-account-rotate.sh select <entry>"
  select_entry "$1"
  ;;
probe)
  [ $# -ge 1 ] || die "usage: fm-claude-account-rotate.sh probe <entry> [--model <model>]"
  entry=$1 model=
  [ "${2:-}" != --model ] || model=${3:-}
  probe_entry "$entry" "$model"
  ;;
observe)
  [ $# -ge 1 ] || die "usage: fm-claude-account-rotate.sh observe <task-id> [--pane-hash <hash>] [--pane-line <text>]"
  task=$1 pane_hash='' pane_line=''
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
    --pane-hash) pane_hash=${2:-} ;;
    --pane-line) pane_line=${2:-} ;;
    *) die "unknown observe option '$1'" ;;
    esac
    shift 2 || break
  done
  observe "$task" "$pane_hash" "$pane_line"
  ;;
validation-scan) validation_scan ;;
*) die "unknown subcommand '$cmd' (see --help)" ;;
esac
