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
  }
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
