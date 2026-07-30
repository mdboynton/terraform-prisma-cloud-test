#!/usr/bin/env bash
#
# merge_apply.sh — NON-DESTRUCTIVE WRITE for the compute-runtime-policies module.
#
# Invoked by a `null_resource` local-exec on apply. Reads configuration from
# environment variables (set via the null_resource `environment` block):
#   PCC_CONSOLE_URL              Compute Console URL
#   PCC_ACCESS_KEY               access key id
#   PCC_SECRET_KEY               secret key
#   PCC_POLICY_KIND             "container" | "host"
#   PCC_SKIP_CERT               "true" | "false"
#   PCC_ASSOCIATIONS_B64         base64 of [{policy_rule_name,add_collection}, ...]
#   PCC_DRY_RUN                  "true" | "false" (when true, print diff but do NOT PUT)
#
# Behavior: GET the runtime policy, append add_collection to the `collections`
# of each matched rule (idempotent — skips if already present, preserves all
# other collections and every other field), then PUT the EXACT same object back
# with only the targeted collections changed. Round-trips the policy verbatim so
# no field is ever clobbered.

set -euo pipefail

fail() { echo "ERROR: $1" >&2; exit 1; }

command -v jq   >/dev/null 2>&1 || fail "jq is required but not found"
command -v curl >/dev/null 2>&1 || fail "curl is required but not found"

: "${PCC_CONSOLE_URL:?PCC_CONSOLE_URL is required}"
: "${PCC_ACCESS_KEY:?PCC_ACCESS_KEY is required}"
: "${PCC_SECRET_KEY:?PCC_SECRET_KEY is required}"
: "${PCC_POLICY_KIND:?PCC_POLICY_KIND is required}"
: "${PCC_ASSOCIATIONS_B64:?PCC_ASSOCIATIONS_B64 is required}"
SKIP_CERT="${PCC_SKIP_CERT:-false}"
DRY_RUN="${PCC_DRY_RUN:-false}"

CURL_OPTS=(--silent --show-error --fail-with-body)
[ "$SKIP_CERT" = "true" ] && CURL_OPTS+=(-k)

case "$PCC_POLICY_KIND" in
  container) POLICY_PATH="/api/v1/policies/runtime/container" ;;
  host)      POLICY_PATH="/api/v1/policies/runtime/host" ;;
  *)         fail "PCC_POLICY_KIND must be 'container' or 'host', got '$PCC_POLICY_KIND'" ;;
esac

BASE="${PCC_CONSOLE_URL%/}"

# 1. Authenticate.
TOKEN="$(curl "${CURL_OPTS[@]}" \
  -H 'Content-Type: application/json' \
  -X POST "$BASE/api/v1/authenticate" \
  -d "{\"username\":\"$PCC_ACCESS_KEY\",\"password\":\"$PCC_SECRET_KEY\"}" \
  | jq -r '.token')" || fail "authentication failed"
[ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] || fail "authentication returned no token"

# 2. GET the live policy (verbatim). Written to a file; passed to jq via
#    --slurpfile so a large policy does not overflow ARG_MAX.
TMPDIR_MERGE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_MERGE"' EXIT
curl "${CURL_OPTS[@]}" \
  -H "Authorization: Bearer $TOKEN" \
  -X GET "$BASE$POLICY_PATH" > "$TMPDIR_MERGE/policy.json" || fail "failed to GET $POLICY_PATH"

ASSOC_JSON="$(printf '%s' "$PCC_ASSOCIATIONS_B64" | base64 --decode)"

# 3. Merge: for each association, append {name:add_collection} to the matched
#    rule's collections if not already present. Everything else is untouched.
jq --argjson assoc "$ASSOC_JSON" '
  . as $policy
  | reduce $assoc[] as $a (
      $policy;
      .rules |= map(
        if .name == $a.policy_rule_name then
          .collections = (
            ( .collections // [] ) as $cols
            | if ($cols | map(.name) | index($a.add_collection)) != null
              then $cols
              else $cols + [ { "name": $a.add_collection } ] end
          )
        else . end
      )
    )
  ' "$TMPDIR_MERGE/policy.json" > "$TMPDIR_MERGE/merged.json" || fail "merge failed"

# 4. Report what changed (names of rules whose collections grew).
CHANGED="$(jq -n \
  --slurpfile before "$TMPDIR_MERGE/policy.json" \
  --slurpfile after  "$TMPDIR_MERGE/merged.json" '
  ($before[0]) as $b | ($after[0]) as $a
  | [ $a.rules[]
      | . as $ar
      | ($b.rules[] | select(.name == $ar.name)) as $br
      | select( (($ar.collections // []) | length) != (($br.collections // []) | length) )
      | $ar.name
    ]')"
echo "changed_rules=$CHANGED" >&2

if [ "$DRY_RUN" = "true" ]; then
  echo "DRY RUN — no changes applied to $PCC_POLICY_KIND runtime policy." >&2
  exit 0
fi

# Idempotent: skip the PUT when the merge produced no change.
if cmp -s "$TMPDIR_MERGE/policy.json" "$TMPDIR_MERGE/merged.json"; then
  echo "No changes needed for $PCC_POLICY_KIND runtime policy (idempotent)." >&2
  exit 0
fi

# 5. PUT the merged policy back (body from file to avoid ARG_MAX on -d).
#
# The response body is captured rather than discarded: this endpoint reports
# real, actionable reasons in it (unknown collection, illegal characters in a
# collection name, ...). Without this, a rejection surfaced only as the opaque
# `curl: (22) ... error: 400` that gives no clue what to fix.
HTTP_CODE="$(curl "${CURL_OPTS[@]}" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -X PUT "$BASE$POLICY_PATH" \
  --data-binary "@$TMPDIR_MERGE/merged.json" \
  -o "$TMPDIR_MERGE/response.json" \
  -w '%{http_code}' || true)"

if [ "$HTTP_CODE" != "200" ] && [ "$HTTP_CODE" != "204" ]; then
  API_ERR="$(jq -r '.err // .error // empty' "$TMPDIR_MERGE/response.json" 2>/dev/null || true)"
  [ -n "$API_ERR" ] || API_ERR="$(head -c 300 "$TMPDIR_MERGE/response.json" 2>/dev/null || true)"
  echo "ERROR: PUT $POLICY_PATH returned HTTP $HTTP_CODE" >&2
  echo "       API said: ${API_ERR:-(empty response body)}" >&2
  echo "       add_collection must satisfy ALL of:" >&2
  echo "         1. the collection already exists" >&2
  echo "         2. its name matches ^[A-Za-z0-9_:-]+\$ (no spaces/parens, so" >&2
  echo "            '<x> - Access Group (RBAC)' is never usable here)" >&2
  echo "         3. HOST rules only: its clusters must be empty or ['*']" >&2
  echo "       Nothing was changed by this request." >&2
  exit 1
fi

echo "Applied collection associations to $PCC_POLICY_KIND runtime policy." >&2
