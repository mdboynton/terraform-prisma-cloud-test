# ============================================================
# alert-summary - count CSPM alerts scoped to a Collection.
#
# READ-ONLY BY CONSTRUCTION. Every block below is a `data` block. There are NO
# `resource` blocks, so a plan against this module can only ever report, never
# change.
#
# WHY THIS IS NOT A ONE-LINER:
# the alerts API has no collection filter. Verified against the live tenant -
# it publishes 31 filter names and "collection" is not among them. A collection
# is only an `assetGroups` selector, so the module resolves the collection to
# its cloud accounts and filters by those instead.
#
# THE TRAP THIS MODULE EXISTS TO AVOID:
# an unrecognised filter NAME is silently dropped and the request still returns
# HTTP 200 with the FULL tenant-wide result set. Passing `collection=<name>`
# would have returned all ~8,800 alerts and looked entirely plausible. Every
# guard below exists because of that behaviour.
# ============================================================

locals {
  enabled = var.enabled && var.collection_name != null
}

# ------------------------------------------------------------
# Resolve the collection NAME to its id.
#
# `prismacloud_collection` takes an id, but a human knows the name, so the full
# listing is read first. This is one small call - collections are a handful of
# fields each, nothing like the alert payload.
# ------------------------------------------------------------
data "prismacloud_collections" "all" {
  count = local.enabled ? 1 : 0
}

locals {
  matched_ids = local.enabled ? [
    for c in data.prismacloud_collections.all[0].listing : c.id
    if c.name == var.collection_name
  ] : []

  collection_id = length(local.matched_ids) == 1 ? local.matched_ids[0] : null
}

# GUARD 1: the collection name must resolve to exactly one collection.
#
# This HARD FAILS rather than warning: if the name is wrong and we carried on,
# the query would run unfiltered and report tenant-wide alerts as if they
# belonged to the collection. Names are not unique by API contract, so 2+
# matches is equally unsafe - we cannot know which was meant.
#
# The precondition lives on the DATA SOURCE, not on a `terraform_data` resource.
# `terraform_data` would have worked, but it is a RESOURCE, and putting one here
# would break the zero-resource guarantee this module's value depends on. Data
# sources have supported lifecycle preconditions since Terraform 1.2.
data "prismacloud_collection" "this" {
  count = local.collection_id != null ? 1 : 0
  id    = local.collection_id

  lifecycle {
    precondition {
      condition     = length(local.matched_ids) == 1
      error_message = "Collection name '${var.collection_name}' did not resolve to exactly one collection (matched ${length(local.matched_ids)}). Refusing to continue: an unresolved name would silently produce TENANT-WIDE alert counts instead of an error."
    }
  }
}

# When the name matches nothing, count is 0 and the precondition above never
# runs - so the failure has to be raised somewhere that is always evaluated.
# `check` is the right tool: it is evaluated unconditionally and, unlike a
# resource, adds nothing to the plan.
check "collection_name_resolves" {
  assert {
    condition     = !local.enabled || length(local.matched_ids) == 1
    error_message = length(local.matched_ids) == 0 ? "No CSPM Collection named '${var.collection_name}' exists in this tenant. Check the spelling in the Prisma Cloud console. No alert counts were produced." : "${length(local.matched_ids)} collections are named '${var.collection_name}'. Cannot tell which was meant."
  }
}

# ------------------------------------------------------------
# Translate the collection's asset groups into alert filters.
# ------------------------------------------------------------
locals {
  # asset_groups is a SET, not a list, so it cannot be indexed with [0] -
  # "Elements of a set are identified only by their value". Flatten instead.
  asset_groups = local.collection_id != null ? data.prismacloud_collection.this[0].asset_groups : []

  raw_account_ids = distinct(flatten([for g in local.asset_groups : g.account_ids]))
  repository_ids  = distinct(flatten([for g in local.asset_groups : g.repository_ids]))

  # GUARD 2: "*" means "every account", not an account literally named "*".
  # Passing it through would filter for a nonexistent account and report 0.
  is_wildcard = contains(local.raw_account_ids, "*")
  account_ids = local.is_wildcard ? [] : local.raw_account_ids

  # A collection scoped only to code repositories has no cloud-alert meaning.
  repo_only = length(local.account_ids) == 0 && !local.is_wildcard && length(local.repository_ids) > 0

  # Whether the alert query is genuinely scoped. When wildcard, it is not -
  # the result is tenant-wide and the outputs say so rather than implying
  # the collection is small.
  scoped = length(local.account_ids) > 0
}

# ------------------------------------------------------------
# Baseline: the same query WITHOUT the account filter.
#
# This is the detector for the silent-drop behaviour. If the scoped count ever
# equals the baseline exactly, the account filter was probably ignored and the
# number is tenant-wide. `limit = 1` keeps the payload to a single row - `total`
# is a server-side count and does not depend on how many rows come back, so a
# count costs almost nothing.
# ------------------------------------------------------------
data "prismacloud_alerts" "baseline" {
  count = local.enabled ? 1 : 0
  limit = 1

  time_range {
    relative {
      amount = var.time_amount
      unit   = var.time_unit
    }
  }

  filters {
    name  = "alert.status"
    value = var.alert_status
  }
}

# ------------------------------------------------------------
# Scoped total.
#
# CRITICAL - one `filters` block PER ACCOUNT, never a comma-joined list.
# Verified on the live tenant:
#   account A alone              -> 188
#   account B alone              -> 271
#   repeated blocks (A, B)       -> 459   = 188 + 271, correct OR
#   single block "A,B" (CSV)     -> 0     WRONG, and silently so
# A CSV value looks reasonable and returns HTTP 200, so this would have
# under-reported every multi-account collection to zero.
# ------------------------------------------------------------
data "prismacloud_alerts" "scoped" {
  count = local.scoped ? 1 : 0
  limit = 1

  time_range {
    relative {
      amount = var.time_amount
      unit   = var.time_unit
    }
  }

  filters {
    name  = "alert.status"
    value = var.alert_status
  }

  dynamic "filters" {
    for_each = local.account_ids
    content {
      name  = "cloud.accountId"
      value = filters.value
    }
  }
}

# ------------------------------------------------------------
# Per-severity breakdown - one query each, counts only.
# ------------------------------------------------------------
data "prismacloud_alerts" "by_severity" {
  for_each = local.scoped ? toset(var.severities) : toset([])
  limit    = 1

  time_range {
    relative {
      amount = var.time_amount
      unit   = var.time_unit
    }
  }

  filters {
    name  = "alert.status"
    value = var.alert_status
  }

  filters {
    name  = "policy.severity"
    value = each.value
  }

  dynamic "filters" {
    for_each = local.account_ids
    content {
      name  = "cloud.accountId"
      value = filters.value
    }
  }
}

locals {
  baseline_total = local.enabled ? data.prismacloud_alerts.baseline[0].total : null
  scoped_total   = local.scoped ? data.prismacloud_alerts.scoped[0].total : null

  severity_counts = {
    for s, d in data.prismacloud_alerts.by_severity : s => d.total
  }

  # GUARD 4 (detection, not prevention): scoped == baseline is the signature of
  # a dropped filter. It CAN legitimately happen when the collection covers
  # every account with an alert, so this warns rather than fails.
  suspect_unfiltered = local.scoped && local.scoped_total == local.baseline_total

  # Severities are mutually exclusive, so they should sum to the total. A
  # mismatch means a severity value outside var.severities exists (or the
  # windows disagree) - worth surfacing rather than quietly showing a
  # breakdown that doesn't add up.
  severity_sum = local.scoped ? sum(concat([0], values(local.severity_counts))) : null
}

# A `check` block warns without failing the plan - correct for the two
# conditions above, which are suspicious rather than definitively wrong.
check "alert_counts_are_plausible" {
  # GUARD 3: a repository-only collection has no cloud-alert meaning.
  assert {
    condition     = !local.repo_only
    error_message = "Collection '${var.collection_name}' selects only code repositories (${length(local.repository_ids)} repositoryIds) and no cloud accounts. CSPM alerts are raised against cloud resources, so this collection cannot scope them. No scoped counts were produced."
  }

  assert {
    condition     = !local.suspect_unfiltered
    error_message = "Scoped alert count (${coalesce(local.scoped_total, 0)}) exactly equals the tenant-wide count (${coalesce(local.baseline_total, 0)}). The account filter may have been ignored - the alerts API drops unrecognised filters and still returns HTTP 200. This is legitimate only if collection '${var.collection_name}' covers every account that has alerts."
  }

  assert {
    condition     = !local.scoped || local.severity_sum == local.scoped_total
    error_message = "Severity breakdown sums to ${coalesce(local.severity_sum, 0)} but the total is ${coalesce(local.scoped_total, 0)}. Some alerts carry a severity outside var.severities, so the breakdown is incomplete."
  }
}
