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
# stdin : {"rules_json","grace_days","override_recipient",
#          "campaign_start_date"(YYYY-MM-DD),"notify_days"(optional JSON array),
#          "now_ms"(optional)}
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
CAMPAIGN_START="$(get campaign_start_date)"
NOTIFY_DAYS_JSON="$(get notify_days)"
[ -n "$NOTIFY_DAYS_JSON" ] || NOTIFY_DAYS_JSON='[1,3,5,7,10,13]'

[ -n "$RULES_JSON" ] || fail "rules_json is required (the grouped table from digest.sh)"
[ -n "$GRACE_DAYS" ] || fail "grace_days is required"

# ---------------------------------------------------------------------------
# ORDER MATTERS: the override recipient is checked FIRST.
#
# It is the guard that stops live owner mailboxes being resolved at all, so it
# must be the first thing that can refuse. An earlier version of this file put
# the campaign-date check above it, which meant a caller who omitted BOTH was
# told about the date and never learned the safety gate existed. Caught by the
# existing notify suite, which asserts the refusal wording.
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# THE CAMPAIGN START DATE — required, and the reason is not bureaucratic.
#
# The countdown measures from `firstSeen`, the finding's own first sighting.
# MEASURED on this tenant: all 52 open alerts are ALREADY older than 14 days
# (min 29, median 150, max 371). Anchoring on firstSeen alone means the very
# first run tells every single owner their grace period expired months ago,
# and hands all 52 straight to the escalation gate. Nobody actually receives
# the 14 days they were promised. That is an ambush, not a warning.
#
# So day 0 is max(firstSeen, campaign_start_date):
#   - findings already open at go-live start their clock at the ANNOUNCEMENT;
#   - findings first seen afterwards start at their own firstSeen.
# Both cohorts get a full grace period.
#
# There is deliberately NO DEFAULT. Defaulting to today would silently reset
# the whole campaign on every run and no one would ever reach the threshold;
# defaulting to epoch would restore the ambush. Neither failure is visible in
# the output, so the caller has to say what the date is.
# ---------------------------------------------------------------------------
[ -n "$CAMPAIGN_START" ] || fail \
  "campaign_start_date is required (YYYY-MM-DD). The grace countdown runs from
 max(firstSeen, campaign_start_date). Without it, findings that were already
 open before this campaign existed would be reported as long overdue on the
 first run - warning people about a deadline that passed before they were
 told. Set it to the date the campaign is announced."

case "$CAMPAIGN_START" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
  *) fail "campaign_start_date must be YYYY-MM-DD, got: $CAMPAIGN_START" ;;
esac

# Convert to epoch ms at UTC midnight. GNU and BSD date disagree on flags, so
# try both rather than assuming the runner's platform (CI is Linux, dev is
# macOS, and a silent failure here would hand jq an empty string).
CAMPAIGN_START_MS=""
if CS="$(date -u -d "${CAMPAIGN_START}T00:00:00Z" +%s 2>/dev/null)"; then
  CAMPAIGN_START_MS="$(( CS * 1000 ))"
elif CS="$(date -u -j -f "%Y-%m-%d %H:%M:%S" "${CAMPAIGN_START} 00:00:00" +%s 2>/dev/null)"; then
  CAMPAIGN_START_MS="$(( CS * 1000 ))"
else
  fail "could not parse campaign_start_date '$CAMPAIGN_START' with either GNU or BSD date"
fi

# A calendar-shaped string can still be nonsense (2026-02-31 parses on GNU).
case "$CAMPAIGN_START_MS" in
  ''|*[!0-9]*) fail "campaign_start_date did not convert to a timestamp: $CAMPAIGN_START" ;;
esac

case "$GRACE_DAYS" in
  ''|*[!0-9]*) fail "grace_days must be a whole number of days, got: $GRACE_DAYS" ;;
esac

# ---------------------------------------------------------------------------
# THE NOTIFY DAYS — which days of the grace period get a reminder.
#
# The schedule is a SET OF EXACT DAYS, matched against age_days, not a
# "notify every N days" rule. That makes the plan a pure function of the
# finding's age: the same input on the same day produces the same output, with
# no memory of whether a previous run happened.
#
# ⚠️ THE COST OF THAT, STATED PLAINLY: a missed run is a missed notice. If the
# cron does not fire on day 3, nobody gets a day-3 warning - day 5 is the next
# one. Catching up would require a record of what was actually sent, which
# firstSeen cannot provide (it says when the finding appeared, not when anyone
# was told). That ledger is deliberately NOT built here; until it exists, the
# gap between reminders is the safety margin, which is why the set is dense
# early and never leaves more than 3 days between contacts.
# ---------------------------------------------------------------------------
jq -e 'type == "array"' >/dev/null 2>&1 <<<"$NOTIFY_DAYS_JSON" \
  || fail "notify_days must be a JSON array, got: $NOTIFY_DAYS_JSON"

jq -e 'all(type == "number" and . >= 0 and floor == .)' >/dev/null 2>&1 <<<"$NOTIFY_DAYS_JSON" \
  || fail "notify_days must contain only non-negative whole numbers, got: $NOTIFY_DAYS_JSON"

jq -e 'length == (unique | length)' >/dev/null 2>&1 <<<"$NOTIFY_DAYS_JSON" \
  || fail "notify_days must not contain duplicates, got: $NOTIFY_DAYS_JSON"

# A notify day at or beyond the deadline is unreachable: at age >= grace_days
# the finding is overdue and belongs to the escalation path, not the reminder
# path. Silently ignoring such an entry would let someone configure
# notify_days=[1,7,14] with grace_days=14 and believe a final warning goes out
# on the deadline day when it never does.
BAD_DAYS="$(jq -r --argjson g "$GRACE_DAYS" '[.[] | select(. >= $g)] | join(", ")' <<<"$NOTIFY_DAYS_JSON")"
[ -z "$BAD_DAYS" ] || fail \
  "notify_days contains $BAD_DAYS, which is not before grace_days ($GRACE_DAYS).
 A reminder on or after the deadline would never be sent: at that age the
 finding is overdue and handled by the escalation path instead. Use a day
 strictly less than $GRACE_DAYS."

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
  --argjson cstart "$CAMPAIGN_START_MS" \
  --argjson ndays "$NOTIFY_DAYS_JSON" \
  --arg override "$OVERRIDE" '
  [ .[]
    | select(.open_alerts > 0 and .open_first > 0)

    # Prefer the finding-level first sighting; fall back to the alert time for
    # data produced before `open_first_seen` existed, so an older digest
    # payload still plans rather than silently dropping every group.
    | ((if (.open_first_seen // 0) > 0 then .open_first_seen else .open_first end)) as $seen

    # DAY 0 = the later of "when we first saw it" and "when we announced the
    # campaign". A finding that predates the campaign cannot be more than
    # (today - campaign_start) days into its grace period, however old it is.
    | (if $seen > $cstart then $seen else $cstart end) as $clock_start

    | ((($now - $clock_start) / 86400000) | floor) as $age

    # The real age of the finding, independent of the campaign. Kept because
    # it is the honest answer to "how long has this been happening" and a
    # warning that hides it would understate the problem.
    | ((($now - $seen) / 86400000) | floor) as $true_age
    | {
        rule:        .rule,
        scope:       .scope,
        account:     .account,
        clusters:    (.clusters // []),
        open_alerts: .open_alerts,
        occurrences: .occurrences,

        # Days into the GRACE PERIOD. This is what the countdown in a warning
        # message must use.
        age_days:    $age,

        # Days since the finding was first seen. Always >= age_days.
        finding_age_days: $true_age,

        # True when the campaign start, not the finding, is setting day 0 --
        # i.e. this was already open before the campaign began.
        backlog:     ($cstart > $seen),

        days_remaining: ($grace - $age),
        overdue:     ($age >= $grace),

        # Is TODAY one of the reminder days for this group?
        #
        # An exact set membership test on age_days, so the whole plan stays a
        # pure function of age. Note this is independent of `routable` and
        # `escalatable`: a group can be due a reminder today and still be
        # unmailable. Conflating the two would hide the unroutable ones, and
        # those are exactly the findings that would otherwise be blocked with
        # nobody warned.
        notify_today: ($ndays | index($age) != null),

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

# How many groups predate the campaign. On a first run this is normally ALL of
# them, and it is the number that says "these people are hearing about this for
# the first time" -- distinct from `overdue`, which now means "their announced
# grace period has genuinely elapsed".
BACKLOG="$(jq -r '[.[] | select(.backlog)] | length' <<<"$PLANNED")"
UNROUTABLE="$(jq -r '[.[] | select(.routable | not)] | length' <<<"$PLANNED")"
DISTINCT_OWNERS="$(jq -r '[.[].would_notify[]] | unique | length' <<<"$PLANNED")"
NOT_ESCALATABLE="$(jq -r '[.[] | select(.escalatable | not)] | length' <<<"$PLANNED")"

# The set a send path could legitimately mail today: aged out, addressable, and
# pointing at a rule that escalation can actually act on.
SENDABLE="$(jq -r '[.[] | select(.overdue and .routable and .escalatable)] | length' <<<"$PLANNED")"
MAX_RECIPIENTS="$(jq -r '[.[].would_notify | length] | max // 0' <<<"$PLANNED")"

# Groups whose age lands on a reminder day today.
DUE_TODAY="$(jq -r '[.[] | select(.notify_today)] | length' <<<"$PLANNED")"

# Of those, the ones a send path could actually deliver.
#
# Reported SEPARATELY from due_today rather than replacing it: the difference
# between the two numbers is the count of people who are due a warning today
# and will not get one. That gap is the thing worth watching, so it must not be
# arithmetic the reader has to do themselves.
DUE_TODAY_ROUTABLE="$(jq -r '[.[] | select(.notify_today and .routable)] | length' <<<"$PLANNED")"

jq -nc \
  --arg grace_days       "$GRACE_DAYS" \
  --arg campaign_start_date "$CAMPAIGN_START" \
  --arg notify_days      "$NOTIFY_DAYS_JSON" \
  --arg due_today        "$DUE_TODAY" \
  --arg due_today_routable "$DUE_TODAY_ROUTABLE" \
  --arg planned          "$TOTAL" \
  --arg overdue          "$OVERDUE" \
  --arg backlog          "$BACKLOG" \
  --arg unroutable       "$UNROUTABLE" \
  --arg not_escalatable  "$NOT_ESCALATABLE" \
  --arg sendable         "$SENDABLE" \
  --arg distinct_owners  "$DISTINCT_OWNERS" \
  --arg max_recipients   "$MAX_RECIPIENTS" \
  --arg override_recipient "$OVERRIDE" \
  --arg send_capable     "false" \
  --arg messages_json    "$PLANNED" \
  '$ARGS.named'
