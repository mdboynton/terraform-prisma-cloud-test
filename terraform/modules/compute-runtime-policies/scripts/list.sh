#!/usr/bin/env bash
#
# list.sh — READ-ONLY listing for the compute-runtime-policies module.
#
# Invoked by a `data "external"` block. Reads a JSON object from stdin:
#   {
#     "console_url": "...",
#     "access_key": "...",
#     "secret_key": "...",
#     "policy_kind": "container" | "host",
#     "skip_cert_verification": "true" | "false",
#     "collection_filter": "<name or empty>"
#   }
#
# Authenticates + GETs the runtime policy, then emits BOTH directions:
#   - full_dump:         every rule with its attached collection names (Direction 1).
#   - rules_by_collection: map of collection name -> [rule names referencing it]
#                          (Direction 2). When collection_filter is non-empty, the
#                          map is restricted to that single collection.
#
# Prints a FLAT JSON object (string->string) to stdout, base64-packed:
#   { "result_b64": "<base64 of the listing JSON>" }
#
# Makes NO changes (read-only).

set -euo pipefail

fail() { echo "{\"error\":\"$1\"}" >&2; exit 1; }

command -v jq   >/dev/null 2>&1 || fail "jq is required but not found"
command -v curl >/dev/null 2>&1 || fail "curl is required but not found"

INPUT="$(cat)"

CONSOLE_URL="$(jq -r '.console_url'           <<<"$INPUT")"
ACCESS_KEY="$(jq -r '.access_key'             <<<"$INPUT")"
SECRET_KEY="$(jq -r '.secret_key'            <<<"$INPUT")"
POLICY_KIND="$(jq -r '.policy_kind'          <<<"$INPUT")"
SKIP_CERT="$(jq -r '.skip_cert_verification' <<<"$INPUT")"
COLLECTION_FILTER="$(jq -r '.collection_filter // ""' <<<"$INPUT")"

[ -n "$CONSOLE_URL" ] && [ "$CONSOLE_URL" != "null" ] || fail "console_url is empty"

CURL_OPTS=(--silent --show-error --fail-with-body)
[ "$SKIP_CERT" = "true" ] && CURL_OPTS+=(-k)

case "$POLICY_KIND" in
  container) POLICY_PATH="/api/v1/policies/runtime/container" ;;
  host)      POLICY_PATH="/api/v1/policies/runtime/host" ;;
  *)         fail "policy_kind must be 'container' or 'host', got '$POLICY_KIND'" ;;
esac

BASE="${CONSOLE_URL%/}"

TOKEN="$(curl "${CURL_OPTS[@]}" \
  -H 'Content-Type: application/json' \
  -X POST "$BASE/api/v1/authenticate" \
  -d "{\"username\":\"$ACCESS_KEY\",\"password\":\"$SECRET_KEY\"}" \
  | jq -r '.token')" || fail "authentication failed"
[ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] || fail "authentication returned no token"

POLICY_JSON="$(curl "${CURL_OPTS[@]}" \
  -H "Authorization: Bearer $TOKEN" \
  -X GET "$BASE$POLICY_PATH")" || fail "failed to GET $POLICY_PATH"

LISTING="$(jq -n \
  --argjson policy "$POLICY_JSON" \
  --arg kind "$POLICY_KIND" \
  --arg filter "$COLLECTION_FILTER" '
  ($policy.rules // []) as $rules
  |
  # Direction 1: every rule with its collection names.
  ($rules | map({
      name: .name,
      disabled: (.disabled // false),
      collections: ((.collections // []) | map(.name))
   })) as $full
  |
  # Direction 2: collection name -> rules referencing it.
  ([ $rules[]
     | .name as $rn
     | ((.collections // []) | map(.name))[]
     | { collection: ., rule: $rn }
   ]
   | group_by(.collection)
   | map({ key: .[0].collection, value: (map(.rule)) })
   | from_entries) as $by_all
  |
  ($filter | length > 0) as $has_filter
  |
  {
    policy_kind: $kind,
    rules_total: ($rules | length),
    full_dump: $full,
    rules_by_collection: (
      if $has_filter
      then { ($filter): ($by_all[$filter] // []) }
      else $by_all end
    )
  }')"

RESULT_B64="$(printf '%s' "$LISTING" | base64 | tr -d '\n')"
jq -n --arg r "$RESULT_B64" '{result_b64:$r}'
