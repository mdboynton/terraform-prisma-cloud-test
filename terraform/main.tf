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
module "tenant_inventory" {
  source = "./modules/tenant-inventory"

  providers = {
    prismacloud = prismacloud
  }

  enabled = var.tenant_inventory_enabled
  scope   = var.tenant_inventory_scope
}
