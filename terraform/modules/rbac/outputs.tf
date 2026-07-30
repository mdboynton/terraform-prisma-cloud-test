# ----------------------------------------------------------------
# Role
# ----------------------------------------------------------------

output "team_role_id" {
  description = "ID of the team's Prisma Cloud role. Hand off to IdP for SAML group mapping. See README §idp-handoff-contract."
  value       = prismacloud_user_role.team.role_id
}

output "team_role_name" {
  description = "Name of the team's Prisma Cloud role. Paired with team_role_id for the IdP handoff."
  value       = prismacloud_user_role.team.name
}

# ----------------------------------------------------------------
# Account Groups
# ----------------------------------------------------------------

output "account_group_ids" {
  description = "Map of Account Group name => Account Group ID for every Account Group created for the team."
  value       = { for k, ag in prismacloud_account_group.team : ag.name => ag.group_id }
}

output "account_group_names" {
  description = "List of Account Group names created for the team."
  value       = [for k, ag in prismacloud_account_group.team : ag.name]
}

# ----------------------------------------------------------------
# Resource Lists
# ----------------------------------------------------------------

output "resource_list_ids" {
  description = "Map of Resource List name => Resource List ID for every Resource List created for the team."
  value       = { for k, rl in prismacloud_resource_list.team : rl.name => rl.id }
}

output "resource_list_names" {
  description = "List of Resource List names created for the team. Each is embedded in its auto-spawned Collection's name."
  value       = [for k, rl in prismacloud_resource_list.team : rl.name]
}

# Constructed strings (not a data source) — see README §auto-collection-verification.
output "auto_collection_expected_names" {
  description = "Map of Resource List name => expected name of the Collection auto-spawned by Prisma Cloud for that Resource List. Verify in UI under Inventory → Collections. If missing, check the tenant's Collections quota (default 200) — quota exhaustion silently suppresses the auto-spawn."
  value       = { for k, rl in prismacloud_resource_list.team : rl.name => "${rl.name} - Access Group (RBAC)" }
}

# Resolved from the live tenant via the prismacloud_collections data source by
# matching the constructed auto-collection name. A null value means the expected
# Collection was not found (e.g. not yet spawned, or Collections quota exhausted).
output "resource_list_collection_ids" {
  description = "Map of Resource List name => the ID of the Collection that Prisma Cloud auto-spawned for it (resolved by name from the live tenant). Null when the expected Collection is absent (not yet spawned or Collections quota exhausted)."
  value       = local.resource_list_collection_ids
}

# ----------------------------------------------------------------
# Dedicated dashboard filter collection
# ----------------------------------------------------------------

output "dashboard_collection_id" {
  description = "ID of the team's dedicated dashboard Collection (Terraform-managed; distinct from the per-Resource-List auto-spawned Collections). Use this to scope dashboards/widgets to the team."
  value       = prismacloud_collection.team_dashboard_filter.id
}

output "dashboard_collection_name" {
  description = "Name of the team's dedicated dashboard Collection."
  value       = prismacloud_collection.team_dashboard_filter.name
}

# ----------------------------------------------------------------
# Compute-native Collection
# ----------------------------------------------------------------

output "compute_collection_name" {
  description = "Name of the team's Compute-native Collection — the value to use as `add_collection` in config/compute-runtime-policies.yaml. Null when compute_collection_enabled = false. Unlike the CSPM Collections, this one is visible to Compute AND satisfies the runtime-policy charset rule."
  value       = var.compute_collection_enabled ? prismacloudcompute_collection.team_workloads[0].name : null
}

# ----------------------------------------------------------------
# Alert Rule
# ----------------------------------------------------------------

output "alert_rule_id" {
  description = "ID (policy scan config ID) of the team's CSPM Alert Rule."
  value       = prismacloud_alert_rule.team.policy_scan_config_id
}

output "alert_rule_name" {
  description = "Name of the team's CSPM Alert Rule."
  value       = prismacloud_alert_rule.team.name
}

# ----------------------------------------------------------------
# Service Account (only when var.service_account_name is set)
# ----------------------------------------------------------------

output "service_account_username" {
  description = "Username of the team's service account, or null when no service account was created."
  value       = one(prismacloud_user_profile.service_account[*].username)
}

output "service_account_access_key_id" {
  description = "Access Key ID for the team's service account, or null when no service account was created."
  value       = one(prismacloud_user_profile.service_account[*].access_key_id)
}

output "service_account_secret_key" {
  description = "Secret Key for the team's service account access key, or null when no service account was created. Prisma Cloud returns this only once, at creation. Treat the Terraform state as a secret."
  value       = one(prismacloud_user_profile.service_account[*].secret_key)
  sensitive   = true
}
