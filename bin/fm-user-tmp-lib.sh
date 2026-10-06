#!/usr/bin/env bash
# fm-user-tmp-lib.sh - per-user private namespaces under the fixed /tmp root,
# for paths every Firstmate home of one user must agree on while no other user
# on the machine may resolve or own them.
#
# A namespace is /tmp/<name>-<uid>: the fixed /tmp root, not $TMPDIR, which
# differs between interactive shells, launchd jobs, and harness sandboxes and
# would split one user's processes across two paths.
# A namespace is usable only as a real directory owned by the caller's uid with
# mode 700; anything else refuses rather than degrading.
# No source-time side effects.

fm_user_tmp_namespace() {  # <name>
  local name=$1 uid
  case "$name" in
    ''|*/*) return 1 ;;
  esac
  uid=$(id -u 2>/dev/null) || return 1
  case "$uid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '/tmp/%s-%s' "$name" "$uid"
}

fm_user_tmp_stat_mode() {  # <path>
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    /usr/bin/stat -f '%Lp' "$1" 2>/dev/null
  else
    stat -c '%a' "$1" 2>/dev/null
  fi
}

fm_user_tmp_stat_uid() {  # <path>
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    /usr/bin/stat -f '%u' "$1" 2>/dev/null
  else
    stat -c '%u' "$1" 2>/dev/null
  fi
}

fm_user_tmp_namespace_valid() {  # <dir>
  local dir=$1 expected_uid owner mode
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  expected_uid=$(id -u 2>/dev/null) || return 1
  owner=$(fm_user_tmp_stat_uid "$dir") || return 1
  mode=$(fm_user_tmp_stat_mode "$dir") || return 1
  [ "$owner" = "$expected_uid" ] && [ "$mode" = 700 ]
}

# Create the namespace when absent, then require it to be valid. An existing
# namespace is never chmod-ed or chowned into shape.
fm_user_tmp_namespace_ensure() {  # <dir>
  local dir=$1
  [ -n "$dir" ] || return 1
  if [ ! -e "$dir" ] && [ ! -L "$dir" ]; then
    mkdir -m 700 "$dir" 2>/dev/null || true
  fi
  fm_user_tmp_namespace_valid "$dir"
}
