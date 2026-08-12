#!/usr/bin/env bash
#
# runtime-grace-digest — which runtime rules are STILL FIRING?
#
# Reads promoted `workload_incident` CSPM alerts, groups them by the runtime
# rule that produced them, and reports how many fired inside a window.
#
# READ-ONLY. Every call is a GET or a search POST, plus the POST /login
# handshake. Nothing in this script writes to the tenant.
#
# ---------------------------------------------------------------------------
# WHY RECURRENCE AND NOT AGE
# ---------------------------------------------------------------------------
# The original ask was "escalate if unresolved for 14 days". That is coherent
# for a vulnerability — the CVE is present until patched — but not for a
# runtime finding. A runtime incident is a timestamped EVENT: it happened, and
# no API call makes it un-happen. There is no "resolved" state to age against,
# and incidents never expire out of the store, so "older than N days" trends
# toward *everything ever recorded*. Measured in the reference tenant: 14,398
# of 14,410 incidents were already older than 14 days.
#
# Age therefore measures whether anyone clicked acknowledge — not whether the
# risk persists. This script asks the answerable question instead: which rules
# are STILL producing incidents? A fixed workload stops firing, so the signal
# clears itself.
#
# ---------------------------------------------------------------------------
# WHY THE PROMOTED CSPM ALERT AND NOT THE RAW COMPUTE INCIDENT
# ---------------------------------------------------------------------------
# Compute runtime incidents are promoted into CSPM as `workload_incident`
# alerts. The promoted copy is strictly better for this purpose:
#
#   * It carries `metadata.auditRuleName` — the runtime rule (50/50 sampled).
#     NOTE: CSPM renames the field. It is `ruleName` on a Compute incident and
#     `auditRuleName` under `metadata` here. Searching for the Compute name at
#     the top level finds nothing and looks like an absent field.
#   * It carries `metadata.auditCount` — occurrences.
#   * It has the full CSPM lifecycle (dismissedBy / dismissalNote /
#     dismissalUntilTs / history), so "who accepted this risk, and why?" is
#     answerable. On a raw Compute incident it is not: `acknowledged` is the
#     only state field, it records no actor, note or expiry, and `acknowledge`
#     is the ONLY write route that exists (no dismiss/resolve/archive/note).
#   * It is the same API and auth path as the alert-summary module.
#
# Promotion is one-to-one, not aggregation: `auditCount` was 1 on 99 of 100
# sampled alerts.
#
# ---------------------------------------------------------------------------
# CONTRACT (Terraform external data source)
# ---------------------------------------------------------------------------
# stdin : {"cspm_url","access_key","secret_key","window_days","max_alerts",
#          "alert_status"}
# stdout: a FLAT MAP OF STRINGS (the external provider rejects anything else),
#         so the grouped table is returned as a JSON string in `rules_json`.
#
set -euo pipefail

fail() { echo "$*" >&2; exit 1; }

command -v jq   >/dev/null 2>&1 || fail "jq is required"
command -v curl >/dev/null 2>&1 || fail "curl is required"

INPUT="$(cat)"
[ -n "$INPUT" ] || fail "no input on stdin"

CSPM_URL="$(jq -r '.cspm_url     // ""' <<<"$INPUT")"
ACCESS_KEY="$(jq -r '.access_key // ""' <<<"$INPUT")"
SECRET_KEY="$(jq -r '.secret_key // ""' <<<"$INPUT")"
WINDOW_DAYS="$(jq -r '.window_days  // "14"'   <<<"$INPUT")"
MAX_ALERTS="$(jq -r '.max_alerts   // "2000"'  <<<"$INPUT")"
ALERT_STATUS="$(jq -r '.alert_status // "open"' <<<"$INPUT")"

[ -n "$CSPM_URL" ]   && [ "$CSPM_URL" != "null" ]   || fail "cspm_url is empty"
[ -n "$ACCESS_KEY" ] && [ "$ACCESS_KEY" != "null" ] || fail "access_key is empty"
[ -n "$SECRET_KEY" ] && [ "$SECRET_KEY" != "null" ] || fail "secret_key is empty"

case "$WINDOW_DAYS" in ''|*[!0-9]*) fail "window_days must be a positive integer, got '$WINDOW_DAYS'";; esac
case "$MAX_ALERTS"  in ''|*[!0-9]*) fail "max_alerts must be a positive integer, got '$MAX_ALERTS'";;  esac
[ "$WINDOW_DAYS" -ge 1 ] || fail "window_days must be at least 1"
[ "$MAX_ALERTS"  -ge 1 ] || fail "max_alerts must be at least 1"

# Guard the status too: an unrecognised value would be rejected by the API,
# but naming the valid set gives a better error than a 400 would.
case "$ALERT_STATUS" in
  open|resolved|dismissed|snoozed) ;;
  *) fail "alert_status must be one of open|resolved|dismissed|snoozed, got '$ALERT_STATUS'" ;;
esac

BASE="https://${CSPM_URL#https://}"

# Credentials never touch argv — `ps` on a shared runner would show them.
# The token goes to a 0700 file passed with -H @file; the login body is piped.
TMP="$(mktemp -d)"
chmod 700 "$TMP"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

CURL_OPTS=(--silent --show-error --fail-with-body --max-time 120)

TOKEN="$(jq -nc --arg u "$ACCESS_KEY" --arg p "$SECRET_KEY" '{username:$u,password:$p}' \
  | curl "${CURL_OPTS[@]}" -H 'Content-Type: application/json' \
      -X POST "$BASE/login" --data @- | jq -r '.token // ""')" \
  || fail "authentication request failed against $BASE"

[ -n "$TOKEN" ] || fail "authentication returned no token — check the access key and secret"

printf 'x-redlock-auth: %s\n' "$TOKEN" > "$TMP/auth.hdr"
chmod 600 "$TMP/auth.hdr"

# ---------------------------------------------------------------------------
# search — POST a v2/alert query and return the raw response.
#
# TRAP, VERIFIED: an unrecognised FILTER NAME is silently ignored and the API
# returns HTTP 200 with the entire tenant — 18,351,682 rows, identical to
# sending no filters at all. An unrecognised filter VALUE fails closed (0).
# So a plausible-looking number is not evidence the filter applied. The
# baseline assertion below is what actually catches this.
# ---------------------------------------------------------------------------
search() {
  printf '%s' "$1" \
    | curl "${CURL_OPTS[@]}" -X POST "$BASE/v2/alert" \
        -H @"$TMP/auth.hdr" -H 'Content-Type: application/json' --data @-
}

query_body() { # $1 = limit, $2 = timeRange object
  jq -nc \
    --argjson limit "$1" \
    --argjson tr "$2" \
    --arg status "$ALERT_STATUS" \
    '{
       timeRange: $tr,
       filters: [
         {name:"policy.type",   operator:"=", value:"workload_incident"},
         {name:"alert.status",  operator:"=", value:$status}
       ],
       limit: $limit,
       detailed: true
     }'
}

WINDOW_TR="$(jq -nc --argjson d "$WINDOW_DAYS" '{type:"relative",value:{amount:$d,unit:"day"}}')"
ALLTIME_TR='{"type":"to_now","value":"epoch"}'

# ---------------------------------------------------------------------------
# Baseline assertion.
#
# `detailed=true` is REQUIRED for totalRows — without it the field is 0, which
# would read as "no findings".
# ---------------------------------------------------------------------------
ALLTIME_JSON="$(search "$(query_body 1 "$ALLTIME_TR")")" || fail "alert search failed (all-time baseline)"
TOTAL_ALLTIME="$(jq -r '.totalRows // 0' <<<"$ALLTIME_JSON")"

WINDOW_JSON="$(search "$(query_body 1 "$WINDOW_TR")")" || fail "alert search failed (window)"
TOTAL_WINDOW="$(jq -r '.totalRows // 0' <<<"$WINDOW_JSON")"

# If the window did not reduce the set, the time filter may not have applied —
# the same silent-ignore class as the filter-name trap.
#
# The window has to be genuinely SHORT for equality to be suspicious. A long
# window legitimately covers every alert the tenant has, and flagging that
# would be a false alarm that trains readers to ignore the warning. Caught in
# testing: a 3000-day window returned all 111 alerts and was wrongly flagged.
SUSPECT_WINDOW_DAYS=90
SUSPECT_UNFILTERED=false
if [ "$TOTAL_ALLTIME" -gt 0 ] \
   && [ "$TOTAL_WINDOW" -eq "$TOTAL_ALLTIME" ] \
   && [ "$WINDOW_DAYS" -le "$SUSPECT_WINDOW_DAYS" ]; then
  SUSPECT_UNFILTERED=true
fi

# ---------------------------------------------------------------------------
# Fetch the window and reduce.
#
# Only the handful of fields the digest needs are kept. The full alert carries
# a large `resource` object; dropping it early keeps this safe to hold in a
# shell variable and to hand back through a Terraform data source.
# ---------------------------------------------------------------------------
FETCH_LIMIT="$MAX_ALERTS"
[ "$FETCH_LIMIT" -gt 10000 ] && FETCH_LIMIT=10000

ROWS_JSON="$(search "$(query_body "$FETCH_LIMIT" "$WINDOW_TR")")" || fail "alert search failed (detail fetch)"

# `scope` is derived from `policy.name`, NOT from `metadata.auditType`.
#
# VERIFIED: auditType is the audit KIND (Filesystem / Network / Processes) and
# says nothing about which runtime policy owns the rule. The container-vs-host
# split lives only in policy.name — "Container workloads detected with Runtime
# Incidents" vs "Host workloads detected with Runtime Incidents".
#
# This matters because a rule name can exist in BOTH policies, so grouping
# without the scope would merge two different rules into one row and point any
# later escalation at the wrong policy.
REDUCED="$(jq -c '[ .items[]? | {
    rule:     (.metadata.auditRuleName // "(unnamed)"),
    scope:    (
                 (.policy.name // "") as $p
                 | if   ($p | test("(?i)container")) then "container"
                   elif ($p | test("(?i)host"))      then "host"
                   else "unknown" end
              ),
    kind:     (.metadata.auditType     // "unknown"),
    category: (.metadata.incidentCategory // "unknown"),
    account:  (.resource.account       // "(no account)"),
    count:    (.metadata.auditCount    // 1),
    last:     (.metadata.lastIncidentTime // .alertTime // 0)
  } ]' <<<"$ROWS_JSON")"

FETCHED="$(jq -r 'length' <<<"$REDUCED")"

# `limit` is a cap, not a page size — when it is hit the rest is simply absent.
# Say so, rather than presenting a partial table as the whole picture.
COMPLETE=true
if [ "$TOTAL_WINDOW" -gt "$FETCHED" ]; then COMPLETE=false; fi

# ---------------------------------------------------------------------------
# Group by rule + scope + account.
#
# SCOPE IS PART OF THE KEY ON PURPOSE. A rule name can exist in both the
# container and host runtime policies — `OT-WildFire-Demo-Rule` is a real
# example in the reference tenant. Keying on the name alone would merge two
# distinct rules into one row.
#
# `.collections` is deliberately NOT used as a routing key: it lists every
# collection the resource matches (averaging 168 entries), so routing on it
# would notify everyone.
#
# The NUL separator prevents a rule name containing the delimiter from
# colliding with a different rule/account pair.
# ---------------------------------------------------------------------------
GROUPED="$(jq -c '
  group_by(.rule + "\u0000" + .scope + "\u0000" + .account)
  | map({
      rule:       .[0].rule,
      scope:      .[0].scope,
      account:    .[0].account,
      alerts:     length,
      occurrences: (map(.count) | add),
      kinds:      (map(.kind)     | unique | join(", ")),
      categories: (map(.category) | unique | join(", ")),
      last:       (map(.last) | max)
    })
  | sort_by(-.occurrences, -.alerts)
' <<<"$REDUCED")"

DISTINCT_RULES="$(jq -r '[.[].rule] | unique | length' <<<"$GROUPED")"
DISTINCT_GROUPS="$(jq -r 'length' <<<"$GROUPED")"
TOTAL_OCCURRENCES="$(jq -r '[.[].occurrences] | add // 0' <<<"$GROUPED")"

# `default` is not one of the named runtime rules — it appears to be the
# built-in learned model. It cannot be escalated by name, so it is counted
# separately rather than presented as an actionable row.
UNNAMED_RULE_ALERTS="$(jq -r '[.[] | select(.rule == "default" or .rule == "(unnamed)") | .alerts] | add // 0' <<<"$GROUPED")"

jq -nc \
  --arg window_days       "$WINDOW_DAYS" \
  --arg alert_status      "$ALERT_STATUS" \
  --arg alerts_in_window  "$TOTAL_WINDOW" \
  --arg alerts_all_time   "$TOTAL_ALLTIME" \
  --arg alerts_fetched    "$FETCHED" \
  --arg complete          "$COMPLETE" \
  --arg suspect_unfiltered "$SUSPECT_UNFILTERED" \
  --arg distinct_rules    "$DISTINCT_RULES" \
  --arg distinct_groups   "$DISTINCT_GROUPS" \
  --arg occurrences       "$TOTAL_OCCURRENCES" \
  --arg unnamed_rule_alerts "$UNNAMED_RULE_ALERTS" \
  --arg rules_json        "$GROUPED" \
  '$ARGS.named'
