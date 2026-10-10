#!/usr/bin/env bash
# fm-worker-account-lib.sh - the single owner of the opt-in per-home worker
# account pin: which runners can be pinned, how a pin file is parsed and
# resolved, the launch-time sign-in check under it, and the environment
# credentials a pinned Claude launch sheds.
#
# docs/configuration.md "Worker account pin" owns the operator-facing contract.
# Sourced by bin/fm-spawn.sh and bin/fm-control.sh.
#
# Pinnable runners, each a credential store inside a root its vendor lets a
# process select:
#   claude          CLAUDE_CONFIG_DIR     config/claude-account
#   pi, pi-signed   PI_CODING_AGENT_DIR   config/pi-account
#
# The pin is opt-in: an absent file is no pin, and the launch keeps today's
# ambient behavior byte for byte. A present file must resolve, or the launch
# refuses; nothing falls back to an ambient or vendor-default login once a
# home has declared one. `ordinary` selects the vendor default: for Claude
# that is CLAUDE_CONFIG_DIR unset, because Claude reads $CLAUDE_CONFIG_DIR/
# .claude.json and keys its macOS Keychain entry to any CLAUDE_CONFIG_DIR that
# is set, even $HOME/.claude; for Pi it is $HOME/.pi/agent. Any other value is
# one absolute path to an existing readable, searchable directory. Firstmate
# never copies credentials or changes a global login.
#
# config/claude-account may instead list several such entries, one per line
# and none twice: an ordered rotation pool. A launch then selects the entry
# bin/fm-claude-account-rotate.sh last recorded in
# state/claude-account-rotation/selected, or the first entry when that record
# is absent or names an entry the pool no longer holds. A pool requires
# config/claude-account-allowlist, one account email per line. Whenever that
# allowlist exists, every pinned Claude launch reads the selected root's
# account email from its .claude.json (oauthAccount.emailAddress;
# ~/.claude.json for ordinary) and refuses an email the allowlist does not
# list, or one it cannot read, before the sign-in check runs.
#
# A Pi root can hold several provider identities, so config/pi-account names
# the root on line 1 and the providers that home may spend on line 2,
# separated by spaces. A pinned Pi launch must name its provider explicitly as
# --model <provider>/<id>, and that provider must be declared; Firstmate never
# guesses a provider for an unqualified model. The canonical launch also
# passes --provider <that provider>, because without it Pi may resolve a
# provider-prefixed model under another authenticated provider. A raw Pi
# launch command is launched verbatim and cannot receive that flag, so a home
# with config/pi-account refuses raw Pi launches. A raw Claude launch command
# runs after the pinned root and shed credentials are applied, so its own
# leading CLAUDE_CONFIG_DIR or shed-credential assignment would override the
# pin; a home with config/claude-account refuses such a command.
#
# The sign-in check asks the runner itself, with only HOME, PATH, TMPDIR,
# USER, LOGNAME, and the selected root in its environment, so a credential
# variable left in the caller cannot answer for a root that has no login:
#   Claude: `claude auth status`, which exits 0 only when signed in.
#   Pi:     `pi auth check --provider <p> --json --no-refresh`; status "ready"
#           passes. `pi auth check` loads no extensions, so it answers
#           not_ready/provider_not_found for an extension-registered provider,
#           and a Pi without the command (before 0.84.1) prints no JSON. Both
#           fall through to `pi --list-models <p>`, which lists only the models
#           a root can authenticate; a row whose provider column is exactly
#           <p> passes. --no-refresh keeps the check from rewriting a root's
#           tokens while other workers use them.
# A pinned Claude launch also unsets the environment credentials Claude ranks
# above the root's stored login, so an ambient API key or token cannot outrank
# the pin. Pi ranks a root's stored credentials above environment variables,
# and the check refuses a provider the root has not stored, so a pinned Pi
# launch unsets nothing.

# shellcheck source=bin/fm-timeout-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-timeout-lib.sh"

FM_WORKER_ACCOUNT_CHECK_SECONDS=${FM_WORKER_ACCOUNT_CHECK_SECONDS:-30}

# Credentials Claude Code ranks above the /login stored in its config root
# (code.claude.com/docs/en/authentication, "Authentication precedence"; the
# Claude Platform on AWS and Bedrock Mantle switches from
# code.claude.com/docs/en/env-vars).
FM_WORKER_ACCOUNT_CLAUDE_SHED="CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY CLAUDE_CODE_USE_ANTHROPIC_AWS CLAUDE_CODE_USE_MANTLE ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_PROFILE ANTHROPIC_FEDERATION_RULE_ID"

# fm_worker_account_file <harness>
# Prints the pin file name for a pinnable runner; returns 1 for any other.
fm_worker_account_file() {
  case "$1" in
  claude) printf '%s\n' claude-account ;;
  pi | pi-signed) printf '%s\n' pi-account ;;
  *) return 1 ;;
  esac
}

# fm_worker_account_read <harness> <file>
# For Pi prints "declared<TAB>providers", where declared is `ordinary` or the
# absolute path. For Claude prints each declared entry on its own line, in
# file order. The final newline is optional; any other control byte, including
# a CR, is malformed. Parses bytes before the shell can drop NULs or trailing
# newlines; paths are literal, never shell expressions. Returns 0 on success,
# 3 when the file does not exist, 4 when it cannot be inspected (one error
# already printed), 5 when it is not a readable regular file, 6 when it is
# malformed, and 7 when a Claude pool lists one entry twice.
fm_worker_account_read() {
  perl -MErrno=ENOENT -e '
    my ($harness, $f) = @ARGV;
    unless (lstat $f) {
      exit 3 if $! == ENOENT;
      print STDERR "error: cannot inspect configuration source at $f: $!\n";
      exit 4;
    }
    (-f $f && -r _) or exit 5;
    open(my $fh, "<", $f) or exit 5;
    my $body = do { local $/; <$fh> } // "";
    if ($harness eq "claude") {
      my $entry = qr/(?:ordinary|\/[^\x00-\x1f\x7f]*)/;
      $body =~ /\A($entry(?:\n$entry)*)\n?\z/ or exit 6;
      my %seen;
      for my $e (split /\n/, $1) {
        exit 7 if $seen{$e}++;
        print $e, "\n";
      }
    } else {
      $body =~ /\A(ordinary|\/[^\x00-\x1f\x7f]*)\n([A-Za-z0-9][A-Za-z0-9._-]*(?: +[A-Za-z0-9][A-Za-z0-9._-]*)*)\n?\z/ or exit 6;
      print $1, "\t", $2;
    }
  ' -- "$1" "$2"
}

# fm_worker_account_entries <harness> <config-dir>
# Prints the parsed pin: for Claude every declared entry on its own line, for
# Pi "declared<TAB>providers". Prints nothing and returns 0 when the runner is
# not pinnable or the home has no pin. On refusal prints one error naming the
# file and returns 1.
fm_worker_account_entries() {
  local harness=$1 config=$2 file cfg rc
  file=$(fm_worker_account_file "$harness") || return 0
  cfg="$config/$file"
  fm_worker_account_read "$harness" "$cfg"
  rc=$?
  case "$rc" in
  0 | 3) return 0 ;;
  4) return 1 ;;
  5)
    echo "error: config/$file must be a readable regular file: $cfg" >&2
    return 1
    ;;
  7)
    echo "error: config/$file lists the same account entry twice; each pool entry must appear once: $cfg" >&2
    return 1
    ;;
  *)
    if [ "$file" = pi-account ]; then
      echo "error: config/$file must hold 'ordinary' or one absolute path on line 1 and the providers this home may spend on line 2, separated by spaces, with no other lines or control characters: $cfg" >&2
    else
      echo "error: config/$file must hold 'ordinary' or absolute paths, one per line, with no blank lines or control characters: $cfg" >&2
    fi
    return 1
    ;;
  esac
}

# fm_worker_account_rotation_dir <state-dir>
# The runtime record directory bin/fm-claude-account-rotate.sh owns.
fm_worker_account_rotation_dir() {
  printf '%s/claude-account-rotation\n' "$1"
}

# fm_worker_account_claude_selected <entries> <state-dir>
# Prints the pool entry a launch selects: the recorded selection when it names
# one of <entries> (newline-separated), otherwise the first entry.
fm_worker_account_claude_selected() {
  local entries=$1 state=${2:-} recorded=
  if [ -n "$state" ]; then
    recorded=$(head -n 1 "$(fm_worker_account_rotation_dir "$state")/selected" 2>/dev/null) || recorded=
  fi
  if [ -n "$recorded" ] && printf '%s\n' "$entries" | grep -Fxq -- "$recorded"; then
    printf '%s\n' "$recorded"
  else
    printf '%s\n' "$entries" | head -n 1
  fi
}

# fm_worker_account_claude_pool_size <config-dir>
# Prints how many entries config/claude-account lists: 0 with no pin or a
# malformed one, 1 for a single pin, two or more for a rotation pool.
fm_worker_account_claude_pool_size() {
  local entries
  entries=$(fm_worker_account_entries claude "$1" 2>/dev/null) || entries=
  if [ -z "$entries" ]; then
    printf '0\n'
  else
    printf '%s\n' "$entries" | wc -l | tr -d '[:space:]'
    printf '\n'
  fi
}

# fm_worker_account_claude_limit_line <text>
# Prints the usage-limit line Claude rendered among the last 15 non-blank
# lines of <text> (a pane capture or an agent log tail), with surrounding
# borders and bullets trimmed, and returns 0; returns 1 when there is none.
# Any of several independent phrasings counts, so no single vendor string is
# load-bearing: "You've hit your <kind> limit" (any apostrophe), "usage limit
# reached" (including the older "Claude AI usage limit reached|<epoch>"), and
# "<session|weekly|daily|5-hour|Opus|Sonnet> limit reached". A match is only
# a trigger: bin/fm-claude-account-rotate.sh confirms it with a live probe
# before anything is relaunched.
fm_worker_account_claude_limit_line() {
  local line
  line=$(printf '%s\n' "$1" | LC_ALL=C grep -v '^[[:space:]]*$' | tail -n 15 |
    LC_ALL=C grep -Ei "you( ha|[^[:alpha:][:space:]]{0,4})ve (hit|reached) your [[:alnum:] -]*limit|usage limit reached|(session|weekly|daily|5-hour|five-hour|opus|sonnet) limit reached" |
    tail -n 1 | LC_ALL=C sed 's/^[^A-Za-z0-9]*//; s/[^A-Za-z0-9)]*$//') || return 1
  [ -n "$line" ] || return 1
  printf '%s\n' "$line" | cut -c1-200
}

# fm_worker_account_claude_root <declared>
# Prints the CLAUDE_CONFIG_DIR a declared entry selects; empty for ordinary.
fm_worker_account_claude_root() {
  [ "$1" = ordinary ] || printf '%s\n' "$1"
}

# fm_worker_account_claude_email <root>
# Prints the lowercased oauthAccount.emailAddress of the Claude store a root
# selects ($HOME/.claude.json when root is empty). Returns 1, silently, when
# the store or the field cannot be read.
fm_worker_account_claude_email() {
  local store email
  if [ -n "$1" ]; then
    store="$1/.claude.json"
  else
    store="${HOME:-}/.claude.json"
  fi
  email=$(jq -r '.oauthAccount.emailAddress // empty | strings' "$store" 2>/dev/null) || return 1
  case "$email" in
  '' | *[[:space:]]* | *[[:cntrl:]]*) return 1 ;;
  esac
  printf '%s\n' "$email" | tr '[:upper:]' '[:lower:]'
}

# fm_worker_account_allowlist <config-dir>
# Prints config/claude-account-allowlist's emails, lowercased, one per line.
# Returns 3 when the file does not exist; otherwise refuses a file that is not
# a readable regular file, or that holds anything but one address per line,
# with one error naming it, and returns 1.
fm_worker_account_allowlist() {
  local cfg="$1/claude-account-allowlist" rc
  perl -MErrno=ENOENT -e '
    my $f = $ARGV[0];
    unless (lstat $f) {
      exit 3 if $! == ENOENT;
      print STDERR "error: cannot inspect configuration source at $f: $!\n";
      exit 4;
    }
    (-f $f && -r _) or exit 5;
    open(my $fh, "<", $f) or exit 5;
    my $body = do { local $/; <$fh> } // "";
    my $addr = qr/[^\s\@\x00-\x1f\x7f]+\@[^\s\@\x00-\x1f\x7f]+/;
    $body =~ /\A($addr(?:\n$addr)*)\n?\z/ or exit 6;
    print lc($_), "\n" for split /\n/, $1;
  ' -- "$cfg"
  rc=$?
  case "$rc" in
  0 | 3) return "$rc" ;;
  4) return 1 ;;
  5)
    echo "error: config/claude-account-allowlist must be a readable regular file: $cfg" >&2
    return 1
    ;;
  *)
    echo "error: config/claude-account-allowlist must hold one account email per line, with no blank lines, spaces, or control characters: $cfg" >&2
    return 1
    ;;
  esac
}

# fm_worker_account_claude_allowed <config-dir> <declared> <root> [<pool-size>]
# Applies config/claude-account-allowlist to one selected entry. Returns 0
# when no allowlist applies (the file is absent and the pin is a single
# entry) or the entry's account email is listed; otherwise prints one error
# and returns 1. A pool of two or more entries requires the allowlist.
fm_worker_account_claude_allowed() {
  local config=$1 declared=$2 root=$3 pool=${4:-1} allow rc email
  allow=$(fm_worker_account_allowlist "$config")
  rc=$?
  case "$rc" in
  0) ;;
  3)
    [ "$pool" -le 1 ] && return 0
    echo "error: config/claude-account lists a rotation pool of $pool accounts, which requires config/claude-account-allowlist naming the account emails Firstmate may launch: $config/claude-account-allowlist" >&2
    return 1
    ;;
  *) return 1 ;;
  esac
  if ! email=$(fm_worker_account_claude_email "$root"); then
    echo "error: config/claude-account selects $declared, but its account email cannot be read from ${root:-${HOME:-~}}/.claude.json (oauthAccount.emailAddress), so it cannot be checked against config/claude-account-allowlist; sign that root in, or remove it from config/claude-account" >&2
    return 1
  fi
  if ! printf '%s\n' "$allow" | grep -Fxq -- "$email"; then
    echo "error: config/claude-account selects $declared, which is signed in as $email, an account config/claude-account-allowlist does not list; Firstmate never launches it - sign that root in to an allowed account, or remove it from config/claude-account" >&2
    return 1
  fi
  return 0
}

# fm_worker_account_resolve <harness> <config-dir> [<state-dir>]
# Prints "declared<TAB>root<TAB>providers" for a valid pin, where root is the
# directory the launch selects (empty for ordinary Claude, meaning
# CLAUDE_CONFIG_DIR unset). A Claude pool resolves to the selected entry
# (fm_worker_account_claude_selected) and fills providers with the pool size.
# Prints nothing and returns 0 when the runner is not pinnable or the home
# has no pin. On refusal prints one error naming the file and returns 1.
fm_worker_account_resolve() {
  local harness=$1 config=$2 state=${3:-} file cfg entries token declared root fallback
  file=$(fm_worker_account_file "$harness") || return 0
  entries=$(fm_worker_account_entries "$harness" "$config") || return 1
  [ -n "$entries" ] || return 0
  if [ "$harness" = claude ]; then
    declared=$(fm_worker_account_claude_selected "$entries" "$state")
    token="$declared"$'\t'$(printf '%s\n' "$entries" | wc -l | tr -d '[:space:]')
  else
    token=$entries
    declared=${token%%$'\t'*}
  fi
  cfg="$config/$file"
  root=$declared
  # shellcheck disable=SC2088  # The fallbacks are literal text for the refusal.
  case "$harness" in
  claude) fallback='~/.claude with CLAUDE_CONFIG_DIR unset' ;;
  *) fallback='~/.pi/agent' ;;
  esac
  if [ "$declared" = ordinary ]; then
    case "$harness" in
    claude) root= ;;
    *) root="${HOME:?HOME is required to resolve an ordinary Pi account}/.pi/agent" ;;
    esac
  fi
  if [ -n "$root" ] && { [ ! -d "$root" ] || [ ! -r "$root" ] || [ ! -x "$root" ]; }; then
    echo "error: config/$file must name a readable, searchable existing directory (ordinary means $fallback): $cfg -> $root" >&2
    return 1
  fi
  printf '%s\t%s\t%s\n' "$declared" "$root" "${token#*$'\t'}"
}

# fm_worker_account_pi_provider <model>
# Prints the provider an explicit Pi --model <provider>/<id> names. Returns 1,
# silently, for anything else, so no caller can fall back to a guess.
fm_worker_account_pi_provider() {
  local model=$1
  case "$model" in
  */*)
    [ -n "${model%%/*}" ] && [ -n "${model#*/}" ] || return 1
    printf '%s\n' "${model%%/*}"
    ;;
  *) return 1 ;;
  esac
}

# fm_worker_account_check <harness> <declared> <root> <executable> [<provider>]
# Returns 0 only when the runner's own check says the selected root is signed
# in for this launch; otherwise prints one error and returns 1.
fm_worker_account_check() {
  local harness=$1 declared=$2 root=$3 executable=$4 provider=${5:-} out verdict name
  local -a clean=(env -i "HOME=${HOME:-}" "PATH=${PATH:-}")
  for name in TMPDIR USER LOGNAME; do
    [ -z "${!name:-}" ] || clean+=("$name=${!name}")
  done
  case "$harness" in
  claude)
    [ -z "$root" ] || clean+=("CLAUDE_CONFIG_DIR=$root")
    if fm_run_timed "$FM_WORKER_ACCOUNT_CHECK_SECONDS" "${clean[@]}" \
      "$executable" auth status >/dev/null 2>&1 </dev/null; then
      return 0
    fi
    if [ -n "$root" ]; then
      echo "error: config/claude-account pins Claude workers to $root, which is not signed in (claude auth status); sign in with CLAUDE_CONFIG_DIR=$root claude, then /login, or change the pin" >&2
    else
      echo "error: config/claude-account pins Claude workers to the ordinary account, which is not signed in (claude auth status); sign in with env -u CLAUDE_CONFIG_DIR claude, then /login, or change the pin" >&2
    fi
    return 1
    ;;
  pi | pi-signed)
    clean+=("PI_CODING_AGENT_DIR=$root")
    out=$(fm_run_timed "$FM_WORKER_ACCOUNT_CHECK_SECONDS" "${clean[@]}" \
      "$executable" auth check --provider "$provider" --json --no-refresh 2>/dev/null </dev/null)
    verdict=$(printf '%s\n' "$out" | jq -r '
      if type != "object" or (has("status") | not) then "list"
      elif .status == "ready" then "ready"
      elif .status == "not_ready" and .reason == "provider_not_found" then "list"
      else "\(.status) \(.reason // "")"
      end' 2>/dev/null)
    case "${verdict:-list}" in
    ready) return 0 ;;
    list)
      if out=$(fm_run_timed "$FM_WORKER_ACCOUNT_CHECK_SECONDS" "${clean[@]}" \
        "$executable" --list-models "$provider" 2>/dev/null </dev/null) &&
        printf '%s\n' "$out" | awk -v p="$provider" 'NR > 1 && $1 == p { found = 1; exit } END { exit !found }'; then
        return 0
      fi
      verdict="no model listed for provider $provider"
      ;;
    esac
    echo "error: config/pi-account pins Pi workers to $declared, which is not signed in for provider '$provider' ($verdict); sign in with PI_CODING_AGENT_DIR=$root $harness, then /login, or change the pin" >&2
    return 1
    ;;
  esac
  return 0
}

# fm_worker_account_select <harness> <config-dir> <state-dir> <model> <executable> [<raw-command>]
# The whole launch-time decision. Prints nothing for an unpinned runner, so
# the caller keeps today's launch unchanged. For a pinned one prints
# "declared<TAB>root<TAB>provider", where provider is the Pi launch model's
# own (empty for Claude), after the model guard, the Claude allowlist, and the
# sign-in check pass. On refusal prints one error and returns 1.
# bin/fm-spawn.sh runs it before any endpoint exists, and bin/fm-control.sh
# before a relaunch stops the live agent.
fm_worker_account_select() {
  local harness=$1 config=$2 state=$3 model=$4 executable=$5 raw=${6:-} selection declared root providers word provider=
  selection=$(fm_worker_account_resolve "$harness" "$config" "$state") || return 1
  [ -n "$selection" ] || return 0
  declared=${selection%%$'\t'*}
  root=${selection#*$'\t'}
  providers=${root#*$'\t'}
  root=${root%%$'\t'*}
  if [ "$harness" = claude ]; then
    for word in $raw; do
      case "$word" in
      [A-Za-z_]*=*)
        case " CLAUDE_CONFIG_DIR $FM_WORKER_ACCOUNT_CLAUDE_SHED " in
        *" ${word%%=*} "*)
          echo "error: config/claude-account pins Claude workers, but the raw launch command sets ${word%%=*}, which would override the pinned account; remove ${word%%=*} from the raw command, or change or remove config/claude-account" >&2
          return 1
          ;;
        esac
        ;;
      *) break ;;
      esac
    done
  else
    if [ -n "$raw" ]; then
      echo "error: config/pi-account pins Pi workers, and a raw Pi launch command runs verbatim, so it cannot carry the pinned --provider; launch with --harness $harness and --model <provider>/<id> instead" >&2
      return 1
    fi
    provider=$(fm_worker_account_pi_provider "$model") || {
      echo "error: config/pi-account pins Pi workers to providers ($providers), so a Pi launch needs --model <provider>/<id> naming one of them; '${model:-none}' names no provider, and Firstmate does not guess one" >&2
      return 1
    }
    case " $providers " in
    *" $provider "*) ;;
    *)
      echo "error: config/pi-account pins Pi workers to providers ($providers), but --model '$model' names provider '$provider'" >&2
      return 1
      ;;
    esac
  fi
  if [ "$harness" = claude ]; then
    fm_worker_account_claude_allowed "$config" "$declared" "$root" "$providers" || return 1
  fi
  fm_worker_account_check "$harness" "$declared" "$root" "$executable" "$provider" || return 1
  printf '%s\t%s\t%s\n' "$declared" "$root" "$provider"
}

# fm_worker_account_claude_shed
# Prints the `env` launch prefix that unsets the environment credentials Claude
# ranks above a pinned root's stored login. The caller appends the root
# assignment, or -u CLAUDE_CONFIG_DIR for the ordinary account.
fm_worker_account_claude_shed() {
  local var prefix=env
  for var in $FM_WORKER_ACCOUNT_CLAUDE_SHED; do
    prefix="$prefix -u $var"
  done
  printf '%s\n' "$prefix"
}
