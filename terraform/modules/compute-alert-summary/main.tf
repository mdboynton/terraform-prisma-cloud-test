# ============================================================
# compute-alert-summary - count Compute findings scoped to a COMPUTE collection.
#
# READ-ONLY BY CONSTRUCTION. The only block below is a `data` block, so a plan
# against this module can report but never change.
#
# WHY THIS IS NOT PART OF alert-summary:
# Prisma has TWO unrelated collection systems. The "<name> - Access Group (RBAC)"
# collections spawned by a Resource List are COMPUTE objects and do not exist on
# the CSPM side (verified: 0 of 46 CSPM collections). The CSPM module's only
# scoping lever is cloud.accountId, and 2,056 of 2,186 Compute collections are
# accountIDs:["*"] - so for a customer that onboards no cloud accounts, that path
# yields no scope by construction. Different host, different auth, different
# objects, non-comparable counts.
#
# See plans/compute-collection-scoping-findings.md.
# ============================================================

locals {
  enabled = var.enabled && var.collection_name != null && var.collection_name != ""

  # For use in error_message strings ONLY.
  #
  # A `check` block's error_message is evaluated even when the assertion passes
  # and even when this module is disabled. Interpolating a null variable there
  # raises "Invalid template interpolation value" and fails the ENTIRE plan -
  # every module, not just this one. This bit the alert-summary module and was
  # only found by running an untargeted plan; all workflows use -target, which
  # hides it.
  collection_label = coalesce(var.collection_name, "(none specified)")

  # Derived from sensitive variables, so the result inherits the taint. The
  # boolean itself reveals nothing, and the caller MUST be able to read it to
  # tell "misconfigured" from "genuinely no findings" - so it is explicitly
  # de-tainted rather than the output being marked sensitive, which would hide
  # exactly the signal the workflow needs.
  #
  # TEST FOR EMPTY, NOT JUST NULL. A missing GitHub secret does not arrive as
  # null - `TF_VAR_x: ${{ secrets.MISSING }}` sets the variable to the EMPTY
  # STRING. A null-only check passes, the script runs, and the plan hard-fails
  # with "console_url is empty" instead of reporting missing_credentials - so
  # the status output a workflow branches on never gets the chance to fire.
  # This is the exact case missing_credentials exists for, and it was silently
  # unreachable in CI.
  # NOT coalesce(): it treats "" as absent and raises "Error in function call"
  # when every argument is empty, which turns the very case being guarded into
  # a hard plan failure. `x != null && x != ""` is the safe form.
  creds_present = nonsensitive(
    var.console_url != null && var.console_url != "" &&
    var.access_key != null && var.access_key != "" &&
    var.secret_key != null && var.secret_key != ""
  )

  should_query = local.enabled && local.creds_present
}

# ------------------------------------------------------------
# The query.
#
# `external` is a DATA source: this preserves the zero-resource guarantee. A
# `terraform_data` or `null_resource` would have worked mechanically but would
# put a resource in the plan, which is the thing that makes this module safe to
# run unattended.
#
# The script hard-fails on an unknown collection name rather than returning
# zeros. That is deliberate: the API filter is exact-match and case-sensitive,
# and a name that matches nothing returns 0 - indistinguishable from a real but
# quiet collection. A failed plan is the correct outcome for a typo.
# ------------------------------------------------------------
data "external" "summary" {
  count = local.should_query ? 1 : 0

  program = ["bash", "${path.module}/scripts/summary.sh"]

  query = {
    console_url     = var.console_url
    access_key      = var.access_key
    secret_key      = var.secret_key
    collection_name = var.collection_name
    max_images      = tostring(var.max_images)
    skip_cert       = var.skip_cert_check ? "true" : "false"
  }
}

locals {
  raw = local.should_query ? data.external.summary[0].result : null

  # `data "external"` can only return a flat map of STRINGS. Numbers are
  # stringified by the script and converted back here so callers get real
  # numbers rather than having to parse them.
  result = local.raw == null ? null : {
    collection = local.raw.collection

    incidents         = tonumber(local.raw.incidents)
    incidents_unacked = tonumber(local.raw.incidents_unacked)

    images        = tonumber(local.raw.images)
    vuln_critical = tonumber(local.raw.vuln_critical)
    vuln_high     = tonumber(local.raw.vuln_high)
    vuln_medium   = tonumber(local.raw.vuln_medium)
    vuln_low      = tonumber(local.raw.vuln_low)

    # How many images the CVE totals were actually summed from. When this is
    # below `images`, the severity counts are a SAMPLE, not a total - which is
    # why it is reported rather than hidden.
    images_scanned     = tonumber(local.raw.images_scanned)
    images_complete    = local.raw.images_complete == "true"
    images_stop_reason = local.raw.images_stop_reason

    # Tenant-wide figures over the same query. Included for proportion, and
    # because they are the numbers the scoped counts would equal if the filter
    # had been silently dropped.
    incidents_tenant = tonumber(local.raw.incidents_tenant)
    images_tenant    = tonumber(local.raw.images_tenant)

    suspect_unfiltered = local.raw.suspect_unfiltered == "true"
  }
}

# GUARD: warn when the scoped counts match the tenant-wide counts.
#
# This is the signature of a silently-dropped filter - the failure mode that
# makes these APIs dangerous (the singular `collection=` parameter is ignored
# and returns all 14,409 incidents with HTTP 200). It is a `check` rather than a
# precondition because it CAN legitimately happen: a collection that selects
# everything, such as "All", genuinely equals the tenant. The reader is told;
# the plan is not failed on a true statement.
check "scope_is_not_tenant_wide" {
  assert {
    condition     = local.result == null || !local.result.suspect_unfiltered
    error_message = "Compute collection '${local.collection_label}' returned counts identical to the tenant-wide totals. This is expected for a collection that selects everything (e.g. \"All\"), but it is also what a silently-dropped filter looks like. Confirm the collection's scope before reading these numbers as team-specific."
  }
}

# GUARD: the CVE severity totals are a sample when the image cap is hit.
check "image_scan_is_complete" {
  assert {
    condition     = local.result == null || local.result.images_complete
    error_message = "Vulnerability severity totals for '${local.collection_label}' were summed from ${local.result == null ? 0 : local.result.images_scanned} of ${local.result == null ? 0 : local.result.images} images (stopped: ${local.result == null ? "n/a" : local.result.images_stop_reason}). They are a SAMPLE, not a total. Raise max_images for complete figures."
  }
}
