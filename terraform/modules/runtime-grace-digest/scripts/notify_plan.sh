#!/usr/bin/env bash
#
# notify_plan.sh — PLAN the grace warning. Does not send anything.
#
# Takes the grouped rule table produced by digest.sh and works out who would be
# warned that a runtime rule is about to be escalated to blocking, how old the
# finding is, and how many days of grace remain.
#
# ---------------------------------------------------------------------------
# THIS SCRIPT CANNOT SEND MAIL. THAT IS THE POINT.
# ---------------------------------------------------------------------------
# There is no SMTP client here, no curl to a webhook, no mail(1). The only
# output is JSON on stdout. Sending is a separate, separately-gated script.
#
# The reason for the split: every other script in this repo has a blast radius
# that stops at the tenant, and the tenant is a sandbox. A wrong PUT is undone
# with another PUT. This data is different — `cloudAccountOwners` holds real,
# live mailboxes of real people, including addresses outside the company. A
# message sent to the wrong person cannot be recalled, and "it was a lab" is
# not a repair. So the addressing logic is built and reviewed FIRST, in a form
# that is physically incapable of contacting anyone.
#
# ---------------------------------------------------------------------------
# THE OVERRIDE RECIPIENT
# ---------------------------------------------------------------------------
# `override_recipient` is REQUIRED. When set, every planned message is
# addressed to it, and the owner addresses derived from the alert are carried
# alongside as `would_notify` — visible for review, never used as a recipient.
#
# This is deliberately not a boolean "dry run" flag. A flag can be flipped by
# accident; a required field that replaces the address means the unreviewed
# path does not exist yet. Removing the override is a code change, not a
# configuration change, and it belongs in the slice that adds sending.
#
# ---------------------------------------------------------------------------
# CONTRACT (Terraform external data source)
# ---------------------------------------------------------------------------
# stdin : {"rules_json","grace_days","override_recipient","now_ms"(optional)}
# stdout: a FLAT MAP OF STRINGS — the external provider rejects anything else.
#
set -euo pipefail

fail() { echo "$*" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || fail "jq is required"

INPUT="$(cat)"
[ -n "$INPUT" ] || fail "no input on stdin"

get() { jq -r --arg k "$1" '.[$k] // ""' <<<"$INPUT"; }

RULES_JSON="$(get rules_json)"
GRACE_DAYS="$(get grace_days)"
OVERRIDE="$(get override_recipient)"
NOW_MS="$(get now_ms)"

[ -n "$RULES_JSON" ] || fail "rules_json is required (the grouped table from digest.sh)"
[ -n "$GRACE_DAYS" ] || fail "grace_days is required"

# The override is what makes this script safe to run against live data. Refuse
# to plan without it rather than defaulting to the real owner addresses.
[ -n "$OVERRIDE" ] || fail \
  "override_recipient is required. This script plans warnings from live owner
 addresses; it will not resolve real recipients until a reviewed send path
 exists. Set override_recipient to your own address."

case "$OVERRIDE" in
  *@*.*) ;;
  *) fail "override_recipient does not look like an email address: $OVERRIDE" ;;
esac

case "$GRACE_DAYS" in
  ''|*[!0-9]*) fail "grace_days must be a whole number of days, got: $GRACE_DAYS" ;;
esac

# `now` is injectable so the age arithmetic is testable against a fixed clock.
# Without this every assertion about "days remaining" would drift daily.
if [ -z "$NOW_MS" ]; then NOW_MS="$(( $(date +%s) * 1000 ))"; fi
case "$NOW_MS" in
  ''|*[!0-9]*) fail "now_ms must be epoch milliseconds, got: $NOW_MS" ;;
esac

echo "$RULES_JSON" | jq -e 'type == "array"' >/dev/null 2>&1 \
  || fail "rules_json must be a JSON array"

# ---------------------------------------------------------------------------
# Plan.
#
# Only groups with at least one OPEN alert are candidates: resolved, dismissed
# and snoozed alerts all stop the clock, so warning about them would be noise.
# The clock runs from `open_first` (the earliest alertTime among the open
# members), NOT `first`, which spans every status — a rule whose old alerts
# were all dismissed plus one fresh open alert must not read as aged.
#
# ---------------------------------------------------------------------------
# TWO THINGS THIS PLAN SURFACES THAT A SEND PATH MUST HANDLE FIRST
# ---------------------------------------------------------------------------
# Measured on the reference tenant at a 14-day grace: 19 groups planned, ALL 19
# already overdue, 9 unroutable, 8 distinct people, one group addressing 5.
#
# 1. `default` IS NOT ESCALATABLE, BUT IT DOMINATES THE OVERDUE LIST.
#    6 of the 19 planned groups are the `default` rule — the built-in learned
#    model, not a named rule. digest.sh already excludes it from
#    `actionable_rules` precisely because it cannot be escalated by name. So a
#    warning about it threatens a consequence that cannot be delivered, and
#    tells the recipient to fix something they cannot address. Those groups are
#    still PLANNED here (dropping them silently would hide 6 aged findings),
#    but they are flagged `escalatable: false` and a send path must not mail
#    them until there is a real remediation instruction to give.
#
# 2. THE CLOCK ALREADY EXPIRED FOR EVERYONE.
#    Every planned group is past 14 days — the oldest by 368. A first run would
#    therefore be a "your grace period ended long ago" notice to 8 people at
#    once, which is not a warning, it is an ambush. A grace period has to start
#    when it is ANNOUNCED, not backdated to the alert. Whoever wires the send
#    path needs a campaign start date, so the countdown is measured from first
#    contact.
# ---------------------------------------------------------------------------
PLANNED="$(jq -c \
  --argjson now "$NOW_MS" \
  --argjson grace "$GRACE_DAYS" \
  --arg override "$OVERRIDE" '
  [ .[]
    | select(.open_alerts > 0 and .open_first > 0)
    | ((($now - .open_first) / 86400000) | floor) as $age
    | {
        rule:        .rule,
        scope:       .scope,
        account:     .account,
        clusters:    (.clusters // []),
        open_alerts: .open_alerts,
        occurrences: .occurrences,
        age_days:    $age,
        days_remaining: ($grace - $age),
        overdue:     ($age >= $grace),

        # `default` is the built-in learned model, not a named rule, so no
        # escalation can be aimed at it. Warning about it promises a
        # consequence that cannot be carried out.
        escalatable: (.rule != "default" and .rule != "(unnamed)"),

        # WHO WOULD BE MAILED once a send path exists. Recorded for review.
        would_notify: (.owners // []),

        # WHO IS ACTUALLY ADDRESSED right now: always the override.
        recipient:   $override,

        # A group with no owner on the alert cannot be routed to a human. It is
        # surfaced, never dropped -- silently skipping these is how a workload
        # gets blocked with nobody warned.
        routable:    (((.owners // []) | length) > 0)
      }
  ]
  | sort_by(-.age_days)' <<<"$RULES_JSON")"

TOTAL="$(jq -r 'length' <<<"$PLANNED")"
OVERDUE="$(jq -r '[.[] | select(.overdue)] | length' <<<"$PLANNED")"
UNROUTABLE="$(jq -r '[.[] | select(.routable | not)] | length' <<<"$PLANNED")"
DISTINCT_OWNERS="$(jq -r '[.[].would_notify[]] | unique | length' <<<"$PLANNED")"
NOT_ESCALATABLE="$(jq -r '[.[] | select(.escalatable | not)] | length' <<<"$PLANNED")"

# The set a send path could legitimately mail today: aged out, addressable, and
# pointing at a rule that escalation can actually act on.
SENDABLE="$(jq -r '[.[] | select(.overdue and .routable and .escalatable)] | length' <<<"$PLANNED")"
MAX_RECIPIENTS="$(jq -r '[.[].would_notify | length] | max // 0' <<<"$PLANNED")"

jq -nc \
  --arg grace_days       "$GRACE_DAYS" \
  --arg planned          "$TOTAL" \
  --arg overdue          "$OVERDUE" \
  --arg unroutable       "$UNROUTABLE" \
  --arg not_escalatable  "$NOT_ESCALATABLE" \
  --arg sendable         "$SENDABLE" \
  --arg distinct_owners  "$DISTINCT_OWNERS" \
  --arg max_recipients   "$MAX_RECIPIENTS" \
  --arg override_recipient "$OVERRIDE" \
  --arg send_capable     "false" \
  --arg messages_json    "$PLANNED" \
  '$ARGS.named'
