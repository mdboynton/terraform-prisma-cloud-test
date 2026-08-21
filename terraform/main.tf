import {
  for_each = var.existing_permission_group_id != null ? { pg = var.existing_permission_group_id } : {}
  to       = prismacloud_permission_group.app_owner_readonly_singleton
  id       = each.value
}

# Shared Permission Group for all teams. Feature catalog: locals.tf.
resource "prismacloud_permission_group" "app_owner_readonly_singleton" {
  name = "appowner-readonly-prmgrp"
  #name                  = var.permission_group_name
  description           = var.permission_group_description
  permission_group_type = "Custom"
  custom                = true
  accept_account_groups = true
  accept_resource_lists = true

  dynamic "features" {
    for_each = local.permission_group_features
    content {
      feature_name = features.key
      operations {
        read   = features.value.read
        update = features.value.update
        create = features.value.create
        delete = features.value.delete
      }
    }
  }
}

module "prisma_cloud_rbac" {
  source   = "./modules/rbac"
  for_each = local.teams

  providers = {
    prismacloud = prismacloud
    # Needed for the team's Compute-native Collection (compute_collection_enabled).
    prismacloudcompute = prismacloudcompute
  }

  team_name             = each.key
  team_description      = try(each.value.description, null)
  permission_group_id   = prismacloud_permission_group.app_owner_readonly_singleton.id
  permission_group_name = prismacloud_permission_group.app_owner_readonly_singleton.name

  # per-resource descriptions
  # null values will be overridden with `team_description`
  role_description                        = try(each.value.role_description, null)
  alert_rule_description                  = try(each.value.alert_rule_description, null)
  dashboard_filter_collection_description = try(each.value.dashboard_filter_collection_description, null)

  # Account Groups / Resource Lists for the team; the team Role binds all of them.
  account_groups = try(each.value.account_groups, [])
  resource_lists = try(each.value.resource_lists, [])

  # Optional per-team naming overrides; null = use module defaults.
  # Partial CAG objects rely on optional() defaults in the module variable schema.
  account_group_name_suffix               = try(each.value.account_group_name_suffix, null)
  resource_list_name_suffix               = try(each.value.resource_list_name_suffix, null)
  role_name_suffix                        = try(each.value.role_name_suffix, null)
  dashboard_filter_collection_name_suffix = try(each.value.dashboard_filter_collection_name_suffix, null)

  # per-team service account
  # skips creation if set to null
  service_account_name      = try(each.value.service_account.name, null)
  service_account_role_id   = try(each.value.service_account.role_id, null)
  service_account_time_zone = try(each.value.service_account.time_zone, "America/New_York")

  # Optional list of existing tenant user emails to grant the team Role.
  # Empty/unset = no members managed by Terraform.
  team_members = try(each.value.members, [])

  # Compute-native Collection for the team. Opt-in, because it is the ONLY
  # collection that can be attached to a runtime policy rule: CSPM Collections
  # are invisible to Compute, and the auto-spawned "<rl> - Access Group (RBAC)"
  # Collections are rejected by the runtime-policy API for illegal characters.
  compute_collection_enabled     = try(each.value.compute_collection.enabled, false)
  compute_collection_name_suffix = try(each.value.compute_collection.name_suffix, null)
  compute_collection_clusters    = try(each.value.compute_collection.clusters, [])

  # Optional per-team CSPM Alert Rule tuning; unset = module defaults
  # (high+critical severity, scan all policies, no notification config).
  alert_rule_name_suffix  = try(each.value.alert_rule.name_suffix, null)
  alert_severity_filter   = try(each.value.alert_rule.severity_filter, ["high", "critical"])
  alert_scan_all          = try(each.value.alert_rule.scan_all, true)
  alert_policies          = try(each.value.alert_rule.policies, [])
  alert_excluded_policies = try(each.value.alert_rule.excluded_policies, [])
  alert_notification      = try(each.value.alert_rule.notification, null)
}

# Attaches RBAC collections to EXISTING Compute runtime policy rules (container +
# host) so console-authored policies apply to a team's resources. Does not create
# or redefine policies. Driven by config/compute-runtime-policies.yaml. A no-op
# when that config has no associations.
module "compute_runtime_policies" {
  source = "./modules/compute-runtime-policies"

  console_url            = var.prisma_compute_console_url
  access_key             = var.prisma_cloud_access_key
  secret_key             = var.prisma_cloud_secret_key
  skip_cert_verification = coalesce(var.prisma_compute_skip_cert_verification, false)

  container_associations = local.compute_container_associations
  host_associations      = local.compute_host_associations

  # Read-only listing (Direction 1 full dump + Direction 2 collection->rules index
  # + Direction 3 cluster->rules when list_clusters is set).
  enable_list            = var.compute_runtime_list_enabled
  list_collection_filter = var.compute_runtime_list_collection
  list_clusters          = var.compute_runtime_list_clusters
}

# ============================================================
# Tenant-level inventory — STRICTLY READ-ONLY.
#
# Contains only `data` blocks; there is not a single `resource` in the module,
# so it is structurally incapable of changing the tenant. Nothing to gate, no
# apply required. Driven by the tenant-inventory.yml workflow.
# ============================================================
# ============================================================
# Access audit - STRICTLY READ-ONLY, same construction as tenant_inventory:
# only `data` blocks, zero `resource` blocks. Driven by access-audit.yml.
# ============================================================
module "access_audit" {
  source = "./modules/access-audit"

  providers = {
    prismacloud = prismacloud
  }

  enabled          = var.access_audit_enabled
  scope            = var.access_audit_scope
  redact_usernames = var.access_audit_redact_usernames
  stale_login_days = var.access_audit_stale_login_days
}

# ----------------------------------------------------------------
# Alert summary (read-only) - alert COUNTS scoped to a CSPM Collection.
#
# Counts only, by design: the alerts data source returns no resource or policy
# fields, and a tenant holds ~8,800 open alerts at ~20KB each detailed, so
# pulling alert bodies would bloat every plan. `limit = 1` reads the
# server-side `total` without the payload.
# ----------------------------------------------------------------
module "alert_summary" {
  source = "./modules/alert-summary"

  providers = {
    prismacloud = prismacloud
  }

  enabled         = var.alert_summary_enabled
  collection_name = var.alert_summary_collection_name
  time_amount     = var.alert_summary_time_amount
  time_unit       = var.alert_summary_time_unit
  alert_status    = var.alert_summary_status

  # Per-alert detail (opt-in). The counts above come from the provider; the
  # detail comes from a script that calls the REST API directly, so it needs
  # the credentials passed explicitly - it cannot read the provider block.
  include_detail    = var.alert_summary_include_detail
  detail_severities = var.alert_summary_detail_severities
  detail_limit      = var.alert_summary_detail_limit

  cspm_url   = var.prisma_cloud_api_url
  access_key = var.prisma_cloud_access_key
  secret_key = var.prisma_cloud_secret_key
}

# ----------------------------------------------------------------
# Compute alert summary (read-only) - finding counts scoped to a COMPUTE
# collection.
#
# The sibling of alert_summary above, NOT a replacement. That module answers
# "how many CSPM alerts for this CSPM collection"; this one answers "how many
# runtime incidents and image vulnerabilities for this COMPUTE collection".
#
# Both exist because Prisma has two unrelated collection systems, and the
# "<name> - Access Group (RBAC)" collections a Resource List spawns live only on
# the Compute side. A tenant that onboards no cloud accounts cannot be scoped by
# the CSPM module at all. The counts are NOT comparable - different objects.
# ----------------------------------------------------------------
module "compute_alert_summary" {
  source = "./modules/compute-alert-summary"

  enabled         = var.compute_alert_summary_enabled
  collection_name = var.compute_alert_summary_collection_name
  max_images      = var.compute_alert_summary_max_images

  # The script calls the Compute REST API directly, so it needs credentials
  # explicitly - it cannot read the prismacloudcompute provider block.
  console_url     = var.prisma_compute_console_url
  access_key      = var.prisma_cloud_access_key
  secret_key      = var.prisma_cloud_secret_key
  skip_cert_check = coalesce(var.prisma_compute_skip_cert_verification, false)
}

# ----------------------------------------------------------------
# Runtime grace digest (read-only) - which runtime rules are STILL FIRING?
#
# Reads promoted `workload_incident` CSPM alerts, so it uses the CSPM
# credentials above, NOT the Compute Console. The promoted alert carries the
# runtime rule name and occurrence count as well as the dismissal lifecycle;
# the raw Compute incident carries only an unattributed `acknowledged` flag.
#
# Reports RECURRENCE, not age. A runtime finding is an event that never closes,
# so "unresolved for N days" would select nearly everything ever recorded and
# would only measure whether anyone clicked acknowledge.
#
# This is the report-only stage of the escalation pipeline. It sends nothing and
# changes nothing. See plans/policy-escalation-findings.md.
# ----------------------------------------------------------------
module "runtime_grace_digest" {
  source = "./modules/runtime-grace-digest"

  enabled      = var.runtime_grace_digest_enabled
  window_days  = var.runtime_grace_digest_window_days
  max_alerts   = var.runtime_grace_digest_max_alerts
  alert_status = var.runtime_grace_digest_alert_status

  # Empty list = no severity filter, which is the default and is reported as
  # such rather than being presented as a scoped result.
  severities = var.runtime_grace_digest_severities

  # Grace warning: PLANNED ONLY. Works out who would be told a rule is heading
  # for escalation. The module has no send path, and every planned message is
  # addressed to the override, never to the owner addresses read from the
  # alerts. See the module README.
  notify_enabled             = var.runtime_grace_digest_notify_enabled
  grace_days                 = var.runtime_grace_digest_grace_days
  notify_days                = var.runtime_grace_digest_notify_days
  warning_recipient_override = var.runtime_grace_digest_warning_recipient

  # Day 0 for anything already open when the campaign was announced. An empty
  # string from an unset workflow input must arrive as null, not "", so the
  # module reports `no_campaign_start` rather than failing date parsing.
  campaign_start_date = (
    var.runtime_grace_digest_campaign_start_date == "" ? null : var.runtime_grace_digest_campaign_start_date
  )

  # The script calls the CSPM REST API directly, so it needs credentials
  # explicitly - it cannot read the prismacloud provider block.
  cspm_url   = var.prisma_cloud_api_url
  access_key = var.prisma_cloud_access_key
  secret_key = var.prisma_cloud_secret_key
}

# Reports the CURRENT ENFORCEMENT EFFECT of runtime rules that are producing
# alerts - the question workflow 8 cannot answer.
#
# It needs BOTH APIs. VERIFIED: the promoted CSPM alert carries no effect field
# at any depth, so enforcement state has to be read from the Compute Console
# policy objects and joined to the alert stream by rule name.
#
# Reading is unconditional; WRITING needs two separate deliberate acts:
# a non-empty `escalations` list AND apply_escalations set to exactly "APPLY".
# The write runs in a null_resource provisioner, so `terraform plan` stays
# read-only no matter how those variables are set.
module "runtime_rule_effects" {
  source = "./modules/runtime-rule-effects"

  enabled      = var.runtime_rule_effects_enabled
  window_days  = var.runtime_rule_effects_window_days
  alert_status = var.runtime_rule_effects_alert_status
  max_alerts   = var.runtime_rule_effects_max_alerts

  escalations       = var.runtime_rule_effects_escalations
  apply_escalations = var.runtime_rule_effects_apply

  cspm_url    = var.prisma_cloud_api_url
  compute_url = var.prisma_compute_console_url
  access_key  = var.prisma_cloud_access_key
  secret_key  = var.prisma_cloud_secret_key

  skip_cert_verification = var.prisma_compute_skip_cert_verification
}

module "tenant_inventory" {
  source = "./modules/tenant-inventory"

  providers = {
    prismacloud = prismacloud
  }

  enabled = var.tenant_inventory_enabled
  scope   = var.tenant_inventory_scope
}
