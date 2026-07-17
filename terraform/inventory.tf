# ============================================================
# Inventory data sources (read-only)
#
# Single source of truth for enumerating every resource type this configuration
# creates/manages — INCLUDING resources that are not in Terraform state (e.g. the
# Collections that Prisma Cloud auto-spawns per Resource List, or artifacts left
# behind by a removed team). Use these for reconcile / cleanup audits: diff what
# exists in the tenant against config/teams.yaml.
#
# These are purely informational; they create nothing and are safe to read on
# every plan. The filtered_* outputs below match the module's DEFAULT naming
# conventions; teams using custom *_name_suffix overrides may need the raw
# listings instead.
# ============================================================

data "prismacloud_account_groups" "all" {}
data "prismacloud_resource_lists" "all" {}
data "prismacloud_collections" "all" {}
data "prismacloud_user_roles" "all" {}
data "prismacloud_user_profiles" "all" {}
data "prismacloud_permission_groups" "all" {}

locals {
  # Default-convention name fragments used to heuristically match module-managed
  # artifacts in the tenant. Teams with custom suffixes won't match these —
  # consult the raw listings (inventory_* outputs) in that case.
  _ag_suffix         = "-account-group"
  _rl_suffix         = "-resource-list"
  _role_suffix       = "-role"
  _collection_suffix = "-collection"
  _auto_coll_marker  = " - Access Group (RBAC)"
}
