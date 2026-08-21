# Null means "not asked for" (module disabled, or credentials absent). Zero
# means "asked, and nothing is firing". Collapsing the two would let a
# misconfiguration read as a clean bill of health — which, for a security
# report, is the worst possible failure mode.

# ----------------------------------------------------------------
# Machine-readable status.
#
# WHY THIS EXISTS: the `check` blocks in main.tf emit warnings, and a failing
# check does NOT fail the plan. Worse, `terraform show -json` omits the `checks`
# array entirely for a plan file, so a caller cannot detect the warning
# programmatically at all - it appears only in human-readable stderr.
#
# A workflow must branch on THIS value, not on the exit code.
# ----------------------------------------------------------------
# `empty_window` sits BELOW the two "your data may be wrong" states and ABOVE
# `partial_grouping`, because ordering here is a claim about which problem to
# report when several are true at once:
#
#   - suspect_unfiltered and empty_window are mutually exclusive by definition
#     (one needs window == all_time > 0, the other window == 0 < all_time), so
#     their relative order is unobservable. It is fixed only for readability.
#
#   - empty_window MUST outrank partial_grouping. With zero alerts in the
#     window `complete` is trivially true, so partial_grouping cannot fire --
#     but if the cap semantics ever change, reporting "the table is a sample"
#     for a table that has no rows at all would be actively misleading.
#
# `ok` with zero rows remains a legitimate, healthy answer: it is reported only
# when the tenant has no alerts AT ALL, which is genuinely nothing to say.
output "status" {
  description = "ok | disabled | missing_credentials | suspect_unfiltered | empty_window | partial_grouping. Callers must branch on this: a failed check does NOT fail the plan, and check results are absent from plan JSON."
  value = (
    !var.enabled ? "disabled" :
    !local.creds_present ? "missing_credentials" :
    local.result == null ? "disabled" :
    local.result.suspect_unfiltered ? "suspect_unfiltered" :
    (local.result.alerts_in_window == 0 && local.result.alerts_all_time > 0) ? "empty_window" :
    !local.result.complete ? "partial_grouping" :
    "ok"
  )
}

output "status_detail" {
  description = "Human-readable explanation of `status`. Null when status is ok."
  value = (
    !var.enabled ? "Module disabled." :
    !local.creds_present ? "CSPM credentials were not supplied (cspm_url, access_key, secret_key). No report was produced - this is NOT the same as nothing firing." :
    local.result == null ? "Module disabled." :
    local.result.suspect_unfiltered ? "The ${local.result.window_days}-day window returned the same count as an all-time query. Either every alert is genuinely recent, or the time filter was silently ignored." :
    (local.result.alerts_in_window == 0 && local.result.alerts_all_time > 0) ? "The ${local.result.window_days}-day window returned 0 alerts, but the tenant has ${local.result.alerts_all_time} all-time. Nothing is firing inside the window. This is indistinguishable from a healthy tenant in the report itself, and it plans zero grace warnings - widen window_days if this feeds an escalation campaign." :
    !local.result.complete ? "The rule table was built from ${local.result.alerts_fetched} of ${local.result.alerts_in_window} alerts (capped by max_alerts). Rules below the cut-off are missing." :
    null
  )
}

# ----------------------------------------------------------------
# The report.
# ----------------------------------------------------------------

output "summary" {
  description = "Counts for the window, plus the all-time total for proportion. Null when the module is disabled or credentials are absent."
  value       = local.result
}

output "rules" {
  description = "Runtime rules that produced promoted CSPM alerts inside the window, grouped by rule + scope (container|host) + cloud account, ordered by occurrences. INCLUDES the built-in `default` model. Empty list when nothing was queried."
  value       = local.rules
}

output "actionable_rules" {
  description = "As `rules`, but excluding the built-in `default` model, which is not a named runtime rule and cannot be escalated by name. This is the list a human acts on."
  value       = local.actionable_rules
}

# ----------------------------------------------------------------
# The grace warning plan.
#
# PLAN ONLY. Nothing here sends anything, and `send_capable` is always false.
# `warning_messages[].would_notify` holds the REAL owner addresses from the
# alert; `recipient` is always the override. Treat would_notify as personal
# data: it is live mailboxes of real people, including external ones.
# ----------------------------------------------------------------

# `no_campaign_start` is checked alongside `no_override` because they are the
# same class of problem: a required input the caller has not supplied, where
# the consequence of a default would be silent and harmful.
output "notify_status" {
  description = "ok | disabled | no_override | no_campaign_start | not_queried | all_overdue | has_unroutable. Callers must branch on this rather than the exit code - a failed check does not fail the plan."
  value = (
    !var.notify_enabled ? "disabled" :
    !local.should_query ? "not_queried" :
    (var.warning_recipient_override == null || var.warning_recipient_override == "") ? "no_override" :
    !local.campaign_start_set ? "no_campaign_start" :
    local.warning_plan == null ? "not_queried" :
    (local.warning_plan.planned > 0 && local.warning_plan.overdue == local.warning_plan.planned) ? "all_overdue" :
    local.warning_plan.unroutable > 0 ? "has_unroutable" :
    "ok"
  )
}

output "notify_status_detail" {
  description = "Human-readable explanation of `notify_status`. Null when ok."
  value = (
    !var.notify_enabled ? "Grace warning planning is disabled." :
    !local.should_query ? "The digest did not run, so there is nothing to plan warnings from." :
    (var.warning_recipient_override == null || var.warning_recipient_override == "") ? "warning_recipient_override is required. Planning reads live owner mailboxes from the alert data; it will not resolve real recipients until a reviewed send path exists." :
    !local.campaign_start_set ? "campaign_start_date is required (YYYY-MM-DD). The countdown runs from max(firstSeen, campaign_start_date). Without it, findings that were already open before this campaign began would be reported as long overdue on the first run - warning people about a deadline that passed before anyone told them." :
    local.warning_plan == null ? "The digest did not run, so there is nothing to plan warnings from." :
    (local.warning_plan.planned > 0 && local.warning_plan.overdue == local.warning_plan.planned) ? "All ${local.warning_plan.planned} planned warnings are already past the ${local.warning_plan.grace_days}-day window measured from ${local.warning_plan.campaign_start_date}. With a campaign start date set this should only happen once the period has genuinely elapsed - if it appears on a first run, check the date is not in the past." :
    local.warning_plan.unroutable > 0 ? "${local.warning_plan.unroutable} of ${local.warning_plan.planned} planned warnings have no owner on the alert and cannot be addressed. They are reported, not dropped - but those rules would be escalated with nobody warned." :
    null
  )
}

output "warning_plan" {
  description = "Counts for the planned grace warning: planned, overdue, backlog, unroutable, not_escalatable, sendable, due_today, due_today_routable, notify_days, distinct_owners, max_recipients. Null when planning is disabled. `sendable` is the only set a send path could honestly mail: overdue AND addressable AND pointing at an escalatable rule."
  value       = local.warning_plan
}

output "warning_messages" {
  description = "Per-rule-group warning plan: age_days, days_remaining, overdue, notify_today, escalatable, routable, would_notify (the REAL owner addresses, for review only) and recipient (always the override). Empty list when planning is disabled. Contains live personal email addresses - do not publish this verbatim."
  value       = local.warning_messages
}

# The subset a daily run would act on. Separate from `warning_messages` so a
# caller does not have to re-implement the schedule filter and risk drifting
# from it - the definition of "due today" lives in one place.
output "due_today_messages" {
  description = "The subset of `warning_messages` whose age_days lands on a notify_days entry today. This is what a send path iterates. Empty list when planning is disabled or nothing is due. Contains live personal email addresses."
  value       = [for m in local.warning_messages : m if m.notify_today]
}

output "top_rule" {
  description = "The single actionable rule with the most occurrences in the window, or null when nothing is firing. Convenience for a one-line notification."
  value       = length(local.actionable_rules) > 0 ? local.actionable_rules[0] : null
}

# ----------------------------------------------------------------
# Individual counts, for callers that want one number without unwrapping the
# envelope. All null when nothing was queried - never silently zero.
# ----------------------------------------------------------------

output "alerts_in_window" {
  description = "Runtime incident alerts raised inside the window. Server-side total, never capped by max_alerts. Null when nothing was queried."
  value       = local.result == null ? null : local.result.alerts_in_window
}

output "distinct_rules" {
  description = "How many distinct runtime rules fired inside the window. Null when nothing was queried."
  value       = local.result == null ? null : local.result.distinct_rules
}

output "scope" {
  description = "How the report was produced, for troubleshooting. If a number looks wrong, this shows what was actually queried and how it compares to all time."
  value = local.result == null ? null : {
    window_days         = local.result.window_days
    alert_status        = local.result.alert_status
    alerts_in_window    = local.result.alerts_in_window
    alerts_all_time     = local.result.alerts_all_time
    alerts_fetched      = local.result.alerts_fetched
    complete            = local.result.complete
    unnamed_rule_alerts = local.result.unnamed_rule_alerts
    suspect_unfiltered  = local.result.suspect_unfiltered

    # An empty list here is the honest report of an UNFILTERED query, and it is
    # the default. Anyone reading a count and assuming "high/critical only"
    # should be able to see, in the same object, that no severity was asked for.
    severities = local.result.severities

    # Proof the filter took effect, not just that it was requested. Kept next to
    # `severities` because the pair is the whole story: what was asked for, and
    # whether the response actually honoured it.
    severities_verified = local.result.severities_verified
  }
}
