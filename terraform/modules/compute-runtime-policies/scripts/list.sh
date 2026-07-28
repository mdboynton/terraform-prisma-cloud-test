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
#     "collection_filter": "<name or empty>",
#     "clusters_filter": "<comma-separated cluster names or empty>"
#   }
#
# Authenticates + GETs the runtime policy, then emits:
#   - full_dump:            every rule with its attached collection names (Direction 1).
#   - rules_by_collection:  map of collection name -> [rule names] (Direction 2).
#                           Restricted to collection_filter when set.
#   - rules_by_cluster:     map of cluster name -> { collections:[...], rules:[...] }
#                           (Direction 3). Only computed when clusters_filter is set;
#                           resolves cluster -> collections that SPECIFICALLY select it
#                           (exact name or targeted trailing-glob; the "*"/"All" wildcard
#                           is excluded as it means "not cluster-constrained") -> the
#                           runtime rules bound to those collections.
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
CLUSTERS_FILTER="$(jq -r '.clusters_filter // ""' <<<"$INPUT")"

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

# Large API payloads (the policy, and especially /collections with thousands of
# entries) are passed to jq via files with --slurpfile, NOT via --argjson on the
# command line, which would blow past ARG_MAX ("Argument list too long").
TMPDIR_LIST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_LIST"' EXIT

curl "${CURL_OPTS[@]}" \
  -H "Authorization: Bearer $TOKEN" \
  -X GET "$BASE$POLICY_PATH" > "$TMPDIR_LIST/policy.json" || fail "failed to GET $POLICY_PATH"

# Only fetch collections when cluster resolution is requested (extra API call).
echo "[]" > "$TMPDIR_LIST/collections.json"
if [ -n "$CLUSTERS_FILTER" ]; then
  curl "${CURL_OPTS[@]}" \
    -H "Authorization: Bearer $TOKEN" \
    -X GET "$BASE/api/v1/collections" > "$TMPDIR_LIST/collections.json" \
    || fail "failed to GET /api/v1/collections"
fi

# --slurpfile wraps each file's content in a 1-element array; index [0] to unwrap.
LISTING="$(jq -n \
  --slurpfile policy_arr "$TMPDIR_LIST/policy.json" \
  --slurpfile collections_arr "$TMPDIR_LIST/collections.json" \
  --arg clusters_csv "$CLUSTERS_FILTER" \
  --arg kind "$POLICY_KIND" \
  --arg filter "$COLLECTION_FILTER" '
  ($policy_arr[0]) as $policy
  | ($collections_arr[0]) as $collections
  | ($clusters_csv | split(",") | map(gsub("^\\s+|\\s+$";"")) | map(select(length>0))) as $clusters
  |
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
  # Direction 3: cluster -> { collections, rules }.
  # A collection "specifically" selects a cluster when a non-"*"/"All" entry of its
  # clusters selector equals the cluster or is a trailing glob matching it.
  ( reduce $clusters[] as $cl ({};
      . + { ($cl): (
        [ $collections[]
          | . as $c
          | (($c.clusters // []) | map(select(. != "*" and . != "All"))) as $spec
          | select(any($spec[];
              . == $cl
              or (endswith("*") and ((.[:-1]) | length > 0) and ($cl | startswith(.[:-1])))
            ))
          | $c.name
        ] | unique
      ) })
  ) as $cluster_cols
  |
  ( reduce $clusters[] as $cl ({};
      . + { ($cl): (
        ($cluster_cols[$cl] | map({(.):true}) | add // {}) as $m
        | {
            collections: $cluster_cols[$cl],
            rules: [ $rules[]
              | select(any((.collections // [])[]; .name as $n | $m[$n]))
              | .name ]
          }
      ) })
  ) as $by_cluster
  |
  {
    policy_kind: $kind,
    rules_total: ($rules | length),
    full_dump: $full,
    rules_by_collection: (
      if $has_filter
      then { ($filter): ($by_all[$filter] // []) }
      else $by_all end
    ),
    rules_by_cluster: $by_cluster
  }')"

RESULT_B64="$(printf '%s' "$LISTING" | base64 | tr -d '\n')"
jq -n --arg r "$RESULT_B64" '{result_b64:$r}'
