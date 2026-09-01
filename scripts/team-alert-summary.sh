#!/usr/bin/env bash
#
# team-alert-summary.sh — count Prisma Cloud alerts attributed to one team
# (user role), over a relative lookback window, broken down by category, with
# a per-alert CSV of the matched alerts.
#
# Standalone bash equivalent of .github/workflows/team-alert-summary.yml -
# kept in sync manually. Writes alerts-runtime_<role>_<YYYYMMDD>.csv to the
# current directory (or -o's argument, if given).
#
# Required env vars:
#   PRISMA_API_URL     Prisma Cloud API URL (e.g. api2.prismacloud.io)
#   PRISMA_ACCESS_KEY   Prisma Cloud access key id
#   PRISMA_SECRET_KEY   Prisma Cloud secret key
#   ROLE_NAME    Team name — must match a User Role's "name" field exactly
#   DAYS         Lookback window in days, relative to now
#
# Optional:
#   -v flag or DEBUG=1/true env var — verbose per-alert attribution tracing
#   -o <file>    override the output CSV filename
#   -R           resolve the team name from ROLE_NAME's leading acronym
#                (substring up to the first hyphen, uppercased - e.g.
#                "sdp-readonly-role" -> "SDP") and use it in print statements
#                and the CSV filename instead of the raw role name. Off by
#                default.
#
# ATTRIBUTION MODEL — why this needs 4 API calls PER ALERT instead of 1:
# "Which team owns this alert" is not a field on the alert; it is derived by
# walking a chain of IDs:
#   alert.alertRules[].policyScanConfigId
#     -> alert rule.target.includedResourceLists.computeAccessGroupIds[]
#       -> user role.resourceListIds[]  (the role's name IS the team)
# Every /alert and /v2/alert LIST endpoint explicitly omits alertRules
# (per the OpenAPI spec); only the single-alert "Alert Info" endpoint
# populates it. That is the whole reason for the per-alert loop below.
#
# CATEGORY BREAKDOWN: `metadata` on AlertModel is an untyped free-form object
# (no fixed schema) - incidentCategory/auditType/auditAttackTechniques are
# populated only for certain alert types (e.g. UEBA/audit-event alerts) and
# are absent/null otherwise. `policy.policyType` is always present. All four
# are read from the same Alert Info response already fetched for attribution,
# so this adds zero extra API calls. Breakdown is scoped to alerts matched to
# the team (not the whole window) - the point of this script is per-team
# reporting, and counting unmatched alerts would mix in other teams' data.

set -euo pipefail

fail() { echo "ERROR: $1" >&2; exit 1; }

# DEBUG can arrive pre-set via env (DEBUG=1 ./script.sh) or via -v below.
DEBUG="${DEBUG:-false}"

# No `&&`/`||` one-liner here - under `set -e`, a bare compound whose last
# evaluated command fails (i.e. debug logging is off) would abort the script.
debug() {
  if [ "$DEBUG" = "true" ] || [ "$DEBUG" = "1" ]; then
    echo "DEBUG: $1" >&2
  fi
}

OUTPUT_FILE=""
RESOLVE_TEAM_NAME=false
while getopts "vo:R" opt; do
  case "$opt" in
    v) DEBUG=true ;;
    o) OUTPUT_FILE="$OPTARG" ;;
    R) RESOLVE_TEAM_NAME=true ;;
    *) fail "usage: $0 [-v] [-o output_file] [-R]" ;;
  esac
done
shift $((OPTIND - 1))

command -v jq   >/dev/null 2>&1 || fail "jq is required but not found"
command -v curl >/dev/null 2>&1 || fail "curl is required but not found"


PRISMA_API_URL="https://api.gov.prismacloud.io"
PRISMA_ACCESS_KEY="339bc484-cdf1-4f84-aa7b-dc8948eaf26a"
PRISMA_SECRET_KEY="4o/8Dx/VKy2Kvel3t9c2uWEfnQc="
ROLE_NAME="sdp-readonly-role"
#ROLE_NAME="fsc-readonly-role"
#ROLE_NAME="dtc-role"
DAYS=1

: "${PRISMA_API_URL:?PRISMA_API_URL is required}"
: "${PRISMA_ACCESS_KEY:?PRISMA_ACCESS_KEY is required}"
: "${PRISMA_SECRET_KEY:?PRISMA_SECRET_KEY is required}"
: "${ROLE_NAME:?ROLE_NAME is required}"
: "${DAYS:?DAYS is required}"

case "$DAYS" in
  ''|*[!0-9]*) fail "DAYS must be a positive integer, got '$DAYS'" ;;
esac
[ "$DAYS" -gt 0 ] || fail "DAYS must be greater than zero"

if [ "$RESOLVE_TEAM_NAME" = "true" ]; then
  TEAM_NAME="$(printf '%s' "${ROLE_NAME%%-*}" | tr '[:lower:]' '[:upper:]')"
else
  TEAM_NAME="$ROLE_NAME"
fi

BASE="${PRISMA_API_URL}"

CURL_OPTS=(--silent --show-error --fail-with-body)

# create temporary working directory
TMP="$(mktemp -d)"
chmod 700 "$TMP"
trap 'rm -rf "$TMP"' EXIT

# authenticate to Prisma Cloud via /login endpoint and save the JWT in the response
TOKEN="$(jq -nc --arg u "$PRISMA_ACCESS_KEY" --arg p "$PRISMA_SECRET_KEY" '{username:$u,password:$p}' \
  | curl "${CURL_OPTS[@]}" -H 'Content-Type: application/json' \
      -X POST "$BASE/login" --data @- \
  | jq -r '.token // ""')" || fail "authentication failed against $BASE"
[ -n "$TOKEN" ] || fail "authentication returned no token - check credentials"

# propogate token to x-redlock-auth header
printf 'x-redlock-auth: %s\n' "$TOKEN" > "$TMP/auth.hdr"
chmod 600 "$TMP/auth.hdr"
AUTH=(-H "@$TMP/auth.hdr")

# calculate start/end datetimes
WINDOW_END="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if date -u -d "-$DAYS days" +%Y-%m-%dT%H:%M:%SZ >/dev/null 2>&1; then
  WINDOW_START="$(date -u -d "-$DAYS days" +%Y-%m-%dT%H:%M:%SZ)"
else
  WINDOW_START="$(date -u -v-"${DAYS}"d +%Y-%m-%dT%H:%M:%SZ)"
fi

echo "==> Fetching alerts from the last $DAYS day(s)..." >&2
echo "      Start time: $WINDOW_START" >&2
echo "      End time: $WINDOW_END" >&2

# fetch alerts within time range and save to temp file
: > "$TMP/alert_ids.txt"
PAGE_TOKEN=""
while :; do
  PAGE_ARGS=(-G "$BASE/v2/alert"
    --data-urlencode "timeType=relative"
    --data-urlencode "timeAmount=$DAYS"
    --data-urlencode "timeUnit=day"
    --data-urlencode "detailed=false"
    --data-urlencode "fields=alert.id"
    --data-urlencode "limit=10000")
  [ -n "$PAGE_TOKEN" ] && PAGE_ARGS+=(--data-urlencode "pageToken=$PAGE_TOKEN")

  curl "${CURL_OPTS[@]}" "${AUTH[@]}" "${PAGE_ARGS[@]}" > "$TMP/page.json" \
    || fail "alert list query failed"

  jq -r '(.items // [])[].id // empty' "$TMP/page.json" >> "$TMP/alert_ids.txt"

  PAGE_TOKEN="$(jq -r '.nextPageToken // empty' "$TMP/page.json")"
  [ -n "$PAGE_TOKEN" ] || break
done

# calculate total alerts
TOTAL_ALERTS="$(wc -l < "$TMP/alert_ids.txt" | tr -d ' ')"

# exit early if no alerts returned
if [ "$TOTAL_ALERTS" -eq 0 ]; then
  echo "No alerts found in the last $DAYS day(s). Nothing to attribute - exiting."
  exit 0
fi

echo "==> Found $TOTAL_ALERTS alert(s). Fetching alert rules and user roles..." >&2

# fetch alert rules and save to temp file
curl "${CURL_OPTS[@]}" "${AUTH[@]}" -X GET "$BASE/v2/alert/rule" > "$TMP/alert_rules.json" \
  || fail "could not list alert rules"

# fetch user roles and save to temp file
curl "${CURL_OPTS[@]}" "${AUTH[@]}" -X GET "$BASE/user/role" > "$TMP/user_roles.json" \
  || fail "could not list user roles"

# confirm target role exists in the tenant, exiting early if not
ROLE_EXISTS="$(jq -r --arg n "$ROLE_NAME" '[.[] | select(.name == $n)] | length' "$TMP/user_roles.json")"
if [ "$ROLE_EXISTS" -eq 0 ]; then
  SUGGESTION="$(jq -r --arg n "$ROLE_NAME" '[.[].name | select(ascii_downcase == ($n | ascii_downcase))] | first // ""' "$TMP/user_roles.json")"
  if [ -n "$SUGGESTION" ]; then
    fail "no user role named '$ROLE_NAME' - did you mean '$SUGGESTION'?"
  fi
  fail "no user role named '$ROLE_NAME' exists in this tenant"
fi

echo "==> Attributing alerts to role '$TEAM_NAME'..." >&2

: > "$TMP/matched_alert_ids.txt"
: > "$TMP/matched_categories.ndjson"
: > "$TMP/matched_rows.ndjson"
CHECKED=0

# iterate over list of alerts, fetching the details for each
while IFS= read -r ALERT_ID; do
  [ -n "$ALERT_ID" ] || continue

  debug "[$ALERT_ID] fetching Alert Info"

  # respect 5 req/sec, 10 req/sec burst rate limit
  sleep 0.21

  curl "${CURL_OPTS[@]}" "${AUTH[@]}" -X GET "$BASE/alert/$ALERT_ID?detailed=false" > "$TMP/alert.json" \
    || fail "Alert Info request failed for $ALERT_ID"

  RULE_IDS="$(jq -c '[(.alertRules // [])[] | .policyScanConfigId // empty] | unique' "$TMP/alert.json")"
  debug "[$ALERT_ID] alert rule ids: $RULE_IDS"
  if [ "$(jq 'length' <<<"$RULE_IDS")" -eq 0 ]; then
    debug "[$ALERT_ID] no alert rules attached - skipping"
    CHECKED=$((CHECKED + 1))
    continue
  fi

  GROUP_IDS="$(jq -c --argjson ids "$RULE_IDS" '
      [ .[] | select(.policyScanConfigId as $rid | ($ids | index($rid)) != null)
        | ((.target.includedResourceLists.computeAccessGroupIds // [])[]) ]
      | unique
    ' "$TMP/alert_rules.json")"
  debug "[$ALERT_ID] compute access group ids: $GROUP_IDS"
  if [ "$(jq 'length' <<<"$GROUP_IDS")" -eq 0 ]; then
    debug "[$ALERT_ID] no compute access groups on the matched rule(s) - skipping"
    CHECKED=$((CHECKED + 1))
    continue
  fi

  MATCHED="$(jq -r --argjson ids "$GROUP_IDS" --arg role "$ROLE_NAME" '
      any(.[]; .name == $role and ((.resourceListIds // []) | any(. as $rl | ($ids | index($rl)) != null)))
    ' "$TMP/user_roles.json")"
  debug "[$ALERT_ID] matched role '$ROLE_NAME': $MATCHED"

  if [ "$MATCHED" = "true" ]; then
    echo "$ALERT_ID" >> "$TMP/matched_alert_ids.txt"

    # save the alert details into temp file for summary at the end
    jq -c '{
        incidentCategory:       (.metadata.incidentCategory // null),
        auditType:              (.metadata.auditType // null),
        auditAttackTechniques:  ((.metadata.auditAttackTechniques // []) | if . == [] then "None" else . end),
        policyType:             (.policy.policyType | if . == "workload_incident" then "Workload Incident" elif . == "workload_vulnerability" then "Workload Vulnerability" else . end // null)
      }' "$TMP/alert.json" >> "$TMP/matched_categories.ndjson"
    debug "[$ALERT_ID] category fields: $(tail -n1 "$TMP/matched_categories.ndjson")"

    # populate details of alert into a new row in the final CSV file
    jq -c '{
        id:                         (.id // ""),
        status:                     (.status // ""),
        firstSeen:                  (.firstSeen // ""),
        lastSeen:                   (.lastSeen // ""),
        alertTime:                  (.alertTime // ""),
        lastUpdated:                (.lastUpdated // ""),
        policyId:                   (.policy.policyId // ""),
        policyType:                 (.policy.policyType // ""),
        resourceId:                 (.resource.id // ""),
        resourceName:               (.resource.name // ""),
        resourceAccountId:          (.resource.accountId // ""),
        resourceRegionId:           (.resource.regionId // ""),
        resourceType:               (.resource.resourceType // ""),
        resourceApiName:            (.resource.resourceApiName // ""),
        resourceCloudServiceName:   (.resource.cloudServiceName // ""),
        resourceUrl:                (.resource.url // ""),
        resourceCloudType:          (.resource.cloudType // ""),
        resourceInternalResourceId: (.resource.internalResourceId // "")
      }' "$TMP/alert.json" >> "$TMP/matched_rows.ndjson"
  fi

  CHECKED=$((CHECKED + 1))
done < "$TMP/alert_ids.txt"

TEAM_COUNT="$(wc -l < "$TMP/matched_alert_ids.txt" | tr -d ' ')"

# print summary
echo
echo "━━━━━━━━━━━ Alert Summary ━━━━━━━━━━━"
echo "Role:             $TEAM_NAME"
echo "Days:             $DAYS"
echo "Total Alerts:     $TOTAL_ALERTS"
echo "Alerts Checked:   $CHECKED"
echo "Alerts For Team:  $TEAM_COUNT"
echo

count_by() {
  jq -s --arg key "$1" '
      group_by(.[$key]) | map({ value: .[0][$key], count: length }) | sort_by(-.count)
    ' "$TMP/matched_categories.ndjson"
}

INCIDENT_CATEGORY_COUNTS='[]'
AUDIT_TYPE_COUNTS='[]'
POLICY_TYPE_COUNTS='[]'
AUDIT_TECHNIQUES_COUNTS='[]'

if [ -s "$TMP/matched_categories.ndjson" ]; then
  INCIDENT_CATEGORY_COUNTS="$(count_by incidentCategory)"
  AUDIT_TYPE_COUNTS="$(count_by auditType)"
  POLICY_TYPE_COUNTS="$(count_by policyType)"

  AUDIT_TECHNIQUES_COUNTS="$(jq -s '
      group_by(.auditAttackTechniques) | map({ value: .[0].auditAttackTechniques, count: length }) | sort_by(-.count)
    ' "$TMP/matched_categories.ndjson")"
fi

print_breakdown() {
  local title="$1" counts="$2"
  echo "┅┅┅ $title ┅┅┅"
  jq -r '.[] | "\(.count)\t\(.value // "null")"' <<<"$counts"
  echo
}

print_breakdown "Incident Category"      "$INCIDENT_CATEGORY_COUNTS"
print_breakdown "Audit Event Type"             "$AUDIT_TYPE_COUNTS"
print_breakdown "Attack Techniques" "$AUDIT_TECHNIQUES_COUNTS"
print_breakdown "Policy Type"     "$POLICY_TYPE_COUNTS"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# set output file name to resolved team name if -R flag is supplied, otherwise use default format
if [ -z "$OUTPUT_FILE" ]; then
  SAFE_TEAM_NAME="$(printf '%s' "$TEAM_NAME" | tr -c 'A-Za-z0-9_-' '_')"
  OUTPUT_FILE="alerts-runtime_${SAFE_TEAM_NAME}_$(date -u +%Y%m%d).csv"
fi

# output CSV file with detailed breakdown for each alert
{
  echo "id,status,firstSeen,lastSeen,alertTime,lastUpdated,policyId,policyType,resourceId,resourceName,resourceAccountId,resourceRegionId,resourceType,resourceApiName,resourceCloudServiceName,resourceUrl,resourceCloudType,resourceInternalResourceId"
  jq -r '[.id,.status,.firstSeen,.lastSeen,.alertTime,.lastUpdated,.policyId,.policyType,.resourceId,.resourceName,.resourceAccountId,.resourceRegionId,.resourceType,.resourceApiName,.resourceCloudServiceName,.resourceUrl,.resourceCloudType,.resourceInternalResourceId] | @csv' "$TMP/matched_rows.ndjson"
} > "$OUTPUT_FILE"

echo
echo "Output detailed results to $OUTPUT_FILE"
