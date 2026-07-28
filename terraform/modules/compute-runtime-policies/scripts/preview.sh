#!/usr/bin/env bash
#
# preview.sh — DRY RUN for the compute-runtime-policies module.
#
# Invoked by a `data "external"` block. Reads a JSON object from stdin:
#   {
#     "console_url": "...",
#     "access_key": "...",
#     "secret_key": "...",
#     "policy_kind": "container" | "host",
#     "skip_cert_verification": "true" | "false",
#     "associations_json": "<base64 of [{policy_rule_name,add_collection}, ...]>"
#   }
#
# Authenticates to the Compute Console, GETs the runtime policy, and for each
# association reports whether the collection is already present, would be added,
# or the rule was not found. Prints a FLAT JSON object (string->string) to stdout
# as required by the external data source protocol:
#   { "result_b64": "<base64 of the preview JSON>" }
#
# It makes NO changes (read-only). The actual write is done by merge_apply.sh.

set -euo pipefail

fail() { echo "{\"error\":\"$1\"}" >&2; exit 1; }

command -v jq   >/dev/null 2>&1 || fail "jq is required but not found"
command -v curl >/dev/null 2>&1 || fail "curl is required but not found"

INPUT="$(cat)"

CONSOLE_URL="$(jq -r '.console_url'            <<<"$INPUT")"
ACCESS_KEY="$(jq -r '.access_key'              <<<"$INPUT")"
SECRET_KEY="$(jq -r '.secret_key'              <<<"$INPUT")"
POLICY_KIND="$(jq -r '.policy_kind'           <<<"$INPUT")"
SKIP_CERT="$(jq -r '.skip_cert_verification'  <<<"$INPUT")"
ASSOC_B64="$(jq -r '.associations_json'       <<<"$INPUT")"

[ -n "$CONSOLE_URL" ] && [ "$CONSOLE_URL" != "null" ] || fail "console_url is empty"

CURL_OPTS=(--silent --show-error --fail-with-body)
[ "$SKIP_CERT" = "true" ] && CURL_OPTS+=(-k)

# Compute API path for the runtime policy of this kind.
case "$POLICY_KIND" in
  container) POLICY_PATH="/api/v1/policies/runtime/container" ;;
  host)      POLICY_PATH="/api/v1/policies/runtime/host" ;;
  *)         fail "policy_kind must be 'container' or 'host', got '$POLICY_KIND'" ;;
esac

BASE="${CONSOLE_URL%/}"

# 1. Authenticate -> bearer token.
TOKEN="$(curl "${CURL_OPTS[@]}" \
  -H 'Content-Type: application/json' \
  -X POST "$BASE/api/v1/authenticate" \
  -d "{\"username\":\"$ACCESS_KEY\",\"password\":\"$SECRET_KEY\"}" \
  | jq -r '.token')" || fail "authentication failed"
[ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] || fail "authentication returned no token"

# 2. GET the live policy.
POLICY_JSON="$(curl "${CURL_OPTS[@]}" \
  -H "Authorization: Bearer $TOKEN" \
  -X GET "$BASE$POLICY_PATH")" || fail "failed to GET $POLICY_PATH"

# 3. Decode associations and compute the dry-run per association.
ASSOC_JSON="$(printf '%s' "$ASSOC_B64" | base64 --decode)"

PREVIEW="$(jq -n \
  --argjson policy "$POLICY_JSON" \
  --argjson assoc "$ASSOC_JSON" '
  {
    policy_kind: "'"$POLICY_KIND"'",
    rules_total: ($policy.rules | length),
    associations: [
      $assoc[] as $a
      | ($policy.rules // []) as $rules
      | ($rules | map(select(.name == $a.policy_rule_name)) | first) as $match
      | {
          policy_rule_name: $a.policy_rule_name,
          add_collection:   $a.add_collection,
          status: (
            if $match == null then "rule_not_found"
            elif (($match.collections // []) | map(.name) | index($a.add_collection)) != null
                 then "already_present"
            else "would_add" end
          ),
          existing_collections: (
            if $match == null then []
            else (($match.collections // []) | map(.name)) end
          )
        }
    ]
  }')"

RESULT_B64="$(printf '%s' "$PREVIEW" | base64 | tr -d '\n')"
jq -n --arg r "$RESULT_B64" '{result_b64:$r}'
