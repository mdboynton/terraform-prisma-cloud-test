# Null means "not asked for" (disabled, or credentials absent). Zero means
# "asked, and nothing matched". Collapsing the two would let a misconfiguration
# read as a clean bill of health, which for a security report is the worst
# available failure mode.

# ----------------------------------------------------------------
# Machine-readable status.
#
# WHY THIS EXISTS: the `check` blocks in main.tf emit warnings, and a failing
# check does NOT fail the plan. Worse, `terraform show -json` omits the `checks`
# array entirely for a plan file, so a caller cannot detect the warning
# programmatically at all - it appears only in human-readable stderr.
#
# A workflow must branch on THIS value, never on the exit code.
# ----------------------------------------------------------------
output "status" {
  description = "ok | disabled | missing_credentials | ambiguous_rules | unmatched_rules. Callers must branch on this: a failed check does NOT fail the plan, and check results are absent from plan JSON."
  value = (
    !var.enabled ? "disabled" :
    !local.creds_present ? "missing_credentials" :
    local.raw == null ? "disabled" :
    length(local.ambiguous_rules) > 0 ? "ambiguous_rules" :
    length(local.unmatched_rules) > 0 ? "unmatched_rules" :
    "ok"
  )
}

output "status_detail" {
  description = "Human-readable explanation of `status`. Null when status is ok."
  value = (
    !var.enabled ? "Module disabled." :
    !local.creds_present ? "Credentials were not supplied (cspm_url, compute_url, access_key, secret_key). Nothing was checked - this is NOT the same as nothing firing." :
    local.raw == null ? "Module disabled." :
    length(local.ambiguous_rules) > 0 ? "${length(local.ambiguous_rules)} rule name(s) exist in both the container and host policies; the alert does not say which one fired." :
    length(local.unmatched_rules) > 0 ? "${length(local.unmatched_rules)} firing rule name(s) no longer match any live runtime rule." :
    null
  )
}

# ----------------------------------------------------------------
# The report.
# ----------------------------------------------------------------

output "summary" {
  description = "Counts for the run. Null when nothing was queried."
  value = local.raw == null ? null : {
    window_days     = tonumber(local.raw.window_days)
    alert_status    = local.raw.alert_status
    alerts_total    = tonumber(local.raw.alerts_total)
    container_rules = tonumber(local.raw.container_rules)
    host_rules      = tonumber(local.raw.host_rules)
    firing_rules    = tonumber(local.raw.firing_rules)
    matched         = tonumber(local.raw.matched)
    ambiguous       = tonumber(local.raw.ambiguous)
    unmatched       = tonumber(local.raw.unmatched)
    builtin         = tonumber(local.raw.builtin)
    sites           = length(local.sites)
    alerting        = length(local.alerting_sites)
    enforced        = length(local.enforced_sites)
    disabled        = length(local.disabled_sites)
  }
}

output "rules" {
  description = "Every firing rule with its match_status and, where matched, the full effect-site inventory per policy kind."
  value       = local.rules
}

# ----------------------------------------------------------------
# Effect sites - the unit an escalation targets.
#
# A rule has no single effect. `site` is a literal jq path into the policy
# object, so an escalation is addressed as (kind, rule, site, new effect) with
# nothing inferred.
# ----------------------------------------------------------------

output "sites" {
  description = "One row per effect site on every unambiguously matched firing rule: kind, rule, rule_index, site, effect, action, occurrences, alerts."
  value       = local.sites
}

output "alerting_sites" {
  description = "Sites currently set to `alert` on rules that are still firing. THE ESCALATION CANDIDATE LIST - a human picks from here."
  value       = local.alerting_sites
}

output "enforced_sites" {
  description = "Sites already set to `prevent` or `block` whose rules are STILL producing alerts. Expected, not broken: effect controls enforcement, not telemetry. This is the distinction workflow 8 cannot make."
  value       = local.enforced_sites
}

output "disabled_sites" {
  description = "Sites set to `disable` - the detection is OFF. Kept separate from alerting_sites because disable -> prevent enables a detection that was never running, a much larger change than alert -> prevent."
  value       = local.disabled_sites
}

output "ambiguous_rules" {
  description = "Firing rules whose name exists in BOTH policies. Sites are reported per kind, but an escalation must name the policy explicitly - this is not resolvable from alert data."
  value       = local.ambiguous_rules
}

output "unmatched_rules" {
  description = "Firing rule names with no live runtime rule. Nothing to escalate; reported so they are not silently dropped."
  value       = local.unmatched_rules
}

output "builtin_rules" {
  description = "Alerts attributed to `default`. NOTE: `default` is both the built-in learned model's label and, in some tenants, a real rule name - so an alert naming it cannot be assumed to come from that rule."
  value       = local.builtin_rules
}

output "scope" {
  description = "What was actually queried, for troubleshooting. If a number looks wrong, this shows the inputs that produced it."
  value = local.raw == null ? null : {
    window_days  = tonumber(local.raw.window_days)
    alert_status = local.raw.alert_status
    note         = "alert_status materially changes which rules appear: a rule whose alerts are all resolved or dismissed is invisible under `open`."
  }
}
