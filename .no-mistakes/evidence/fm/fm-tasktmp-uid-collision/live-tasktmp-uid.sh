#!/usr/bin/env bash
# Live driver: real bin/fm-spawn.sh + bin/fm-teardown.sh on an isolated
# fm-lab-* Herdr session with disposable lab homes. Compares the base commit
# (before) and the change (after) for the per-uid task temp namespace.
# Usage: live-tasktmp-uid.sh <worktree-root> <base-root>
set -u
ROOT=$1
BASE=$2
UID_NOW=$(id -u)
NS="/tmp/firstmate-tasks-$UID_NOW"
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

WORK=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-tasktmp-live.XXXXXX")
SESSION="fm-lab-tmpuid-$$"
export HERDR_SESSION="$SESSION"
TAG="tu$$"
CLEAN_DIRS=()
WTS=()
cleanup() {
  for w in "${WTS[@]}"; do [ -n "$w" ] && treehouse return --force "$w" >/dev/null 2>&1; done
  herdr_safe_stop_and_delete "$SESSION"
  for d in "${CLEAN_DIRS[@]}"; do rm -rf "$d"; done
  find "$WORK" -type d -exec chmod u+rwx {} + 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT
fm_herdr_lab_prepare "$SESSION" || { echo "lab prepare failed"; exit 1; }
echo "## lab session: $SESSION   uid: $UID_NOW"

make_project() {
  local dir=$1
  mkdir -p "$dir"; git -C "$dir" init -q
  printf '# scratch\n' > "$dir/README.md"; git -C "$dir" add README.md
  git -C "$dir" -c user.name=T -c user.email=t@example.invalid commit -qm init
  git clone --quiet --bare "$dir" "$dir.origin.git"
  git -C "$dir" remote add origin "file://$dir.origin.git"
}
make_home() {  # <dir> <id>
  "$ROOT/bin/fm-lab-home.sh" create "$1" >/dev/null
  mkdir -p "$1/data/$2"
  printf '# Task\n## Captain'"'"'s intent\nlive tasktmp check\n\n## Firstmate spec\nnothing\n' > "$1/data/$2/brief.md"
}
spawn() {  # <bin-root> <home> <id> <proj> [env...]
  local br=$1 home=$2 id=$3 proj=$4; shift 4
  env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE "$@" FM_SPAWN_NO_GUARD=1 FM_HOME="$home" \
    "$br/bin/fm-spawn.sh" "$id" "$proj" "sh -c 'echo GOTMPDIR_IN_PANE=\$GOTMPDIR; sleep 600'" \
    --mode no-mistakes --yolo off --backend herdr
}
teardown() {  # <home> <id>
  env -u FM_ROOT_OVERRIDE FM_HOME="$1" "$ROOT/bin/fm-teardown.sh" "$2" --force
}
meta_get() { grep "^$2=" "$1/state/$3.meta" | tail -1 | cut -d= -f2-; }
mode() { /usr/bin/stat -f '%Lp %Su(%u)' "$1"; }

PROJ="$WORK/proj"; make_project "$PROJ"

echo
echo "################ S1: happy path spawn -> per-uid tasktmp -> teardown"
ID1="${TAG}-happy"; H1="$WORK/h1"; make_home "$H1" "$ID1"
spawn "$ROOT" "$H1" "$ID1" "$PROJ" > "$WORK/s1.out" 2>&1; rc=$?
echo "spawn rc=$rc"; [ $rc -eq 0 ] || tail -20 "$WORK/s1.out"
WTS+=("$(meta_get "$H1" worktree "$ID1")")
TT=$(meta_get "$H1" tasktmp "$ID1"); CLEAN_DIRS+=("$TT")
echo "meta tasktmp=$TT"
echo "namespace $NS: $(mode "$NS")"
echo "task root  $TT: $(mode "$TT")"
ls -d "$TT/gotmp" && echo "legacy /tmp/fm-$ID1 exists? $([ -e "/tmp/fm-$ID1" ] && echo yes || echo no)"
sleep 2
PANE=$(meta_get "$H1" herdr_pane_id "$ID1")
herdr pane read "$PANE" --session "$SESSION" --lines 20 2>/dev/null | jq -r '.result.text // .result.content // .' 2>/dev/null | grep GOTMPDIR_IN_PANE | grep -v echo | head -2 \
  || herdr pane read "$PANE" --session "$SESSION" 2>&1 | grep -o 'GOTMPDIR_IN_PANE=[^"\\ ]*' | head -2
teardown "$H1" "$ID1" > "$WORK/t1.out" 2>&1; echo "teardown rc=$?"
echo "task root after teardown exists? $([ -e "$TT" ] && echo yes || echo no)"
echo "namespace after teardown: $(mode "$NS")"

echo
echo "################ S2: the collision - another user's /tmp/fm-<id> already exists"
echo "(stand-in: a 0777 dir; a portable non-root fixture cannot chown to uid 502)"
ID2="${TAG}-collide"
LEG="/tmp/fm-$ID2"; mkdir "$LEG"; chmod 777 "$LEG"; CLEAN_DIRS+=("$LEG")
echo "pre-existing $LEG: $(mode "$LEG")"
echo "--- BEFORE (base 26ba1c7):"
HB="$WORK/hb"; make_home "$HB" "$ID2"
spawn "$BASE" "$HB" "$ID2" "$PROJ" > "$WORK/s2b.out" 2>&1; rc=$?
echo "spawn rc=$rc"; grep -i 'error' "$WORK/s2b.out" | head -3
[ -f "$HB/state/$ID2.meta" ] && { WTS+=("$(meta_get "$HB" worktree "$ID2")"); teardown "$HB" "$ID2" >/dev/null 2>&1; }
echo "--- AFTER (this change):"
HA="$WORK/ha"; make_home "$HA" "$ID2"
spawn "$ROOT" "$HA" "$ID2" "$PROJ" > "$WORK/s2a.out" 2>&1; rc=$?
echo "spawn rc=$rc"; [ $rc -eq 0 ] || tail -20 "$WORK/s2a.out"
WTS+=("$(meta_get "$HA" worktree "$ID2")")
TT2=$(meta_get "$HA" tasktmp "$ID2"); CLEAN_DIRS+=("$TT2")
echo "meta tasktmp=$TT2  ($(mode "$TT2"))"
echo "legacy $LEG untouched: $(mode "$LEG") entries=[$(ls -A "$LEG")]"
teardown "$HA" "$ID2" > "$WORK/t2.out" 2>&1; echo "teardown rc=$?"
echo "after teardown: task root exists? $([ -e "$TT2" ] && echo yes || echo no); legacy still present (not ours to remove)? $([ -d "$LEG" ] && echo yes || echo no)"

echo
echo "################ S3: refuse, not degrade - namespace for this uid owned by someone else"
FAKEBIN="$WORK/fakeid"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/id" <<'SH'
#!/usr/bin/env bash
if [ "$#" -eq 1 ] && [ "$1" = -u ]; then printf '%s\n' "$FM_FAKE_UID"; exit 0; fi
exec /usr/bin/id "$@"
SH
chmod +x "$FAKEBIN/id"
FAKE=$(( UID_NOW + 104733 ))
FNS="/tmp/firstmate-tasks-$FAKE"; rm -rf "$FNS"; mkdir -m 700 "$FNS"; CLEAN_DIRS+=("$FNS")
echo "(fake uid $FAKE via PATH 'id' shim; $FNS is $(mode "$FNS"), i.e. squatted by another uid)"
ID3="${TAG}-foreign"; H3="$WORK/h3"; make_home "$H3" "$ID3"
spawn "$ROOT" "$H3" "$ID3" "$PROJ" PATH="$FAKEBIN:$PATH" FM_FAKE_UID="$FAKE" > "$WORK/s3.out" 2>&1; rc=$?
echo "spawn rc=$rc"; grep -i 'error' "$WORK/s3.out" | head -3
[ -f "$H3/state/$ID3.meta" ] && { echo "meta written: $(cat "$H3/state/$ID3.meta" | grep tasktmp)"; WTS+=("$(meta_get "$H3" worktree "$ID3")"); } || echo "no meta written (refused before any task state)"
echo "foreign namespace contents: [$(ls -A "$FNS")]  mode still: $(mode "$FNS")"
echo "fallback /tmp/fm-$ID3 created? $([ -e "/tmp/fm-$ID3" ] && echo yes || echo no)"

echo
echo "################ S4: refuse - namespace path is a symlink planted to a dir"
FAKE2=$(( UID_NOW + 104734 ))
FNS2="/tmp/firstmate-tasks-$FAKE2"; TGT="$WORK/plant"; mkdir -m 700 "$TGT"; rm -rf "$FNS2"; ln -s "$TGT" "$FNS2"; CLEAN_DIRS+=("$FNS2")
ID4="${TAG}-symlink"; H4="$WORK/h4"; make_home "$H4" "$ID4"
spawn "$ROOT" "$H4" "$ID4" "$PROJ" PATH="$FAKEBIN:$PATH" FM_FAKE_UID="$FAKE2" > "$WORK/s4.out" 2>&1; rc=$?
echo "spawn rc=$rc"; grep -i 'error' "$WORK/s4.out" | head -3
echo "planted target contents: [$(ls -A "$TGT")]"
[ -f "$H4/state/$ID4.meta" ] && echo "meta written!" || echo "no meta written"

echo
echo "################ S5: herdr presentation lock (refactored onto the same lib) still works"
ls -ld "/tmp/firstmate-herdr-presentation-$UID_NOW" | awk '{print $1, $3, $NF}'
grep -i 'presentation' "$WORK/s1.out" | head -3 || true
echo "s1 spawn output tail:"; tail -5 "$WORK/s1.out"
echo DONE
