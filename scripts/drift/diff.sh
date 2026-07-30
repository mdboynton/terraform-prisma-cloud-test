#!/usr/bin/env bash
#
# diff.sh - compare two tenant snapshots and describe what changed.
#
# Usage: diff.sh <baseline.json> <current.json> [markdown_out]
#
# Exit codes are the interface:
#   0  no drift
#   2  drift detected   (distinct from 1 so a real script failure is never
#                        mistaken for "the tenant changed")
#   1  usage/runtime error
#
# Output is markdown on stdout, and also written to markdown_out when given.

set -euo pipefail

fail() { echo "ERROR: $1" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || fail "jq is required but not found"

BASE="${1:?usage: diff.sh <baseline.json> <current.json> [markdown_out]}"
CURR="${2:?usage: diff.sh <baseline.json> <current.json> [markdown_out]}"
OUT="${3:-}"

[ -f "$CURR" ] || fail "current snapshot not found: $CURR"

# First run: no baseline to compare against. That is not drift - reporting it as
# drift would open a spurious issue on day one - so it exits 0 and says so.
if [ ! -f "$BASE" ]; then
  msg="## Tenant drift

No baseline snapshot exists yet, so there is nothing to compare against. This
run establishes the baseline; the next run will report changes against it."
  echo "$msg"
  [ -n "$OUT" ] && printf '%s\n' "$msg" > "$OUT"
  exit 0
fi

# jq requires every `def` to be declared before the pipeline that uses it, so
# the two helpers are hoisted to the top rather than defined inline.
REPORT="$(jq -n \
  --slurpfile b "$BASE" \
  --slurpfile c "$CURR" '
  def by_name($xs): ($xs // []) | map({ key: .name, value: . }) | from_entries;
  def by_id($xs):   ($xs // []) | map({ key: .id,   value: . }) | from_entries;

  ($b[0]) as $base | ($c[0]) as $curr

  # ---- counts -------------------------------------------------------------
  | [ ($curr.counts // {}) | keys[] ] as $keys
  | [ $keys[]
      | . as $k
      | ($base.counts[$k]) as $was
      | ($curr.counts[$k]) as $now
      | select($was != $now)
      | { key: $k, was: $was, now: $now }
    ] as $count_changes

  # ---- roles / permission groups: added, removed, modified ----------------
  #
  # Each key is bound with `as $k` before use. Writing `keys[] | select(has(.))`
  # instead would rebind `.` to the key string, so `has(.)` would ask whether an
  # OBJECT has an OBJECT as a key and fail at runtime.
  | (by_name($base.roles))  as $br | (by_name($curr.roles))  as $cr
  | (by_name($base.permission_groups)) as $bg | (by_name($curr.permission_groups)) as $cg

  | { added:    [ $cr | keys[] as $k | select($br | has($k) | not) | $k ],
      removed:  [ $br | keys[] as $k | select($cr | has($k) | not) | $k ],
      modified: [ $cr | keys[] as $k | select(($br | has($k)) and ($br[$k] != $cr[$k]))
                  | { name: $k, was: $br[$k], now: $cr[$k] } ]
    } as $roles

  | { added:    [ $cg | keys[] as $k | select($bg | has($k) | not) | $k ],
      removed:  [ $bg | keys[] as $k | select($cg | has($k) | not) | $k ],
      modified: [ $cg | keys[] as $k | select(($bg | has($k)) and ($bg[$k] != $cg[$k]))
                  | { name: $k, was: $bg[$k], now: $cg[$k] } ]
    } as $groups

  # ---- users: identified only by their hashed id --------------------------
  | (by_id($base.users)) as $bu | (by_id($curr.users)) as $cu
  | { added:    ([ $cu | keys[] as $k | select($bu | has($k) | not) | $k ] | length),
      removed:  ([ $bu | keys[] as $k | select($cu | has($k) | not) | $k ] | length),
      modified: [ $cu | keys[] as $k | select(($bu | has($k)) and ($bu[$k] != $cu[$k]))
                  | { id: $k, was: $bu[$k], now: $cu[$k] } ]
    } as $users

  | { count_changes: $count_changes, roles: $roles, groups: $groups, users: $users }
  | . + { drift: (
      ($count_changes | length) > 0
      or (($roles.added + $roles.removed + $roles.modified) | length) > 0
      or (($groups.added + $groups.removed + $groups.modified) | length) > 0
      or $users.added > 0 or $users.removed > 0 or ($users.modified | length) > 0
    ) }
')" || fail "failed to diff snapshots"

DRIFT="$(printf '%s' "$REPORT" | jq -r '.drift')"

MD="$(printf '%s' "$REPORT" | jq -r '
  def section($title; $rows):
    if ($rows | length) == 0 then empty
    else "### \($title)", "", ($rows[]), "" end;

  if .drift | not then
    "## Tenant drift", "", "No changes since the last snapshot."
  else
    "## Tenant drift detected", "",
    section("Counts";
      [ .count_changes[] | "- **\(.key)**: `\(.was)` -> `\(.now)`" ]),
    section("Roles";
      [ (.roles.added[]    | "- added: `\(.)`"),
        (.roles.removed[]  | "- removed: `\(.)`"),
        (.roles.modified[] | "- changed: `\(.name)` (assigned users \(.was.assigned_user_count) -> \(.now.assigned_user_count), account groups \(.was.account_group_count) -> \(.now.account_group_count))") ]),
    section("Permission groups";
      [ (.groups.added[]    | "- added: `\(.)`"),
        (.groups.removed[]  | "- removed: `\(.)`"),
        (.groups.modified[] | "- changed: `\(.name)`") ]),
    section("Users";
      [ (if .users.added   > 0 then "- \(.users.added) added"   else empty end),
        (if .users.removed > 0 then "- \(.users.removed) removed" else empty end),
        (.users.modified[] | "- changed: `\(.id)` (enabled \(.was.enabled) -> \(.now.enabled), roles \(.was.role_count) -> \(.now.role_count))") ]),
    "_Users are shown as hashed ids; snapshots never contain email addresses._"
  end
')"

echo "$MD"
[ -n "$OUT" ] && printf '%s\n' "$MD" > "$OUT"

[ "$DRIFT" = "true" ] && exit 2
exit 0
