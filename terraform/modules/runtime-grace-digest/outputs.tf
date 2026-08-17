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
output "status" {
  description = "ok | disabled | missing_credentials | suspect_unfiltered | partial_grouping. Callers must branch on this: a failed check does NOT fail the plan, and check results are absent from plan JSON."
  value = (
    !var.enabled ? "disabled" :
    !local.creds_present ? "missing_credentials" :
    local.result == null ? "disabled" :
    local.result.suspect_unfiltered ? "suspect_unfiltered" :
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
  description = "Runtime rules that produced incidents inside the window, grouped by rule + scope (container|host) + cloud account, ordered by occurrences. INCLUDES the built-in `default` model. Empty list when nothing was queried."
  value       = local.rules
}

output "actionable_rules" {
  description = "As `rules`, but excluding the built-in `default` model, which is not a named runtime rule and cannot be escalated by name. This is the list a human acts on."
  value       = local.actionable_rules
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
  }
}
