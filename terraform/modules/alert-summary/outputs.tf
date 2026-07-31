# Null means "not asked for" (module disabled, or the collection did not
# resolve). Zero means "asked, and there are genuinely none". Collapsing the two
# would let a lookup failure read as a clean bill of health.

# ----------------------------------------------------------------
# Machine-readable status.
#
# WHY THIS EXISTS: the `check` blocks in main.tf emit warnings, and a failing
# check does NOT fail the plan - verified: a nonexistent collection name exits 0.
# Worse, `terraform show -json` omits the `checks` array entirely on a plan file,
# so a caller cannot detect the failure programmatically at all; the message only
# appears in human-readable stderr.
#
# A workflow must therefore branch on THIS value, not on the exit code.
# ----------------------------------------------------------------
output "status" {
  description = "ok | disabled | collection_not_found | ambiguous_collection_name | repository_only | tenant_wide. Callers must branch on this: a failed check does NOT fail the plan, and check results are absent from plan JSON."
  value = (
    !var.enabled ? "disabled" :
    var.collection_name == null ? "disabled" :
    length(local.matched_ids) == 0 ? "collection_not_found" :
    length(local.matched_ids) > 1 ? "ambiguous_collection_name" :
    local.repo_only ? "repository_only" :
    local.is_wildcard ? "tenant_wide" :
    "ok"
  )
}

output "status_detail" {
  description = "Human-readable explanation of `status`. Null when status is ok."
  value = (
    !var.enabled || var.collection_name == null ? "Module disabled." :
    length(local.matched_ids) == 0 ? "No CSPM Collection named '${var.collection_name}' exists in this tenant. No counts were produced - the number you want is NOT tenant_total." :
    length(local.matched_ids) > 1 ? "${length(local.matched_ids)} collections share the name '${var.collection_name}'. Cannot determine which was meant." :
    local.repo_only ? "Collection '${var.collection_name}' selects only code repositories, which CSPM alerts are not raised against." :
    local.is_wildcard ? "Collection '${var.collection_name}' selects ALL accounts, so any count would be tenant-wide rather than team-scoped." :
    null
  )
}

output "summary" {
  description = "Alert counts for the collection, plus the scope that produced them. Counts only - no alert detail, no resource names."
  value = local.enabled ? {
    collection    = var.collection_name
    collection_id = local.collection_id

    # What the query was ACTUALLY filtered by. Printed so a reader can tell
    # whether the number reflects the scope they had in mind.
    scoped_to_account_ids = local.account_ids
    account_count         = length(local.account_ids)

    status = var.alert_status
    window = "${var.time_amount} ${var.time_unit}"

    total       = local.scoped_total
    by_severity = local.scoped ? local.severity_counts : null

    # Tenant-wide count over the same window. Included deliberately: it gives
    # the reader proportion ("142 of 8869"), and it is the number the scoped
    # total would equal if the filter had been silently dropped.
    tenant_total = local.baseline_total

    # Advisory flags. A workflow should surface these rather than print the
    # count alone.
    is_tenant_wide     = local.is_wildcard
    suspect_unfiltered = local.suspect_unfiltered
  } : null
}

output "total" {
  description = "Alert count for the collection. Null when the module is disabled, the collection did not resolve, or the collection selects no cloud accounts - never silently a tenant-wide number."
  value       = local.scoped_total
}

output "by_severity" {
  description = "Map of severity to alert count within the collection's scope. Null when there is no scope to count."
  value       = local.scoped ? local.severity_counts : null
}

output "tenant_total" {
  description = "Tenant-wide alert count over the same window and status, for proportion and as the silent-drop reference value."
  value       = local.baseline_total
}

output "scope" {
  description = "How the collection was translated into alert filters. Exposed for troubleshooting: if a count looks wrong, this shows what was actually queried."
  value = local.enabled ? {
    collection_id  = local.collection_id
    account_ids    = local.account_ids
    repository_ids = local.repository_ids
    is_wildcard    = local.is_wildcard
    repo_only      = local.repo_only
    scoped         = local.scoped
  } : null
}
