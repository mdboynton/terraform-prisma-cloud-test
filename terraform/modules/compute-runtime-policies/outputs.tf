# Decoded dry-run previews. Each is the per-association status computed against the
# LIVE policy at plan time: would_add | already_present | rule_not_found, plus the
# rule's existing collections. This is also the "list policies for this RBAC
# artifact" capability (requirement #3).

output "container_preview" {
  description = "Dry-run of the container runtime policy associations (status per rule). Null when no container associations are configured."
  value = local.manage_container ? jsondecode(base64decode(
    data.external.container_preview[0].result.result_b64
  )) : null
}

output "host_preview" {
  description = "Dry-run of the host runtime policy associations (status per rule). Null when no host associations are configured."
  value = local.manage_host ? jsondecode(base64decode(
    data.external.host_preview[0].result.result_b64
  )) : null
}

output "container_apply_id" {
  description = "ID of the null_resource that applied the container associations (proves the merge ran). Null when unmanaged."
  value       = local.manage_container ? null_resource.container_apply[0].id : null
}

output "host_apply_id" {
  description = "ID of the null_resource that applied the host associations (proves the merge ran). Null when unmanaged."
  value       = local.manage_host ? null_resource.host_apply[0].id : null
}

# ------------------------------------------------------------
# Read-only listing (enable_list). Null when enable_list = false.
# ------------------------------------------------------------

# Direction 1 — full dump: every rule with its attached collections.
output "container_policy_rules" {
  description = "Full dump of the CONTAINER runtime policy: list of { name, disabled, collections }. Null when enable_list = false."
  value = var.enable_list ? jsondecode(base64decode(
    data.external.container_list[0].result.result_b64
  )).full_dump : null
}

output "host_policy_rules" {
  description = "Full dump of the HOST runtime policy: list of { name, disabled, collections }. Null when enable_list = false."
  value = var.enable_list ? jsondecode(base64decode(
    data.external.host_list[0].result.result_b64
  )).full_dump : null
}

# Direction 2 — collection -> rules index (restricted to list_collection_filter
# when that is set). Answers "which runtime policy rules apply to this collection?"
output "container_rules_by_collection" {
  description = "Map of collection name -> CONTAINER runtime rule names that reference it. Restricted to list_collection_filter when set. Null when enable_list = false."
  value = var.enable_list ? jsondecode(base64decode(
    data.external.container_list[0].result.result_b64
  )).rules_by_collection : null
}

output "host_rules_by_collection" {
  description = "Map of collection name -> HOST runtime rule names that reference it. Restricted to list_collection_filter when set. Null when enable_list = false."
  value = var.enable_list ? jsondecode(base64decode(
    data.external.host_list[0].result.result_b64
  )).rules_by_collection : null
}

# Direction 3 — cluster -> { collections, rules }. Populated only when list_clusters
# is set. Answers "which runtime rules apply to this cluster?" via
# cluster -> cluster-specific collections -> rules.
output "container_rules_by_cluster" {
  description = "Map of cluster name -> { collections, rules } for the CONTAINER runtime policy (cluster-specific collection matches only). Empty map unless list_clusters is set. Null when enable_list = false."
  value = var.enable_list ? jsondecode(base64decode(
    data.external.container_list[0].result.result_b64
  )).rules_by_cluster : null
}

output "host_rules_by_cluster" {
  description = "Map of cluster name -> { collections, rules } for the HOST runtime policy (cluster-specific collection matches only). Empty map unless list_clusters is set. Null when enable_list = false."
  value = var.enable_list ? jsondecode(base64decode(
    data.external.host_list[0].result.result_b64
  )).rules_by_cluster : null
}
