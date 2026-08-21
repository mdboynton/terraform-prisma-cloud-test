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

# ---------------------------------------------------------------------------
# THE PER-ACCOUNT ROLLUP — one email per account, not one per rule group.
#
# WHY ACCOUNT AND NOT RULE GROUP
#
# Recipients come from the ALERT's `cloudAccountOwners`, which is a property of
# the cloud account, not of the runtime rule. So the same people own every rule
# group in their account and rule-level sends just repeat themselves.
#
# MEASURED on the reference tenant: `twistlock-cto-lab` has 3 rule groups and
# 5 owners - 15 individual sends under rule grouping, 5 emails under account
# grouping, to exactly the same people. Across the whole tenant it is 26 sends
# versus 9. The extra 17 carry no information the first email did not.
#
# ALSO MEASURED, and the reason this is safe: owners are CONSTANT within an
# account. Every one of the 11 accounts has exactly one distinct owner set
# across all its groups (`owner_sets=1`). Rolling up therefore loses no
# addressing precision - it is not an approximation, the groups genuinely
# share a recipient list.
#
# WHAT IS DELIBERATELY NOT DONE HERE
#
# Grouping by PERSON instead of account would cut 9 to 8, because one address
# owns two accounts. Not worth it: an email about "your account" is actionable,
# an email spanning several accounts makes the reader work out which finding
# belongs where, and the account is the unit the owner can actually act on.
#
# Only groups DUE TODAY are rolled up. An account with nothing due produces no
# email at all rather than an empty one.
# ---------------------------------------------------------------------------
ACCOUNT_PLAN="$(jq -c --arg override "$OVERRIDE" '
  [ .[] | select(.notify_today) ]
  | group_by(.account)
  | map({
      account:     .[0].account,

      # Union rather than first-wins. Owners are constant per account today,
      # but if that ever stops being true the union errs toward telling one
      # extra person rather than silently dropping an owner.
      would_notify: ([.[].would_notify[]] | unique),
      recipient:    $override,
      routable:     (([.[].would_notify[]] | unique | length) > 0),

      rule_count:   length,
      rules:        ([.[].rule] | unique),

      # The most urgent thing in this email decides its tone and subject, so
      # the smallest days_remaining is carried at the top level rather than
      # left for a template to recompute.
      min_days_remaining: ([.[].days_remaining] | min),
      max_age_days:       ([.[].age_days] | max),

      # True when at least one group in this account can actually be escalated.
      # An email whose every rule is the built-in `default` model threatens a
      # consequence that cannot be delivered.
      any_escalatable: ([.[] | select(.escalatable)] | length > 0),

      open_alerts:  ([.[].open_alerts] | add),
      occurrences:  ([.[].occurrences] | add),

      # The per-rule detail that would form the body of the email.
      groups: [ .[] | {rule, scope, age_days, days_remaining, open_alerts,
                       occurrences, escalatable} ]
    })
  | sort_by(.min_days_remaining, .account)' <<<"$PLANNED")"

# How many emails a send path would actually dispatch today.
EMAILS_TODAY="$(jq -r '[.[] | select(.routable)] | length' <<<"$ACCOUNT_PLAN")"

# Accounts due a reminder that cannot be addressed. Reported separately so the
# gap stays visible at the level the email is actually sent at.
ACCOUNTS_UNROUTABLE="$(jq -r '[.[] | select(.routable | not)] | length' <<<"$ACCOUNT_PLAN")"

# What the rule-group-per-email approach would have cost, kept so the saving is
# a measured number in the report rather than a claim in a comment.
SENDS_IF_PER_RULE="$(jq -r '[.[] | select(.notify_today) | (.would_notify|length)] | add // 0' <<<"$PLANNED")"

# ---------------------------------------------------------------------------
# THE DAY-14 HANDOFF — what workflow 9 would need to escalate.
#
# This is a LIST, not an instruction. Nothing here escalates anything; the
# script still has no write path of any kind.
#
# ---------------------------------------------------------------------------
# WHY THIS CANNOT BE A COMPLETE ESCALATION REQUEST
# ---------------------------------------------------------------------------
# Workflow 9 escalates an EFFECT SITE, identified by {kind, rule, site,
# effect}. Of those four, this script can honestly supply only two:
#
#   kind   YES - `scope` is derived from `policy.name`, which is the ONLY
#                place the container-vs-host split appears. Verified in
#                digest.sh: the value is exactly "container" or "host",
#                or "unknown" when the policy name matched neither.
#   rule   YES - `metadata.auditRuleName`, which resolves 13/13 against the
#                policy rule names.
#   site   NO  - a container rule has 27 independent effect sites and a host
#                rule 19. MEASURED against 100 promoted alerts: ZERO keys
#                matching /effect/i at any depth. Enforcement state does not
#                survive promotion - it exists only in the Compute Console
#                policy objects. The alert says a rule fired; it does not say
#                which of its 27 controls should start blocking.
#   effect NO  - follows from the site, and `block` is container-only.
#
# So the handoff carries the two fields it can prove and names the two a human
# must choose. Guessing a site would pick, at random, which control starts
# blocking production traffic.
#
# THREE OUTCOMES, REPORTED SEPARATELY. Collapsing them into one count is how a
# finding reaches its deadline with nobody having decided anything:
#
#   ready      - overdue, escalatable, scope known. A human picks the site.
#   blocked    - overdue but NOT escalatable: the built-in `default` learned
#                model, which cannot be targeted by name. On this tenant that
#                is the single largest group of findings, so hiding it would
#                misrepresent most of the backlog as actionable.
#   ambiguous  - overdue and escalatable, but `scope` came back "unknown", so
#                the policy is undetermined. Rule names are NOT unique across
#                policies - three exist in both container and host - and
#                picking the wrong one changes an unrelated control.
#
# Deduplicated by (scope, rule): escalation targets a rule in a policy, not a
# rule in an account. Two accounts hitting the same rule are ONE escalation.
# ---------------------------------------------------------------------------
HANDOFF_READY="$(jq -c '
  [ .[]
    | select(.overdue and .escalatable and (.scope == "container" or .scope == "host"))
  ]
  | group_by(.scope + "\u0000" + .rule)
  | map({
      kind:  .[0].scope,
      rule:  .[0].rule,

      # Named, not guessed - see the block above.
      site:   null,
      effect: null,

      # Carried so a reviewer can weigh the target before choosing a site.
      accounts:      ([.[].account] | unique),
      max_age_days:  ([.[].age_days] | max),
      open_alerts:   ([.[].open_alerts] | add),
      occurrences:   ([.[].occurrences] | add)
    })
  | sort_by(-.max_age_days, .rule)' <<<"$PLANNED")"

HANDOFF_BLOCKED="$(jq -c '
  [ .[] | select(.overdue and (.escalatable | not)) ]
  | group_by(.scope + "\u0000" + .rule)
  | map({kind: .[0].scope, rule: .[0].rule,
         accounts: ([.[].account] | unique),
         max_age_days: ([.[].age_days] | max),
         reason: "the built-in learned model cannot be escalated by name"})
  | sort_by(-.max_age_days, .rule)' <<<"$PLANNED")"

HANDOFF_AMBIGUOUS="$(jq -c '
  [ .[]
    | select(.overdue and .escalatable and .scope != "container" and .scope != "host")
  ]
  | group_by(.scope + "\u0000" + .rule)
  | map({kind: .[0].scope, rule: .[0].rule,
         accounts: ([.[].account] | unique),
         max_age_days: ([.[].age_days] | max),
         reason: "policy.name matched neither container nor host, so the policy is undetermined"})
  | sort_by(-.max_age_days, .rule)' <<<"$PLANNED")"

ESCALATION_READY="$(jq -r 'length' <<<"$HANDOFF_READY")"
ESCALATION_BLOCKED="$(jq -r 'length' <<<"$HANDOFF_BLOCKED")"
ESCALATION_AMBIGUOUS="$(jq -r 'length' <<<"$HANDOFF_AMBIGUOUS")"

# Arithmetic check, not decoration. Every overdue group must land in exactly
# one of the three buckets. If the predicates ever drift out of sync - say a
# new scope value appears - findings would vanish silently between them, and
# a vanished overdue finding is one that reaches its deadline unescalated
# with nothing reporting the omission.
OVERDUE_GROUPS="$(jq -r '[.[] | select(.overdue)]
  | group_by(.scope + "\u0000" + .rule) | length' <<<"$PLANNED")"
BUCKETED=$(( ESCALATION_READY + ESCALATION_BLOCKED + ESCALATION_AMBIGUOUS ))
if [ "$BUCKETED" -ne "$OVERDUE_GROUPS" ]; then
  fail "handoff buckets do not reconcile: ready($ESCALATION_READY) +
 blocked($ESCALATION_BLOCKED) + ambiguous($ESCALATION_AMBIGUOUS) = $BUCKETED,
 but there are $OVERDUE_GROUPS overdue rule/policy groups. Some overdue
 finding is in no bucket and would reach its deadline unreported."
fi

jq -nc \
  --arg emails_today       "$EMAILS_TODAY" \
  --arg accounts_unroutable "$ACCOUNTS_UNROUTABLE" \
  --arg sends_if_per_rule  "$SENDS_IF_PER_RULE" \
  --arg accounts_json      "$ACCOUNT_PLAN" \
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
  --arg escalation_ready     "$ESCALATION_READY" \
  --arg escalation_blocked   "$ESCALATION_BLOCKED" \
  --arg escalation_ambiguous "$ESCALATION_AMBIGUOUS" \
  --arg handoff_ready_json     "$HANDOFF_READY" \
  --arg handoff_blocked_json   "$HANDOFF_BLOCKED" \
  --arg handoff_ambiguous_json "$HANDOFF_AMBIGUOUS" \
  '$ARGS.named'
