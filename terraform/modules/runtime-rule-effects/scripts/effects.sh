#!/usr/bin/env bash
#
# effects.sh — report the CURRENT ENFORCEMENT EFFECT of Compute runtime rules,
# joined to the promoted CSPM alerts that reference them.
#
# READ-ONLY. Two GETs and one POST-as-query. No write route is reachable from
# this script; the escalator that writes is a separate, gated component.
#
# ---------------------------------------------------------------------------
# WHY THIS EXISTS
#
# Workflow 8 answers "which runtime rules are still firing?" but it cannot say
# whether a firing rule is still merely alerting or has already been escalated
# to prevent/block. It cannot, because VERIFIED: the promoted CSPM alert carries
# NO effect field — 100 sampled alerts, zero `/effect/i` keys at any depth, zero
# prevent|block|disable values anywhere. Enforcement state exists only in the
# Compute Console policy objects, so answering the question requires joining two
# APIs. That join is this script's whole job.
#
# ---------------------------------------------------------------------------
# THERE IS NO SUCH THING AS "THE RULE'S EFFECT"
#
# VERIFIED against the live API: a runtime rule has no rule-level `effect`. A
# container rule carries NINE independent effect sites and a host rule carries a
# different, smaller set. Escalating "a rule" is therefore not a well-formed
# operation — a caller must name the SITE.
#
# This script does NOT infer the site from the alert's auditType. auditType is
# Filesystem|Processes|Network, which looks like it maps onto the sites but does
# not: anti-malware detections also surface as "Filesystem", and the API states
# no such mapping. Guessing it would mean proposing a change to the wrong
# control on a live security policy, so the sites are reported and a human picks.
#
# ---------------------------------------------------------------------------
# Input (stdin, Terraform external data source protocol) — all values STRINGS:
#   {"cspm_url","compute_url","access_key","secret_key",
#    "window_days","alert_status","max_alerts","skip_cert"}
#
# Output (stdout): flat string map. `rules_json` holds the payload.

set -euo pipefail

fail() {
  echo "Error Message: $1" >&2
  exit 1
}

command -v jq   >/dev/null 2>&1 || fail "jq is required but not found"
command -v curl >/dev/null 2>&1 || fail "curl is required but not found"

INPUT="$(cat)"
[ -n "$INPUT" ] || fail "no input received on stdin"

get() { jq -r --arg k "$1" '.[$k] // ""' <<<"$INPUT"; }

CSPM_URL="$(get cspm_url)"
COMPUTE_URL="$(get compute_url)"
ACCESS_KEY="$(get access_key)"
SECRET_KEY="$(get secret_key)"
WINDOW_DAYS="$(get window_days)"
ALERT_STATUS="$(get alert_status)"
MAX_ALERTS="$(get max_alerts)"
SKIP_CERT="$(get skip_cert)"

[ -n "$CSPM_URL" ]    || fail "cspm_url is required"
[ -n "$COMPUTE_URL" ] || fail "compute_url is required"
[ -n "$ACCESS_KEY" ]  || fail "access_key is required"
[ -n "$SECRET_KEY" ]  || fail "secret_key is required"

: "${WINDOW_DAYS:=14}"
: "${ALERT_STATUS:=open}"
: "${MAX_ALERTS:=2000}"

case "$ALERT_STATUS" in
  open|resolved|dismissed|snoozed) ;;
  *) fail "alert_status must be one of open|resolved|dismissed|snoozed, got '$ALERT_STATUS'" ;;
esac
case "$WINDOW_DAYS" in ''|*[!0-9]*) fail "window_days must be a positive integer, got '$WINDOW_DAYS'" ;; esac
case "$MAX_ALERTS"  in ''|*[!0-9]*) fail "max_alerts must be a positive integer, got '$MAX_ALERTS'" ;; esac

# The CSPM host is stored without a scheme in some configs; curl needs one.
case "$CSPM_URL" in http://*|https://*) ;; *) CSPM_URL="https://$CSPM_URL" ;; esac
CSPM_BASE="${CSPM_URL%/}"
COMPUTE_BASE="${COMPUTE_URL%/}"

CURL_OPTS=(--silent --show-error --fail-with-body --max-time 120)
[ "$SKIP_CERT" = "true" ] && CURL_OPTS+=(-k)

# ---------------------------------------------------------------------------
# Credentials never touch argv: anything on a command line is world-readable
# via `ps`. Login bodies go in on stdin (`--data @-`) and tokens are read from
# 0600 files in a 0700 directory (`-H @file`), removed on exit.
# ---------------------------------------------------------------------------
TMP="$(mktemp -d)"
chmod 700 "$TMP"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Authentication.
#
# Each login captures the HTTP status and body SEPARATELY rather than letting
# curl's exit code propagate. With `--fail-with-body` under `set -e`, a 401 or
# 404 kills the pipeline before any `|| fail` can run, so the operator sees a
# bare `curl: (22) ... error: 401` instead of a sentence telling them which
# credential or URL is wrong. Every message below is prefixed "Error Message:"
# because the workflow hoists that line onto the run summary.
# ---------------------------------------------------------------------------

# $1=label  $2=url  $3=out-header-file  $4=header-prefix  $5=jq token path
authenticate() {
  local label="$1" url="$2" out="$3" prefix="$4" tokpath="$5"
  local code

  code="$(jq -nc --arg u "$ACCESS_KEY" --arg p "$SECRET_KEY" '{username:$u,password:$p}' \
    | curl "${CURL_OPTS_NOFAIL[@]}" -H 'Content-Type: application/json' \
        -X POST "$url" --data @- \
        -o "$TMP/auth_body.json" -w '%{http_code}')" \
    || fail "$label authentication could not reach $url - check the URL and network access"

  case "$code" in
    200|201) ;;
    401|403) fail "$label authentication was rejected (HTTP $code) - the access key or secret is wrong, or lacks permission" ;;
    404)     fail "$label authentication got HTTP 404 at $url - the base URL looks wrong. For the Compute console it must INCLUDE the path prefix, e.g. https://<region>.cloud.twistlock.com/<tenant-id>" ;;
    000)     fail "$label authentication timed out or the connection failed against $url" ;;
    *)       fail "$label authentication returned HTTP $code from $url" ;;
  esac

  jq -r --arg pre "$prefix" --arg tp "$tokpath" \
    '$pre + (.[$tp] // "")' "$TMP/auth_body.json" > "$out" 2>/dev/null \
    || fail "$label authentication returned a response that is not JSON"
  chmod 600 "$out"
  rm -f "$TMP/auth_body.json"

  # An empty token is the failure mode a status check cannot catch: a Compute
  # URL missing its path prefix can answer 200 with no token at all.
  grep -q "$prefix.\+" "$out" \
    || fail "$label authentication succeeded but returned an EMPTY token. For the Compute console this usually means the URL is missing its path prefix."
}

# A second option set without --fail-with-body: these calls inspect the status
# code themselves, so curl must not exit non-zero and pre-empt the diagnosis.
CURL_OPTS_NOFAIL=(--silent --show-error --max-time 120)
[ "$SKIP_CERT" = "true" ] && CURL_OPTS_NOFAIL+=(-k)

authenticate "CSPM"    "$CSPM_BASE/login"                  "$TMP/cspm.hdr" "x-redlock-auth: "  "token"
authenticate "Compute" "$COMPUTE_BASE/api/v1/authenticate" "$TMP/cc.hdr"   "Authorization: Bearer " "token"

# ---------------------------------------------------------------------------
# 1. Read both runtime policies.
#
# VERIFIED: container and host are DIFFERENT SHAPES. Host has no processes or
# filesystem sections and no rule-level *Effect keys. Each is normalised
# separately below rather than through one shared path that would invent fields
# on whichever policy lacks them.
# ---------------------------------------------------------------------------
curl "${CURL_OPTS[@]}" -H @"$TMP/cc.hdr" \
  -X GET "$COMPUTE_BASE/api/v1/policies/runtime/container" > "$TMP/container.json" \
  || fail "failed to read the container runtime policy"
curl "${CURL_OPTS[@]}" -H @"$TMP/cc.hdr" \
  -X GET "$COMPUTE_BASE/api/v1/policies/runtime/host" > "$TMP/host.json" \
  || fail "failed to read the host runtime policy"

# Flatten both policies into one addressable list of effect sites.
#
# `site` is the escalation address. It is a literal jq path into the policy
# object, so the escalator can apply a change without re-deriving anything and
# without a lookup table that could drift from this file.
#
# `action` (audit|incident) is carried for customRules because it is the OTHER
# axis: effect controls enforcement, action controls whether the event is logged
# as an audit or an incident. Escalating effect does NOT stop incidents - that
# is why "still firing" cannot discharge an escalation.
jq -n \
  --slurpfile c "$TMP/container.json" \
  --slurpfile h "$TMP/host.json" '
  def sites($kind):
    .rules // []
    | to_entries[]
    | .key as $ri | .value as $r
    | [
        # Rule-level effect keys. Container only - selected by presence, so the
        # host policy simply yields none rather than nulls.
        ( $r | to_entries[]
          | select(.key | test("Effect$"))
          | { site: .key, effect: .value, action: null } ),

        # Section effects. `getpath` returns null for a section the policy kind
        # does not have, and those are dropped.
        ( ["processes","deniedList","effect"],
          ["filesystem","deniedList","effect"],
          ["network","listeningPorts","effect"],
          ["network","outboundPorts","effect"],
          ["dns","domainList","effect"],
          ["antiMalware","deniedProcesses","effect"]
          | . as $p
          | select($r | getpath($p) != null)
          | { site: ($p | join(".")), effect: ($r | getpath($p)), action: null } ),

        # Custom rules are addressed BY INDEX. `_id` is the documented key but
        # reads as null through the policy endpoint, so the index is the only
        # reliable address.
        ( ($r.customRules // []) | to_entries[]
          | { site: ("customRules[" + (.key|tostring) + "].effect"),
              effect: .value.effect,
              action: .value.action } )
      ]
    | { kind: $kind, rule: ($r.name // "(unnamed)"), rule_index: $ri,
        owner: ($r.owner // ""), sites: . };

  [ ($c[0] | sites("container")), ($h[0] | sites("host")) ]
' > "$TMP/rules.json" || fail "failed to normalise the runtime policies"

# ---------------------------------------------------------------------------
# 2. Read promoted alerts for the window.
#
# TRAP, VERIFIED: an unrecognised FILTER NAME is silently ignored - HTTP 200 and
# the entire tenant comes back. An unrecognised filter VALUE fails closed. So a
# plausible number is not evidence the filter applied.
# TRAP: `detailed=true` is REQUIRED for totalRows; without it the field is 0,
# which reads as "no findings".
# ---------------------------------------------------------------------------
jq -nc \
  --argjson days "$WINDOW_DAYS" \
  --argjson limit "$MAX_ALERTS" \
  --arg status "$ALERT_STATUS" '
  { timeRange: { type: "relative", value: { amount: $days, unit: "day" } },
    filters: [
      { name: "policy.type",  operator: "=", value: "workload_incident" },
      { name: "alert.status", operator: "=", value: $status }
    ],
    limit: $limit,
    detailed: true }' \
  | curl "${CURL_OPTS[@]}" -H @"$TMP/cspm.hdr" -H 'Content-Type: application/json' \
      -X POST "$CSPM_BASE/v2/alert" --data @- > "$TMP/alerts.json" \
  || fail "alert search failed"

# ---------------------------------------------------------------------------
# 3. Join alerts to rules by name, and classify every outcome.
#
# ⚠️ RULE NAMES ARE NOT UNIQUE ACROSS POLICIES.
#
# VERIFIED: all 13 distinct rule names across 100 promoted alerts resolve to a
# live rule — but 3 names exist in BOTH the container and host policies, and 2
# of those are actively firing. The alert carries no field saying which policy
# produced it, so those matches cannot be resolved from alert data at all.
#
# The stakes are concrete. `OT-WildFire-Demo-Rule` exists in both, with 8 sites
# in container (mostly `disable`) and 1 in host (`alert`). Guessing would change
# an unrelated control on a live security policy.
#
# An alert can also in principle name a rule that no longer exists (rules carry
# `previousName`, so renames happen). That did not occur in the sample, but it
# is cheap to classify and expensive to discover as a silent drop later.
#
# Every outcome is therefore explicit rather than filtered away:
#
#   matched     - exactly one rule with that name; sites are authoritative
#   ambiguous   - the name exists in both policies; sites shown for each, but
#                 which one produced the alert is NOT knowable from the alert
#   unmatched   - no live rule has this name; nothing to escalate
#   builtin     - the `default` learned model
#
# NOTE on `default`: it is BOTH the built-in learned model's label AND a real
# rule name in this tenant's policy. It is classified `builtin` first because an
# alert attributed to `default` cannot be assumed to come from that rule.
# ---------------------------------------------------------------------------
jq -n \
  --slurpfile rules  "$TMP/rules.json" \
  --slurpfile alerts "$TMP/alerts.json" '
  ($rules[0]) as $rules
  | ($alerts[0].items // []) as $items

  | ( $items
      | group_by(.metadata.auditRuleName // "(unnamed)")
      | map({ rule: (.[0].metadata.auditRuleName // "(unnamed)"),
              alerts: length,
              occurrences: ([.[].metadata.auditCount // 1] | add),
              kinds: ([.[].metadata.auditType // "unknown"] | unique),
              accounts: ([.[].resource.account // "(no account)"] | unique),
              last: ([.[].metadata.lastIncidentTime // .[].alertTime // 0] | max) })
    ) as $byrule

  | [ $byrule[]
      | . as $a
      | ([ $rules[] | select(.rule == $a.rule) ]) as $hits
      | $a + {
          match_status: (
            if   $a.rule == "default"  then "builtin"
            elif ($hits | length) == 0 then "unmatched"
            elif ($hits | length) > 1  then "ambiguous"
            else "matched" end
          ),
          matches: [ $hits[] | { kind, rule_index, owner, sites } ]
        }
    ]
  | sort_by(-.occurrences, -.alerts)
' > "$TMP/joined.json" || fail "failed to join alerts to rules"

# ---------------------------------------------------------------------------
# 4. Emit. Every value is a string: the external data source protocol rejects
#    anything else, and a bare number here fails the whole plan.
# ---------------------------------------------------------------------------
JOINED="$(cat "$TMP/joined.json")"
ALL_RULES="$(cat "$TMP/rules.json")"

counts() { jq -r --arg s "$1" '[.[] | select(.match_status == $s)] | length' <<<"$JOINED"; }

jq -nc \
  --arg window_days   "$WINDOW_DAYS" \
  --arg alert_status  "$ALERT_STATUS" \
  --arg alerts_total  "$(jq -r '(.items // []) | length' "$TMP/alerts.json")" \
  --arg container_rules "$(jq -r '[.[] | select(.kind == "container")] | length' <<<"$ALL_RULES")" \
  --arg host_rules      "$(jq -r '[.[] | select(.kind == "host")] | length' <<<"$ALL_RULES")" \
  --arg firing_rules  "$(jq -r 'length' <<<"$JOINED")" \
  --arg matched       "$(counts matched)" \
  --arg ambiguous     "$(counts ambiguous)" \
  --arg unmatched     "$(counts unmatched)" \
  --arg builtin       "$(counts builtin)" \
  --arg rules_json    "$JOINED" \
  '$ARGS.named'
