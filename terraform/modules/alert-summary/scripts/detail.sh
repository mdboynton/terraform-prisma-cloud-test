#!/usr/bin/env bash
#
# detail.sh — fetch per-alert DETAIL for an account-scoped CSPM alert query.
#
# Invoked by a `data "external"` block. Reads a JSON object from stdin:
#   {
#     "cspm_url":         "api2.prismacloud.io",
#     "access_key":       "...",
#     "secret_key":       "...",
#     "accounts_b64":     "<base64 of [\"082654650179\", ...]>",
#     "severities_b64":   "<base64 of [\"critical\", ...]>",
#     "time_amount":      "30",
#     "time_unit":        "day",
#     "alert_status":     "open",
#     "max_rows":         "500"
#   }
#
# Prints a FLAT JSON object (string -> string) to stdout, as the external data
# source protocol requires — nested values are rejected by Terraform:
#   { "result_b64": "<base64 of the detail JSON>" }
#
# READ-ONLY. Every call is a GET (plus the POST /login handshake).
#
# WHY THIS SCRIPT EXISTS AT ALL:
# the `prismacloud_alerts` data source returns a thin `listing` — alert_id,
# status, timestamps. No policy name, no resource name, no severity. Those only
# come from the REST list endpoint with `detailed=true`, which the provider does
# not expose. The counts in main.tf still come from the provider; this script is
# strictly additive and never feeds the totals.
#
# WHY NOT `GET /alert/{id}` (the endpoint one would reach for first):
# measured on this tenant at ~3.9s per call. For a 423-alert collection that is
# ~27 minutes and 423 round trips. The LIST endpoint already carries every field
# that per-alert GET would return, so the whole job is one paged query. Verified:
# policy.name, policy.severity, resource.name, resource.resourceType,
# resource.id, resource.account, resource.regionId and alertTime were present on
# 100/100 rows of a detailed=true page.

set -euo pipefail

fail() { echo "{\"error\":\"$1\"}" >&2; exit 1; }

command -v jq   >/dev/null 2>&1 || fail "jq is required but not found"
command -v curl >/dev/null 2>&1 || fail "curl is required but not found"

INPUT="$(cat)"

CSPM_URL="$(jq -r '.cspm_url'       <<<"$INPUT")"
ACCESS_KEY="$(jq -r '.access_key'   <<<"$INPUT")"
SECRET_KEY="$(jq -r '.secret_key'   <<<"$INPUT")"
ACCOUNTS_B64="$(jq -r '.accounts_b64'   <<<"$INPUT")"
SEVERITIES_B64="$(jq -r '.severities_b64' <<<"$INPUT")"
TIME_AMOUNT="$(jq -r '.time_amount' <<<"$INPUT")"
TIME_UNIT="$(jq -r '.time_unit'     <<<"$INPUT")"
ALERT_STATUS="$(jq -r '.alert_status' <<<"$INPUT")"
MAX_ROWS="$(jq -r '.max_rows'       <<<"$INPUT")"

[ -n "$CSPM_URL" ] && [ "$CSPM_URL" != "null" ] || fail "cspm_url is empty"

ACCOUNTS="$(printf '%s' "$ACCOUNTS_B64"   | base64 --decode)"
SEVERITIES="$(printf '%s' "$SEVERITIES_B64" | base64 --decode)"

# HARD GUARD — never run this query unscoped.
#
# The alerts API drops filter names it does not recognise and returns HTTP 200
# with the FULL tenant-wide result set. An empty account list would therefore
# not error; it would quietly return every alert in the tenant (~9,000 here) and
# label them as belonging to the collection. The module only calls this script
# when it has resolved accounts, so an empty list means something upstream
# changed — refuse rather than guess.
ACCOUNT_COUNT="$(jq 'length' <<<"$ACCOUNTS")"
[ "$ACCOUNT_COUNT" -gt 0 ] || fail "no cloud accounts supplied - refusing to run an unscoped query that would return tenant-wide alerts"

SEV_COUNT="$(jq 'length' <<<"$SEVERITIES")"
[ "$SEV_COUNT" -gt 0 ] || fail "no severities supplied"

BASE="https://${CSPM_URL#https://}"
BASE="${BASE%/}"

CURL_OPTS=(--silent --show-error --fail-with-body)

# 1. Authenticate.
TOKEN="$(curl "${CURL_OPTS[@]}" \
  -H 'Content-Type: application/json' \
  -X POST "$BASE/login" \
  -d "{\"username\":\"$ACCESS_KEY\",\"password\":\"$SECRET_KEY\"}" \
  | jq -r '.token')" || fail "authentication failed"
[ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] || fail "authentication returned no token"

# 2. Build the repeated query parameters.
#
# CRITICAL — one parameter PER VALUE, never a comma-joined list. Verified on the
# live tenant for cloud.accountId:
#   account A alone          -> 188
#   account B alone          -> 271
#   repeated (A, B)          -> 459   = 188 + 271, correct OR
#   single param "A,B" (CSV) -> 0     WRONG, and silently so (still HTTP 200)
# A CSV value looks perfectly reasonable, so this would have under-reported
# every multi-account collection to zero without any error.
QARGS=()
# Piping into `while` would run the loop in a subshell and lose QARGS, so the
# values are read from a here-string instead.
while IFS= read -r a; do
  [ -n "$a" ] && QARGS+=(--data-urlencode "cloud.accountId=$a")
done <<<"$(jq -r '.[]' <<<"$ACCOUNTS")"

while IFS= read -r s; do
  [ -n "$s" ] && QARGS+=(--data-urlencode "policy.severity=$s")
done <<<"$(jq -r '.[]' <<<"$SEVERITIES")"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PAGE_SIZE=250
[ "$MAX_ROWS" -lt "$PAGE_SIZE" ] && PAGE_SIZE="$MAX_ROWS"

# 3. Page through the results.
#
# Pagination is TOKEN based, not offset based. The response carries
# `nextPageToken`; the terminator is that field being null (verified: a query
# whose rows all fit in one page returns nextPageToken: null).
#
# The follow-up parameter is `pageToken`. It is NOT `nextPageToken` — passing
# the response's own key name back returns HTTP 200 and RE-SERVES PAGE ONE.
# Verified by comparing ids: pageToken gave a fresh page, nextPageToken gave the
# first page again. An infinite loop that silently collects duplicates.
PAGE_TOKEN=""
PAGE_NUM=0
TOTAL_ROWS="null"
: > "$TMP/all.ndjson"
FETCHED=0

while : ; do
  PAGE_NUM=$((PAGE_NUM + 1))
  [ "$PAGE_NUM" -gt 200 ] && fail "pagination exceeded 200 pages - aborting rather than looping forever"

  REMAINING=$((MAX_ROWS - FETCHED))
  [ "$REMAINING" -le 0 ] && break
  THIS_PAGE="$PAGE_SIZE"
  [ "$REMAINING" -lt "$THIS_PAGE" ] && THIS_PAGE="$REMAINING"

  if [ -z "$PAGE_TOKEN" ]; then
    curl "${CURL_OPTS[@]}" -G "$BASE/v2/alert" \
      -H "x-redlock-auth: $TOKEN" \
      --data-urlencode 'timeType=relative' \
      --data-urlencode "timeAmount=$TIME_AMOUNT" \
      --data-urlencode "timeUnit=$TIME_UNIT" \
      --data-urlencode "alert.status=$ALERT_STATUS" \
      --data-urlencode 'detailed=true' \
      --data-urlencode "limit=$THIS_PAGE" \
      "${QARGS[@]}" > "$TMP/page.json" || fail "alert query failed on page $PAGE_NUM"
  else
    # The token carries the original filters; they are not resent.
    curl "${CURL_OPTS[@]}" -G "$BASE/v2/alert" \
      -H "x-redlock-auth: $TOKEN" \
      --data-urlencode "pageToken=$PAGE_TOKEN" \
      --data-urlencode "limit=$THIS_PAGE" > "$TMP/page.json" \
      || fail "alert query failed on page $PAGE_NUM"
  fi

  [ "$TOTAL_ROWS" = "null" ] && TOTAL_ROWS="$(jq -r '.totalRows // 0' "$TMP/page.json")"

  GOT="$(jq '.items | length' "$TMP/page.json")"
  [ "$GOT" -eq 0 ] && break

  # Reduce HERE, per page, so the full detailed payload is never accumulated.
  # A detailed=true row is ~9.3 KB; the fields kept below are ~263 bytes. For a
  # 2,000-alert collection that is the difference between ~19 MB and ~0.5 MB
  # held in memory and handed to Terraform.
  jq -c '.items[] | {
    id:          .id,
    severity:    .policy.severity,
    policy:      .policy.name,
    policy_type: .policy.policyType,
    resource:    .resource.name,
    resource_id: .resource.id,
    type:        .resource.resourceType,
    account:     .resource.account,
    account_id:  .resource.accountId,
    region:      .resource.regionId,
    alert_time:  .alertTime
  }' "$TMP/page.json" >> "$TMP/all.ndjson"

  FETCHED=$((FETCHED + GOT))

  PAGE_TOKEN="$(jq -r '.nextPageToken // ""' "$TMP/page.json")"
  [ -z "$PAGE_TOKEN" ] && break

  # The tenant rate-limits sustained looping; without this, long runs start
  # returning empty bodies partway through.
  sleep 1
done

# 4. Assemble. `total_matching` is the SERVER's count for this query and is
#    deliberately kept separate from `fetched` — if the cap truncates, the
#    consumer must still be able to see how many there really were rather than
#    reading the capped number as the truth.
# `-s` slurps the NDJSON stream into one array. Note: do NOT add `-n` here -
# with null input jq never reads the file and `.` is null, not the rows.
# The array is bound to $rows because `.` rebinds inside sub-expressions.
[ "$TOTAL_ROWS" = "null" ] && TOTAL_ROWS=0

ERR="$(jq -s \
  --argjson total "$TOTAL_ROWS" \
  --argjson max "$MAX_ROWS" \
  --argjson sevs "$SEVERITIES" \
  '. as $rows
   | ($rows | length) as $n
   | {
       rows:           $rows,
       fetched:        $n,
       total_matching: $total,
       truncated:      (($total > $n) and ($n >= $max)),
       max_rows:       $max,
       severities:     $sevs,
       by_severity:    (reduce $rows[] as $r ({}; .[$r.severity] = ((.[$r.severity] // 0) + 1)))
     }' "$TMP/all.ndjson" > "$TMP/result.json" 2>&1)" \
  || fail "failed to assemble result: ${ERR//\"/}"

printf '{"result_b64":"%s"}\n' "$(base64 < "$TMP/result.json" | tr -d '\n')"
