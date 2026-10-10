#!/usr/bin/env bash
# Live driver: real bin/fm-claude-account-rotate.sh in a disposable lab home whose
# pool is the operator's real Claude config dirs (read-only use; probes only).
set -u
WT=$1
ROT="$WT/bin/fm-claude-account-rotate.sh"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
trap 'rm -rf "$LAB"' EXIT
P=$HOME/.claude-configs/personal Q=$HOME/.claude-configs/qualabs
printf '%s\n%s\n' "$P" "$Q" > "$LAB/config/claude-account"
printf 'javieraramberri37@gmail.com\njavier@qualabs.com\n' > "$LAB/config/claude-account-allowlist"
run() { echo "\$ $*"; env -u NO_MISTAKES_GATE -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE FM_HOME="$LAB" "$@"; echo "[exit $?]"; }
mktask() {  # <id> [account]
  { echo "kind=ship"; echo "harness=claude"; echo "busy_gen=gen-1"; echo "model=haiku"; [ -z "${2:-}" ] || echo "account=$2"; } > "$LAB/state/$1.meta"
  echo gen-1 > "$LAB/state/$1.busy-gen"
}
busy() { printf 'v1 gen=gen-1 seq=%s state=%s source=claude-hook event=hook ts=%s\n' "$2" "$3" "${4:-1}" > "$LAB/state/$1.busy-state"; }
R="$LAB/state/claude-account-rotation"
NOW=$(date +%s)

echo "=== S1 status: real pool with allowlisted emails"
run "$ROT" status
echo; echo "=== S2 live probe of each real account (haiku)"
run "$ROT" probe "$P" --model haiku
run "$ROT" probe "$Q" --model haiku

echo; echo "=== S3 adversarial: pane limit line on a healthy worker (account=personal) -> live probe decides, no relaunch"
mktask t-healthy "$P"
run "$ROT" observe t-healthy --pane-hash h1 --pane-line "You've hit your usage limit · resets 3pm"
echo "episode:"; cat "$R/episode-t-healthy" 2>/dev/null; echo "control relaunch called? -> $(ls "$LAB/state" | grep -c note- )"
echo "repeat observe (same evidence):"; run "$ROT" observe t-healthy --pane-hash h1 --pane-line "You've hit your usage limit · resets 3pm"

echo; echo "=== S4 adversarial: pane limit line on a worker with no recorded account -> unconfirmed, nothing relaunched"
mktask t-noacct
run "$ROT" observe t-noacct --pane-hash h1 --pane-line "You've hit your usage limit · resets 3pm"
cat "$R/episode-t-noacct"

echo; echo "=== S5 adversarial: worker running on a non-allowlisted account -> stop wake naming it"
FAKE=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab-acct.XXXXXX"); trap 'rm -rf "$LAB" "$FAKE"' EXIT
printf '{"oauthAccount":{"emailAddress":"intruder@example.com"}}\n' > "$FAKE/.claude.json"
mktask t-intruder "$FAKE"
run "$ROT" observe t-intruder --pane-hash h1 --pane-line "You've hit your usage limit · resets 3pm"

echo; echo "=== S6 adversarial: pool entry not on allowlist -> whole rotation stops, select refused"
cp "$LAB/config/claude-account-allowlist" "$LAB/al.bak"
printf 'javieraramberri37@gmail.com\n' > "$LAB/config/claude-account-allowlist"
mktask t-block "$P"
run "$ROT" status
run "$ROT" select "$Q"
run "$ROT" observe t-block --pane-hash h1 --pane-line "You've hit your usage limit · resets 3pm"
mv "$LAB/al.bak" "$LAB/config/claude-account-allowlist"; rm -f "$R/blocked" "$R/episode-t-block"
run "$ROT" select "$Q"; echo "selected: $(cat "$R/selected" 2>/dev/null)"

echo; echo "=== S7 expired wait, worker already resumed (busy record 4 idle -> 6 idle): nothing relaunched"
mktask t-resumed "$P"; busy t-resumed 6 idle
printf 'paused [key=claude-usage-limit]: every Claude pool account is at its usage limit; waiting until X\n' > "$LAB/state/t-resumed.status"
printf 'gen=gen-1\noutcome=waiting\nevidence=pane:h1\nuntil=%s\ndeclared=%s\nbusy=4 idle\npane=h1\nprobed=\n' $((NOW-5)) $((NOW-5)) > "$R/episode-t-resumed"
run "$ROT" observe t-resumed --pane-hash h1 --pane-line "You've hit your usage limit · resets 3pm"
echo "episode:"; cat "$R/episode-t-resumed"; echo "status log:"; cat "$LAB/state/t-resumed.status"

echo; echo "=== S8 r5-1: during wait, new limit hash h2 after a finished turn (busy 4->6 idle) refreshes nothing; expiry leaves worker alone"
mktask t-r51 "$P"; busy t-r51 6 idle
printf 'gen=gen-1\noutcome=waiting\nevidence=pane:h1\nuntil=%s\ndeclared=%s\nbusy=4 idle\npane=h1\nprobed=\n' $((NOW+3600)) $((NOW+3600)) > "$R/episode-t-r51"
run "$ROT" observe t-r51 --pane-hash h2 --pane-line "You've hit your usage limit · resets 3pm"
echo "episode after in-wait observe:"; cat "$R/episode-t-r51"
sed -i '' "s/^until=.*/until=$((NOW-1))/" "$R/episode-t-r51"
run "$ROT" observe t-r51 --pane-hash h2 --pane-line "You've hit your usage limit · resets 3pm"
cat "$R/episode-t-r51"

echo; echo "=== S9 r5-2: StopFailure during wait, then a new turn's busy event after it -> stored unchanged; expiry is a resume"
mktask t-r52 "$P"
printf 'gen=gen-1\noutcome=waiting\nevidence=pane:h1\nuntil=%s\ndeclared=%s\nbusy=4 idle\npane=h1\nprobed=\n' $((NOW+3600)) $((NOW+3600)) > "$R/episode-t-r52"
printf '{"error":"rate_limit","last_assistant_message":"You hit your limit"}' | "$ROT" record-stop-failure "$LAB/state" t-r52 --gen gen-1
ERRTS=$(cut -f1 "$LAB/state/t-r52.api-error"); echo "api-error: $(cat "$LAB/state/t-r52.api-error")"
busy t-r52 7 busy $((ERRTS+5))
run "$ROT" observe t-r52
echo "episode (busy should be '7 busy', not '8 idle'):"; cat "$R/episode-t-r52"
busy t-r52 8 idle $((ERRTS+30))
sed -i '' "s/^until=.*/until=$((NOW-1))/" "$R/episode-t-r52"
run "$ROT" observe t-r52 --pane-hash h3
cat "$R/episode-t-r52"
echo; echo "=== S9b r4-2 counterpart: busy event NOT later than the api-error -> stored as <seq+1> idle"
mktask t-r42 "$P"
printf 'gen=gen-1\noutcome=waiting\nevidence=pane:h1\nuntil=%s\ndeclared=%s\nbusy=4 idle\npane=h1\nprobed=\n' $((NOW+3600)) $((NOW+3600)) > "$R/episode-t-r42"
printf '{"error":"rate_limit","last_assistant_message":"You hit your limit"}' | "$ROT" record-stop-failure "$LAB/state" t-r42 --gen gen-1
ERRTS=$(cut -f1 "$LAB/state/t-r42.api-error")
busy t-r42 5 busy $((ERRTS-2))
run "$ROT" observe t-r42
cat "$R/episode-t-r42"

echo; echo "=== rotation log"; cat "$R/log"
echo "lab removed on exit: $LAB"
