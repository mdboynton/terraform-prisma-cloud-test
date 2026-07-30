#output "app_owner_readonly_singleton_permission_group_id" {
#  description = "The ID of the shared read-only Permission Group. Supply this value as the permission_group_id input when calling the rbac module for each team."
#  value       = prismacloud_permission_group.app_owner_readonly_singleton.id
#}
#
## ----------------------------------------------------------------
## Per-team RBAC outputs — maps keyed by team name (module instance key).
## ----------------------------------------------------------------
#output "team_role_ids" {
#  description = "Map of team name => Prisma Cloud Role ID. Hand off to the IdP for SAML group mapping (see module README §idp-handoff-contract)."
#  value       = { for name, m in module.prisma_cloud_rbac : name => m.team_role_id }
#}
#
#output "team_account_group_ids" {
#  description = "Map of team name => { Account Group name => Account Group ID }."
#  value       = { for name, m in module.prisma_cloud_rbac : name => m.account_group_ids }
#}
#
#output "team_resource_list_ids" {
#  description = "Map of team name => { Resource List name => Resource List ID }."
#  value       = { for name, m in module.prisma_cloud_rbac : name => m.resource_list_ids }
#}
#
#output "team_auto_collection_expected_names" {
#  description = "Map of team name => { Resource List name => expected auto-spawned Collection name }. Verify in UI under Inventory → Collections."
#  value       = { for name, m in module.prisma_cloud_rbac : name => m.auto_collection_expected_names }
#}
#
#output "team_resource_list_collection_ids" {
#  description = "Map of team name => { Resource List name => resolved auto-spawned Collection ID } (looked up by name from the live tenant; null when absent)."
#  value       = { for name, m in module.prisma_cloud_rbac : name => m.resource_list_collection_ids }
#}
#
#output "team_dashboard_collection_ids" {
#  description = "Map of team name => dedicated dashboard Collection ID (Terraform-managed; distinct from the per-Resource-List auto-spawned Collections)."
#  value       = { for name, m in module.prisma_cloud_rbac : name => m.dashboard_collection_id }
#}
#
#output "team_alert_rule_ids" {
#  description = "Map of team name => CSPM Alert Rule ID (policy scan config ID)."
#  value       = { for name, m in module.prisma_cloud_rbac : name => m.alert_rule_id }
#}
#
## ----------------------------------------------------------------
## Inventory (read-only) — single source of truth for reconcile/cleanup.
## Raw listings expose EVERYTHING in the tenant (including resources created
## outside Terraform and the auto-spawned collections). The filtered_* variants
## heuristically narrow to artifacts matching the module's DEFAULT naming.
## ----------------------------------------------------------------
#output "inventory_account_groups" {
#  description = "All Account Groups in the tenant: list of { group_id, name }."
#  value       = [for ag in data.prismacloud_account_groups.all.listing : { group_id = ag.group_id, name = ag.name }]
#}
#
#output "inventory_resource_lists" {
#  description = "All Resource Lists in the tenant: list of { id, name }."
#  value       = [for rl in data.prismacloud_resource_lists.all.listing : { id = rl.id, name = rl.name }]
#}
#
#output "inventory_collections" {
#  description = "All Collections in the tenant (includes the per-Resource-List auto-spawned ones): list of { id, name }."
#  value       = [for c in data.prismacloud_collections.all.listing : { id = c.id, name = c.name }]
#}
#
#output "inventory_user_roles" {
#  description = "All User Roles in the tenant: list of { role_id, name }."
#  value       = [for r in data.prismacloud_user_roles.all.listing : { role_id = r.role_id, name = r.name }]
#}
#
#output "inventory_user_profiles" {
#  description = "All User Profiles in the tenant: list of { profile_id, username }."
#  value       = [for p in data.prismacloud_user_profiles.all.listing : { profile_id = p.profile_id, username = p.username }]
#}
#
#output "inventory_permission_groups" {
#  description = "All Permission Groups in the tenant: list of { name, type }."
#  value       = [for pg in data.prismacloud_permission_groups.all.listing : { name = pg.name, type = pg.permission_group_type }]
#}
#
## Heuristic filters matching the module's DEFAULT naming conventions. Teams using
## custom *_name_suffix overrides will not appear here — use the raw lists above.
#output "inventory_module_like_collections" {
#  description = "Collections whose names look module-managed: the dedicated dashboard Collections (suffix '-collection') and the per-Resource-List auto-spawned ones (' - Access Group (RBAC)')."
#  value = [
#    for c in data.prismacloud_collections.all.listing : { id = c.id, name = c.name }
#    if endswith(c.name, local._collection_suffix) || strcontains(c.name, local._auto_coll_marker)
#  ]
#}
#
#output "inventory_module_like_account_groups" {
#  description = "Account Groups whose names end in the default '-account-group' suffix."
#  value       = [for ag in data.prismacloud_account_groups.all.listing : ag.name if endswith(ag.name, local._ag_suffix)]
#}
#
#output "inventory_module_like_resource_lists" {
#  description = "Resource Lists whose names end in the default '-resource-list' suffix."
#  value       = [for rl in data.prismacloud_resource_lists.all.listing : rl.name if endswith(rl.name, local._rl_suffix)]
#}
#
#output "inventory_module_like_user_roles" {
#  description = "User Roles whose names end in the default '-role' suffix."
#  value       = [for r in data.prismacloud_user_roles.all.listing : r.name if endswith(r.name, local._role_suffix)]
#}
#
## ----------------------------------------------------------------
## Per-team service account credentials. SENSITIVE — the secret key is returned
## by Prisma Cloud only once, at creation, and is persisted in Terraform state.
## Treat the state file as a secret.
## ----------------------------------------------------------------
#output "team_service_account_access_key_ids" {
#  description = "Map of team name => service account Access Key ID (null for teams without a service account)."
#  value       = { for name, m in module.prisma_cloud_rbac : name => m.service_account_access_key_id }
#}
#
#output "team_service_account_secret_keys" {
#  description = "Map of team name => service account Secret Key (null for teams without a service account). SENSITIVE."
#  value       = { for name, m in module.prisma_cloud_rbac : name => m.service_account_secret_key }
#  sensitive   = true
#}

# ----------------------------------------------------------------
# Compute-native Collections created by the RBAC module.
#
# These are the ONLY team collections usable as `add_collection` in
# config/compute-runtime-policies.yaml — CSPM collections are invisible to
# Compute, and the auto-spawned "<rl> - Access Group (RBAC)" ones are rejected
# by the runtime-policy API for illegal characters.
# ----------------------------------------------------------------
output "team_compute_collection_names" {
  description = "Map of team name => Compute-native Collection name (null for teams with compute_collection.enabled = false). Use this value as add_collection in config/compute-runtime-policies.yaml."
  value       = { for name, m in module.prisma_cloud_rbac : name => m.compute_collection_name }
}

# ----------------------------------------------------------------
# Compute runtime policy listing (read-only). Populated only when
# compute_runtime_list_enabled = true; otherwise null.
# ----------------------------------------------------------------

# Direction 1 — full dump of each runtime policy's rules + their collections.
output "compute_container_policy_rules" {
  description = "Full dump of the container runtime policy: [{ name, disabled, collections }]. Null unless compute_runtime_list_enabled."
  value       = module.compute_runtime_policies.container_policy_rules
}

output "compute_host_policy_rules" {
  description = "Full dump of the host runtime policy: [{ name, disabled, collections }]. Null unless compute_runtime_list_enabled."
  value       = module.compute_runtime_policies.host_policy_rules
}

# Direction 2 — collection -> rules index (which rules apply to a collection).
output "compute_container_rules_by_collection" {
  description = "Map of collection name => container runtime rule names referencing it (restricted to compute_runtime_list_collection when set). Null unless compute_runtime_list_enabled."
  value       = module.compute_runtime_policies.container_rules_by_collection
}

output "compute_host_rules_by_collection" {
  description = "Map of collection name => host runtime rule names referencing it (restricted to compute_runtime_list_collection when set). Null unless compute_runtime_list_enabled."
  value       = module.compute_runtime_policies.host_rules_by_collection
}

# Direction 3 — cluster => { collections, rules } (which rules apply to a cluster).
output "compute_container_rules_by_cluster" {
  description = "Map of cluster name => { collections, rules } for container runtime (cluster-specific collection matches). Populated when compute_runtime_list_clusters is set. Null unless compute_runtime_list_enabled."
  value       = module.compute_runtime_policies.container_rules_by_cluster
}

output "compute_host_rules_by_cluster" {
  description = "Map of cluster name => { collections, rules } for host runtime (cluster-specific collection matches). Populated when compute_runtime_list_clusters is set. Null unless compute_runtime_list_enabled."
  value       = module.compute_runtime_policies.host_rules_by_cluster
}

# ----------------------------------------------------------------
# Compute runtime policy association DRY RUN (read-only).
#
# WHY THESE MATTER: the association write is performed by a null_resource
# running a script, so `terraform plan` can only ever say "1 to add" — it
# cannot show what the script will actually do to the policy. These outputs
# are the real preview. For each configured association they report:
#
#   would_add       — collection is absent and WILL be appended
#   already_present — nothing to do (the merge is idempotent)
#   rule_not_found  — NO RULE MATCHES THAT NAME. The apply silently does
#                     nothing and still succeeds, so this is the one status
#                     that looks fine in the plan but means the config is wrong.
#
# Null when no associations of that kind are configured.
# ----------------------------------------------------------------

output "compute_container_preview" {
  description = "Dry-run of the CONTAINER runtime policy associations: per-association status (would_add | already_present | rule_not_found) plus the rule's existing collections. Null when no container associations are configured."
  value       = module.compute_runtime_policies.container_preview
}

output "compute_host_preview" {
  description = "Dry-run of the HOST runtime policy associations: per-association status (would_add | already_present | rule_not_found) plus the rule's existing collections. Null when no host associations are configured."
  value       = module.compute_runtime_policies.host_preview
}

# ----------------------------------------------------------------
# Tenant-level inventory (READ-ONLY). Null unless tenant_inventory_enabled.
# Sourced entirely from provider data sources — nothing here can write.
# ----------------------------------------------------------------

output "tenant_inventory" {
  description = "Read-only snapshot of tenant-level settings and configuration, keyed by category (enterprise_settings, trusted_login_ips, trusted_alert_ips, integrations, reports, notification_templates, anomaly_settings). Categories outside the requested scope are null. Null unless tenant_inventory_enabled."
  value       = module.tenant_inventory.inventory
}

output "tenant_inventory_summary" {
  description = "Compact count-per-category summary of the tenant inventory, for a quick at-a-glance view without scrolling the full dump."
  value       = module.tenant_inventory.summary
}

# ----------------------------------------------------------------
# Access audit (READ-ONLY). Null unless access_audit_enabled.
# ----------------------------------------------------------------

output "access_audit_summary" {
  description = "Counts per category (roles, users, permission groups) plus the flags that produced them. Contains no usernames, so it is safe to publish."
  value       = module.access_audit.summary
}

output "access_audit_findings" {
  description = "The rows an access review acts on: unassigned roles, and users that are disabled, stale, never-logged-in, or hold no roles. Honors access_audit_redact_usernames."
  value       = module.access_audit.findings
}

output "access_audit_roles" {
  description = "Full role listing with assigned-user and account-group counts. Null when out of scope."
  value       = module.access_audit.roles
}

output "access_audit_users" {
  description = "Full user listing with enabled/stale/never-logged-in flags. Honors access_audit_redact_usernames. Null when out of scope."
  value       = module.access_audit.users
}

output "access_audit_permission_groups" {
  description = "Full permission-group listing with custom vs built-in. Null when out of scope."
  value       = module.access_audit.permission_groups
}
