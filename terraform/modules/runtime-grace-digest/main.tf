# ============================================================
# runtime-grace-digest - which runtime rules are STILL FIRING?
#
# READ-ONLY BY CONSTRUCTION. The only block below is a `data` block, so a plan
# against this module can report but never change.
#
# WHY RECURRENCE AND NOT A 14-DAY GRACE TIMER:
# A runtime finding is an EVENT, not a state. It happened, and no API call makes
# it un-happen - there is no "resolved" to age against, and incidents never
# expire out of the store. "Older than N days" therefore trends toward
# everything ever recorded (measured: 14,398 of 14,410) and really only reports
# whether someone clicked acknowledge. This module reports which rules are still
# PRODUCING incidents instead; a fixed workload stops firing, so the signal
# clears itself.
#
# WHY CSPM AND NOT THE COMPUTE CONSOLE:
# Runtime incidents are promoted into CSPM as `workload_incident` alerts. The
# promoted copy carries `metadata.auditRuleName` (the runtime rule) and
# `auditCount` (occurrences), PLUS the full dismissal lifecycle. A raw Compute
# incident has only an unattributed `acknowledged` boolean - no actor, no note,
# no expiry - and `acknowledge` is the only write route that exists.
#
# See plans/policy-escalation-findings.md.
# ============================================================

locals {
  # Derived from sensitive variables, so the result inherits the taint. The
  # boolean itself reveals nothing, and the caller MUST be able to read it to
  # tell "misconfigured" from "genuinely nothing firing" - so it is explicitly
  # de-tainted rather than the output being marked sensitive, which would hide
  # exactly the signal the workflow needs.
  #
  # TEST FOR EMPTY, NOT JUST NULL. A missing GitHub secret does not arrive as
  # null - `TF_VAR_x: ${{ secrets.MISSING }}` sets the variable to the EMPTY
  # STRING. A null-only check passes, the script runs, and the plan hard-fails
  # with "cspm_url is empty" instead of reporting missing_credentials - so the
  # status output a workflow branches on never gets the chance to fire. Caught
  # by testing this module with an unset credential.
  # NOT coalesce(): it treats "" as absent and raises "Error in function call"
  # when every argument is empty, which turns the very case being guarded into
  # a hard plan failure. `x != null && x != ""` is the safe form.
  creds_present = nonsensitive(
    var.cspm_url != null && var.cspm_url != "" &&
    var.access_key != null && var.access_key != "" &&
    var.secret_key != null && var.secret_key != ""
  )

  should_query = var.enabled && local.creds_present
}

# ------------------------------------------------------------
# The query.
#
# `external` is a DATA source: this preserves the zero-resource guarantee. A
# `terraform_data` or `null_resource` would work mechanically but would put a
# resource in the plan, which is the thing that makes this module safe to run
# on a schedule.
# ------------------------------------------------------------
data "external" "digest" {
  count = local.should_query ? 1 : 0

  program = ["bash", "${path.module}/scripts/digest.sh"]

  query = {
    cspm_url     = var.cspm_url
    access_key   = var.access_key
    secret_key   = var.secret_key
    window_days  = tostring(var.window_days)
    max_alerts   = tostring(var.max_alerts)
    alert_status = var.alert_status

    # `external` query values must be STRINGS - a list here is a type error, not
    # a helpful coercion - so the severity set travels as a JSON array literal
    # and is parsed back by the script. `[]` means "no severity filter".
    severities = jsonencode(var.severities)
  }
}

locals {
  raw = local.should_query ? data.external.digest[0].result : null

  # `data "external"` can only return a flat map of STRINGS. Numbers are
  # stringified by the script and converted back here so callers get real
  # numbers, and the grouped table travels as a JSON string that is decoded
  # once, here, rather than by every caller.
  rules = local.raw == null ? [] : jsondecode(local.raw.rules_json)

  # Rules that can actually be acted on. `default` is not one of the named
  # runtime rules - it appears to be the built-in learned model - so it cannot
  # be escalated by name. It is counted, but kept out of the actionable list so
  # nobody tries to "fix the default rule".
  actionable_rules = [
    for r in local.rules : r
    if r.rule != "default" && r.rule != "(unnamed)"
  ]

  result = local.raw == null ? null : {
    window_days  = tonumber(local.raw.window_days)
    alert_status = local.raw.alert_status

    # Server-side totals. Never capped by max_alerts.
    alerts_in_window = tonumber(local.raw.alerts_in_window)
    alerts_all_time  = tonumber(local.raw.alerts_all_time)

    # How many alerts the grouped table was actually built from. When this is
    # below alerts_in_window the table is a SAMPLE, which is why it is reported
    # rather than hidden.
    alerts_fetched = tonumber(local.raw.alerts_fetched)
    complete       = local.raw.complete == "true"

    distinct_rules  = tonumber(local.raw.distinct_rules)
    distinct_groups = tonumber(local.raw.distinct_groups)
    occurrences     = tonumber(local.raw.occurrences)

    # Alerts attributed to the built-in model rather than a named rule.
    unnamed_rule_alerts = tonumber(local.raw.unnamed_rule_alerts)

    # True when the windowed count equals the all-time count on a short window,
    # which is what a silently-dropped time filter looks like.
    suspect_unfiltered = local.raw.suspect_unfiltered == "true"

    # The severity set that was actually asked for, echoed back from the script
    # rather than read from the variable, so the report describes the query that
    # ran instead of the configuration that was intended.
    severities = jsondecode(local.raw.severities)

    # True only when a severity filter was requested AND at least one row came
    # back AND every returned row was inside the requested set.
    #
    # False therefore has TWO meanings and is not, on its own, a problem: no
    # filter was asked for, or the filter matched nothing. It can never mean
    # "the filter leaked" - the script hard-fails on that, because
    # `policy.severity` fails OPEN on a bad value and returns the whole tenant.
    severities_verified = local.raw.severities_verified == "true"
  }
}

# ------------------------------------------------------------
# The grace warning plan.
#
# Also a `data` block, so the zero-resource guarantee still holds. It consumes
# the grouped table from above rather than re-querying, so it costs no extra
# API calls.
#
# It runs only when an override recipient is present. The script enforces this
# too, but failing here gives a readable Terraform error instead of a script
# abort. The override is what makes planning safe against live owner data.
# ------------------------------------------------------------
locals {
  # `campaign_start_date` is as load-bearing as the override recipient: without
  # it the countdown falls back to each finding's own age, and MEASURED on this
  # tenant every open finding is already months past a 14-day grace. Gating on
  # it here turns "silently warns everyone their deadline expired" into a
  # readable "you must set this" at plan time.
  campaign_start_set = var.campaign_start_date != null && var.campaign_start_date != ""

  # A display-safe form of the date, for use inside `check` error messages.
  #
  # This is NOT belt-and-braces. Terraform evaluates a check's `error_message`
  # EAGERLY - even on the runs where the condition passes - so every argument
  # has to be formattable in every case, including the one where the caller
  # omitted the date entirely.
  #
  # `try(tostring(x), "?")` does NOT protect against this, which is the trap
  # that produced the original crash: `tostring(null)` RETURNS null rather than
  # raising, so `try` has no error to catch, hands null to `format`, and the
  # plan dies with "unsupported value for %s: null value cannot be formatted".
  # `try` only guards operations that FAIL; it does nothing about ones that
  # quietly succeed with null. A plain conditional is unambiguous.
  campaign_start_display = local.campaign_start_set ? var.campaign_start_date : "(not set)"

  can_notify = var.notify_enabled && local.should_query && local.raw != null && (
    var.warning_recipient_override != null && var.warning_recipient_override != ""
  ) && local.campaign_start_set
}

data "external" "notify" {
  count = local.can_notify ? 1 : 0

  program = ["bash", "${path.module}/scripts/notify_plan.sh"]

  query = {
    rules_json          = local.raw.rules_json
    grace_days          = tostring(var.grace_days)
    override_recipient  = var.warning_recipient_override
    campaign_start_date = var.campaign_start_date

    # JSON, for the same reason as `severities` above: `external` query values
    # must be strings.
    notify_days = jsonencode(var.notify_days)
  }
}

locals {
  notify_raw = local.can_notify ? data.external.notify[0].result : null

  warning_plan = local.notify_raw == null ? null : {
    grace_days = tonumber(local.notify_raw.grace_days)

    # The announced start of the campaign. Day 0 for anything already open
    # when it began.
    campaign_start_date = local.notify_raw.campaign_start_date

    # Rule groups with at least one open alert.
    planned = tonumber(local.notify_raw.planned)

    # Past the grace threshold, measured from max(firstSeen, campaign start).
    overdue = tonumber(local.notify_raw.overdue)

    # Groups that predate the campaign, so the announcement - not the finding -
    # set their day 0. On a first run this is normally every group, and it is
    # the count of people hearing about this for the first time.
    backlog = tonumber(local.notify_raw.backlog)

    # No owner on the alert - cannot be addressed to a human. Surfaced rather
    # than dropped: silently skipping these is how a workload gets blocked
    # with nobody warned.
    unroutable = tonumber(local.notify_raw.unroutable)

    # The `default` learned model, which cannot be escalated by name, so a
    # warning about it threatens a consequence that cannot be delivered.
    not_escalatable = tonumber(local.notify_raw.not_escalatable)

    # Overdue AND addressable AND pointing at a real rule. The only set a send
    # path could honestly mail.
    sendable = tonumber(local.notify_raw.sendable)

    distinct_owners = tonumber(local.notify_raw.distinct_owners)
    max_recipients  = tonumber(local.notify_raw.max_recipients)

    # The reminder schedule, echoed back from the script so the report
    # describes the run that happened rather than the configuration intended.
    notify_days = jsondecode(local.notify_raw.notify_days)

    # Groups whose age lands on a reminder day TODAY. This is the number a
    # send path would act on - `planned` is the whole population, most of
    # which is mid-period and correctly silent.
    due_today = tonumber(local.notify_raw.due_today)

    # How many EMAILS would actually be dispatched today, one per addressable
    # account. This - not `due_today` - is the number that matters to the
    # people receiving them.
    emails_today = tonumber(local.notify_raw.emails_today)

    # Accounts due a reminder with no owner to send it to. The same gap as
    # `unroutable`, counted at the level mail is actually sent.
    accounts_unroutable = tonumber(local.notify_raw.accounts_unroutable)

    # What one-email-per-rule-group would have cost. Kept so the saving stays a
    # measured number rather than an assertion in a comment.
    sends_if_per_rule = tonumber(local.notify_raw.sends_if_per_rule)

    # Of those, how many could actually be delivered. The DIFFERENCE between
    # this and due_today is the count of people who are due a warning today
    # and will not receive one, which is the number worth watching.
    due_today_routable = tonumber(local.notify_raw.due_today_routable)

    override_recipient = local.notify_raw.override_recipient

    # Always false in this module. There is no send path yet.
    send_capable = local.notify_raw.send_capable == "true"
  }

  warning_messages = local.notify_raw == null ? [] : jsondecode(local.notify_raw.messages_json)

  # One entry per ACCOUNT due a reminder today - the unit an email is sent in.
  # `warning_messages` remains the per-rule-group view; this is a rollup of it,
  # not a replacement, so callers that want rule detail still have it.
  warning_accounts = local.notify_raw == null ? [] : jsondecode(local.notify_raw.accounts_json)
}

# ------------------------------------------------------------
# Guards.
#
# These emit warnings; they do NOT fail the plan. A caller must branch on the
# `status` output instead - see outputs.tf for why the exit code is not enough.
#
# NOTE on error_message: a check block's message is evaluated even when the
# assertion passes and even when this module is disabled. Interpolating a null
# there raises "Invalid template interpolation value" and fails the ENTIRE plan,
# every module, not just this one. That bit the alert-summary module and was
# only caught by running an untargeted plan - every workflow uses -target, which
# hides it. Hence the null-safe locals above and the try() below.
# ------------------------------------------------------------

check "time_window_applied" {
  assert {
    condition = local.result == null ? true : !local.result.suspect_unfiltered

    error_message = format(
      "The %s-day window returned the same number of alerts as an all-time query (%s). Either every alert really is recent, or the time filter was silently ignored - the alerts API returns HTTP 200 and the full tenant for a filter it does not recognise. Confirm before treating this as a recurrence signal.",
      try(tostring(local.result.window_days), "?"),
      try(tostring(local.result.alerts_in_window), "?")
    )
  }
}

# The mirror of the check above. `time_window_applied` catches a window that is
# too WIDE (or silently ignored). This one catches a window that is too NARROW.
#
# Both failure modes render as a confident, clean report. An empty window looks
# exactly like a healthy tenant: zero rows, no warnings, nothing to escalate.
#
# MEASURED on the reference tenant: the default 14-day window returns 0 open
# alerts while an all-time query returns 111. A grace campaign run on the
# defaults would plan zero warnings, email nobody, and report success - and the
# 111 alerts that workflow 9 escalates against would still be there. That is
# the split-brain this check exists to make loud.
#
# Deliberately NOT a hard failure. Zero-in-window is the CORRECT answer for a
# healthy tenant, and a module that errors on good news is a module people
# disable. The distinguishing signal is `alerts_all_time > 0`: alerts exist,
# just not in the window being asked about.
check "window_returned_alerts" {
  assert {
    condition = local.result == null ? true : !(
      local.result.alerts_in_window == 0 &&
      local.result.alerts_all_time > 0
    )

    error_message = format(
      "The %s-day window returned 0 alerts, but the tenant has %s all-time. Nothing is firing INSIDE the window - which reads identically to a healthy tenant and will plan zero grace warnings. If this feeds an escalation campaign, widen window_days until it returns the population you intend to warn about; workflow 9 measures the same tenant over its own window, and the two must agree or people get blocked without notice.",
      try(tostring(local.result.window_days), "?"),
      try(tostring(local.result.alerts_all_time), "?")
    )
  }
}

check "grouping_is_complete" {
  assert {
    condition = local.result == null ? true : local.result.complete

    error_message = format(
      "The rule table was built from %s of %s alerts in the window (capped by max_alerts). Rules below the cut-off are missing entirely - raise max_alerts for a complete picture. The window and tenant totals are unaffected.",
      try(tostring(local.result.alerts_fetched), "?"),
      try(tostring(local.result.alerts_in_window), "?")
    )
  }
}

# The countdown now runs from max(firstSeen, campaign_start_date), so a backlog
# no longer arrives pre-expired: everything already open starts its grace period
# at the announcement.
#
# This check therefore means something different than it used to. Every group
# being overdue is now only possible if the campaign start date is itself more
# than grace_days in the past - i.e. the campaign really has run its course, or
# somebody backdated the date and recreated the ambush this was written to catch.
check "grace_window_is_meaningful" {
  assert {
    condition = local.warning_plan == null ? true : !(
      local.warning_plan.planned > 0 &&
      local.warning_plan.overdue == local.warning_plan.planned
    )

    error_message = format(
      "Every one of the %s planned warnings is already past the %s-day grace window, counted from the campaign start date %s. Since the countdown starts at the announcement, this means either the campaign has genuinely run its full course, or campaign_start_date is backdated far enough that nobody ever received advance notice. Confirm which before any send path acts on this.",
      try(tostring(local.warning_plan.planned), "?"),
      try(tostring(local.warning_plan.grace_days), "?"),
      try(tostring(local.warning_plan.campaign_start_date), "?")
    )
  }
}

# A campaign start date in the FUTURE means every countdown is negative: nothing
# is ever overdue, so nothing would ever escalate, and the digest would look
# calm indefinitely. Cheap to typo (2027 for 2026) and invisible in the output.
# Compared directly rather than inferred from the counts. An earlier version of
# this check tried to detect a future date from "no group is overdue", which is
# also true of a perfectly healthy campaign on day 1 - it would have cried wolf
# on every early run. `timecmp` against the date itself has one meaning.
check "campaign_start_is_not_in_the_future" {
  assert {
    condition = !local.campaign_start_set ? true : timecmp(
      plantimestamp(), "${var.campaign_start_date}T00:00:00Z"
    ) >= 0

    error_message = format(
      "campaign_start_date (%s) is in the future. Every grace countdown starts then, so no finding can reach the %s-day threshold and nothing will ever be escalated - the report will look calm because the clock has not started.",
      local.campaign_start_display,
      try(tostring(var.grace_days), "?")
    )
  }
}

# A warning nobody receives is not a warning. These groups carry no owner on
# the alert, so they would be blocked with no notice at all.
check "warnings_are_routable" {
  assert {
    condition = local.warning_plan == null ? true : local.warning_plan.unroutable == 0
    error_message = format(
      "%s of %s planned warnings have no owner on the alert and cannot be addressed to anyone. They are reported, never silently dropped - but until a fallback recipient is declared, escalating those rules would block a workload with nobody warned.",
      try(tostring(local.warning_plan.unroutable), "?"),
      try(tostring(local.warning_plan.planned), "?")
    )
  }
}
