#!/usr/bin/env bash
#
# summary.sh — count Compute findings (runtime incidents + image vulnerabilities)
# scoped to a COMPUTE collection.
#
# Invoked by `data "external"`. READ-ONLY: every request below is a GET except
# the authentication POST. Nothing in this script can change the tenant.
#
# ------------------------------------------------------------------
# WHY THIS EXISTS RATHER THAN EXTENDING THE CSPM alert-summary MODULE
#
# Prisma has TWO unrelated collection systems. The "<name> - Access Group (RBAC)"
# collections that a Resource List spawns are COMPUTE objects and do not exist on
# the CSPM side at all (verified: 0 of 46 CSPM collections). A customer that
# onboards no cloud accounts therefore cannot be scoped by the CSPM module, whose
# only lever is cloud.accountId — and 2,056 of 2,186 Compute collections are
# accountIDs:["*"], which that module correctly refuses as "no scope".
#
# Different host, different auth, different objects. See
# plans/compute-collection-scoping-findings.md.
# ------------------------------------------------------------------
#
# Input (stdin, JSON object from Terraform — every value is a STRING):
#   console_url      Compute Console URL (CSWP_URL, including any path segment)
#   access_key       access key id
#   secret_key       secret key
#   collection_name  the Compute collection to scope to
#   max_images       cap on images fetched for the vulnerability rollup
#   skip_cert        "true" | "false"
#
# Output (stdout, JSON object of STRINGS — `data "external"` requires a flat
# map of strings; numbers are emitted via tostring and re-parsed by the module).

set -euo pipefail

fail() { echo "ERROR: $1" >&2; exit 1; }

command -v jq   >/dev/null 2>&1 || fail "jq is required but not found"
command -v curl >/dev/null 2>&1 || fail "curl is required but not found"

INPUT="$(cat)"
jq -e . >/dev/null 2>&1 <<<"$INPUT" || fail "stdin was not valid JSON"

CONSOLE_URL="$(jq -r '.console_url // ""'     <<<"$INPUT")"
ACCESS_KEY="$(jq  -r '.access_key // ""'      <<<"$INPUT")"
SECRET_KEY="$(jq  -r '.secret_key // ""'      <<<"$INPUT")"
COLLECTION="$(jq  -r '.collection_name // ""' <<<"$INPUT")"
MAX_IMAGES="$(jq  -r '.max_images // "1000"'  <<<"$INPUT")"
SKIP_CERT="$(jq   -r '.skip_cert // "false"'  <<<"$INPUT")"

[ -n "$CONSOLE_URL" ] || fail "console_url is required"
[ -n "$ACCESS_KEY" ]  || fail "access_key is required"
[ -n "$SECRET_KEY" ]  || fail "secret_key is required"

# HARD GUARD: refuse an empty collection name.
#
# An empty `collections=` is not an error to the API — it is simply absent, and
# an absent filter returns the ENTIRE TENANT. Reporting 14,409 tenant-wide
# incidents as if they belonged to one team is the exact failure this module
# exists to prevent, so it is refused here rather than trusted downstream.
[ -n "$COLLECTION" ] || fail "collection_name is required — refusing to run unscoped (an absent filter returns the whole tenant)"

case "$MAX_IMAGES" in
  ''|*[!0-9]*) fail "max_images must be a positive integer, got '$MAX_IMAGES'" ;;
esac
[ "$MAX_IMAGES" -gt 0 ] || fail "max_images must be greater than zero"

BASE="${CONSOLE_URL%/}"

CURL_OPTS=(--silent --show-error --fail-with-body)
[ "$SKIP_CERT" = "true" ] && CURL_OPTS+=(-k)

# Credentials must never appear in argv: the full command line of any process is
# world-readable via `ps -o args=`. Measured on this machine — a plain
# `curl -d '{"password":"..."}'` leaked the secret. The body therefore goes in
# over stdin and the token lives in a 0700 directory read via `-H @file`.
TMP="$(mktemp -d)"
chmod 700 "$TMP"
trap 'rm -rf "$TMP"' EXIT

# 1. Authenticate. jq builds the body so a quote in a key cannot break out.
TOKEN="$(jq -nc --arg u "$ACCESS_KEY" --arg p "$SECRET_KEY" '{username:$u,password:$p}' \
  | curl "${CURL_OPTS[@]}" -H 'Content-Type: application/json' \
      -X POST "$BASE/api/v1/authenticate" --data @- \
  | jq -r '.token // ""')" || fail "authentication failed against $BASE"
[ -n "$TOKEN" ] || fail "authentication returned no token — check credentials and that console_url includes any required path segment"

printf 'Authorization: Bearer %s\n' "$TOKEN" > "$TMP/auth.hdr"
chmod 600 "$TMP/auth.hdr"
AUTH=(-H "@$TMP/auth.hdr")

# ------------------------------------------------------------------
# 2. Validate the collection name BEFORE using it as a filter.
#
# The filter is exact-match and case-sensitive, and a name that matches nothing
# returns 0 rather than an error. Verified:
#     "Pramm_compute_RBAC - Access Group (RBAC)"  -> 36
#     same string lowercased                      -> 0
#     "Pramm_compute_RBAC" (partial)              -> 0
#
# Zero is also a legitimate answer for a real, quiet collection. Without this
# lookup the two are indistinguishable and a typo reads as "all clear".
# ------------------------------------------------------------------
curl "${CURL_OPTS[@]}" "${AUTH[@]}" -X GET "$BASE/api/v1/collections" > "$TMP/collections.json" \
  || fail "could not list Compute collections"

COLLECTION_EXISTS="$(jq -r --arg n "$COLLECTION" '[.[] | select(.name == $n)] | length' "$TMP/collections.json")"
if [ "$COLLECTION_EXISTS" -eq 0 ]; then
  SUGGESTION="$(jq -r --arg n "$COLLECTION" '
      [ .[].name | select(ascii_downcase == ($n | ascii_downcase)) ] | first // ""
    ' "$TMP/collections.json")"
  if [ -n "$SUGGESTION" ]; then
    fail "no Compute collection named '$COLLECTION' — the filter is case-sensitive; did you mean '$SUGGESTION'?"
  fi
  fail "no Compute collection named '$COLLECTION' exists in this tenant. Refusing to continue: the filter matches nothing, which would report 0 findings and read as a clean bill of health."
fi

# `count_for <endpoint> [extra curl args...]` — read Total-Count without pulling
# any bodies. The header is authoritative and costs one row.
count_for() {
  local ep="$1"; shift
  curl "${CURL_OPTS[@]}" "${AUTH[@]}" -D "$TMP/h.txt" -o /dev/null -G "$BASE/api/v1/$ep" \
    "$@" --data-urlencode 'limit=1' >/dev/null || fail "request to $ep failed"
  awk -F': ' 'tolower($1) ~ /^total-count$/ {gsub(/\r/,"",$2); print $2}' "$TMP/h.txt"
}

# ------------------------------------------------------------------
# 3. Baseline, then scoped counts.
#
# GUARD: the parameter is PLURAL — `collections`. The singular `collection` is
# silently ignored and returns the full unfiltered set (verified: 14,409 for a
# name that does not exist). A silently-dropped filter is indistinguishable from
# a genuinely tenant-sized collection by looking at the number alone, so the
# baseline is fetched and compared below rather than assumed.
# ------------------------------------------------------------------
INCIDENTS_TENANT="$(count_for audits/incidents)"
INCIDENTS="$(count_for audits/incidents --data-urlencode "collections=$COLLECTION")"
IMAGES_TENANT="$(count_for images)"
IMAGES="$(count_for images --data-urlencode "collections=$COLLECTION")"

INCIDENTS_TENANT="${INCIDENTS_TENANT:-0}"; INCIDENTS="${INCIDENTS:-0}"
IMAGES_TENANT="${IMAGES_TENANT:-0}";       IMAGES="${IMAGES:-0}"

# A scoped count identical to the tenant-wide count is the signature of a
# dropped filter. It CAN legitimately happen (a collection selecting everything,
# e.g. "All"), so this is reported as an advisory flag rather than a failure —
# the caller decides. Both being 0 is not suspicious, just an empty tenant.
SUSPECT_UNFILTERED=false
if { [ "$INCIDENTS" -eq "$INCIDENTS_TENANT" ] && [ "$INCIDENTS_TENANT" -gt 0 ]; } \
|| { [ "$IMAGES" -eq "$IMAGES_TENANT" ] && [ "$IMAGES_TENANT" -gt 0 ]; }; then
  SUSPECT_UNFILTERED=true
fi

# ------------------------------------------------------------------
# 4. Unacknowledged incidents.
#
# GUARD: `acknowledged` is validated, not passed through. An unrecognised VALUE
# is not rejected — `acknowledged=garbage` returns the same rows as
# `acknowledged=true` (86 vs 86 measured), so a typo would silently invert the
# meaning of this number. Only the two literals are ever sent.
# ------------------------------------------------------------------
INCIDENTS_UNACKED="$(count_for audits/incidents \
  --data-urlencode "collections=$COLLECTION" \
  --data-urlencode 'acknowledged=false')"
INCIDENTS_UNACKED="${INCIDENTS_UNACKED:-0}"

# ------------------------------------------------------------------
# 5. Image vulnerability rollup.
#
# WHY NOT /api/v1/stats/vulnerabilities: it looks perfect — it returns exactly
# the critical/high/medium/low counts we want in one call. It is unusable here
# for two measured reasons:
#   1. STALE. Its `_id` is a date; this tenant served 2026-07-13 on 2026-08-11,
#      a month behind.
#   2. WRONG WHEN SCOPED. For a collection with 38 real critical CVE instances
#      it returned all zeros, while the unfiltered call returned 166 critical.
#      A false "all clear" is the worst possible failure for this module.
#
# So counts are summed from /api/v1/images, which is ground truth.
#
# VOLUME: a page of 100 images is ~48 MB — the response embeds full package and
# CVE listings. Reducing per page to {id, distribution} takes that to ~14 KB
# (measured 47,965,863 -> 14,260 bytes). The full payload is never accumulated,
# and never reaches Terraform.
#
# `limit` is capped at 100 by the API (limit=500 -> HTTP 400, no partial data).
# ------------------------------------------------------------------
PAGE_SIZE=100
[ "$MAX_IMAGES" -lt "$PAGE_SIZE" ] && PAGE_SIZE="$MAX_IMAGES"

: > "$TMP/dist.ndjson"
OFFSET=0
FETCHED=0
IMAGES_STOP_REASON="complete"

while [ "$FETCHED" -lt "$IMAGES" ] && [ "$FETCHED" -lt "$MAX_IMAGES" ]; do
  REMAINING=$((MAX_IMAGES - FETCHED))
  THIS_PAGE="$PAGE_SIZE"
  [ "$REMAINING" -lt "$THIS_PAGE" ] && THIS_PAGE="$REMAINING"

  curl "${CURL_OPTS[@]}" "${AUTH[@]}" -G "$BASE/api/v1/images" \
    --data-urlencode "collections=$COLLECTION" \
    --data-urlencode "limit=$THIS_PAGE" \
    --data-urlencode "offset=$OFFSET" > "$TMP/page.json" \
    || fail "image query failed at offset $OFFSET"

  GOT="$(jq 'length' "$TMP/page.json")"
  if [ "$GOT" -eq 0 ]; then
    # An empty page before reaching the expected total means we are missing
    # rows for a reason that is NOT the cap. Do not report it as complete.
    [ "$FETCHED" -lt "$IMAGES" ] && IMAGES_STOP_REASON="empty_page"
    break
  fi

  # Reduce HERE, per page, so the ~48 MB body is discarded immediately.
  jq -c '.[] | (.vulnerabilityDistribution // {}) | {
      critical: (.critical // 0),
      high:     (.high     // 0),
      medium:   (.medium   // 0),
      low:      (.low      // 0)
    }' "$TMP/page.json" >> "$TMP/dist.ndjson"

  FETCHED=$((FETCHED + GOT))
  OFFSET=$((OFFSET + GOT))
done

if [ "$FETCHED" -lt "$IMAGES" ] && [ "$IMAGES_STOP_REASON" = "complete" ]; then
  IMAGES_STOP_REASON="cap"
fi

if [ -s "$TMP/dist.ndjson" ]; then
  VULNS="$(jq -s '{
      critical: (map(.critical) | add // 0),
      high:     (map(.high)     | add // 0),
      medium:   (map(.medium)   | add // 0),
      low:      (map(.low)      | add // 0)
    }' "$TMP/dist.ndjson")" || fail "failed to aggregate image vulnerability counts"
else
  VULNS='{"critical":0,"high":0,"medium":0,"low":0}'
fi

# ------------------------------------------------------------------
# 6. Emit. `data "external"` requires a FLAT map of STRINGS — nested objects or
# raw numbers make Terraform fail with "Unexpected value for key". Numbers are
# stringified here and converted back by the module.
# ------------------------------------------------------------------
jq -n \
  --arg collection        "$COLLECTION" \
  --arg incidents         "$INCIDENTS" \
  --arg incidents_unacked "$INCIDENTS_UNACKED" \
  --arg incidents_tenant  "$INCIDENTS_TENANT" \
  --arg images            "$IMAGES" \
  --arg images_tenant     "$IMAGES_TENANT" \
  --arg images_scanned    "$FETCHED" \
  --arg images_stop       "$IMAGES_STOP_REASON" \
  --arg suspect           "$SUSPECT_UNFILTERED" \
  --argjson v             "$VULNS" \
  '{
     collection:          $collection,
     incidents:           $incidents,
     incidents_unacked:   $incidents_unacked,
     incidents_tenant:    $incidents_tenant,
     images:              $images,
     images_tenant:       $images_tenant,
     images_scanned:      $images_scanned,
     images_complete:     (if $images_stop == "complete" then "true" else "false" end),
     images_stop_reason:  $images_stop,
     vuln_critical:       ($v.critical | tostring),
     vuln_high:           ($v.high     | tostring),
     vuln_medium:         ($v.medium   | tostring),
     vuln_low:            ($v.low      | tostring),
     suspect_unfiltered:  $suspect
   }'
