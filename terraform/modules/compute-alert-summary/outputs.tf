# Null means "not asked for" (module disabled, or credentials absent). Zero
# means "asked, and there are genuinely none". Collapsing the two would let a
# misconfiguration read as a clean bill of health.

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
  description = "ok | disabled | missing_credentials | tenant_wide_scope | partial_image_scan. Callers must branch on this: a failed check does NOT fail the plan, and check results are absent from plan JSON."
  value = (
    !local.enabled ? "disabled" :
    !local.creds_present ? "missing_credentials" :
    local.result == null ? "disabled" :
    local.result.suspect_unfiltered ? "tenant_wide_scope" :
    !local.result.images_complete ? "partial_image_scan" :
    "ok"
  )
}

output "status_detail" {
  description = "Human-readable explanation of `status`. Null when status is ok."
  value = (
    !local.enabled ? "Module disabled." :
    !local.creds_present ? "Compute Console credentials were not supplied (console_url, access_key, secret_key). No counts were produced - this is NOT the same as finding nothing." :
    local.result == null ? "Module disabled." :
    local.result.suspect_unfiltered ? "Counts for '${local.collection_label}' equal the tenant-wide totals. Expected for an all-selecting collection, but also what a dropped filter looks like." :
    !local.result.images_complete ? "Vulnerability totals are a sample: ${local.result.images_scanned} of ${local.result.images} images scanned (stopped: ${local.result.images_stop_reason})." :
    null
  )
}

output "summary" {
  description = "Compute finding counts for the collection, plus the tenant-wide totals that produced them. Null when the module is disabled or credentials are absent."
  value       = local.result
}

# ----------------------------------------------------------------
# Individual counts, for callers that want one number without unwrapping the
# envelope. All null when nothing was queried - never silently zero.
# ----------------------------------------------------------------

output "incidents" {
  description = "Runtime incidents (container + host) within the collection's scope. Null when nothing was queried."
  value       = local.result == null ? null : local.result.incidents
}

output "incidents_unacked" {
  description = "Runtime incidents within scope that nobody has acknowledged. Null when nothing was queried."
  value       = local.result == null ? null : local.result.incidents_unacked
}

output "images" {
  description = "Images within the collection's scope. Null when nothing was queried."
  value       = local.result == null ? null : local.result.images
}

output "vulnerabilities" {
  description = "CVE instance counts by severity, summed across the images fetched. NOTE: these are CVE instances, not affected images, and they are a sample when summary.images_complete is false. Null when nothing was queried."
  value = local.result == null ? null : {
    critical = local.result.vuln_critical
    high     = local.result.vuln_high
    medium   = local.result.vuln_medium
    low      = local.result.vuln_low
  }
}

output "scope" {
  description = "How the collection was applied, for troubleshooting. If a count looks wrong, this shows what was actually queried and how it compares to the whole tenant."
  value = local.result == null ? null : {
    collection         = local.result.collection
    incidents_tenant   = local.result.incidents_tenant
    images_tenant      = local.result.images_tenant
    images_scanned     = local.result.images_scanned
    images_complete    = local.result.images_complete
    images_stop_reason = local.result.images_stop_reason
    suspect_unfiltered = local.result.suspect_unfiltered
  }
}
