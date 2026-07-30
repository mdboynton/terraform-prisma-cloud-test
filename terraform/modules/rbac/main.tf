locals {
  description = coalesce(var.team_description, "Managed by Terraform. Prisma Cloud resources for team: ${var.team_name}.")

  # Suffix vars are nullable to accept null passthroughs from try() at the root.
  # coalesce() restores the default when the caller passes null.
  account_group_name_suffix               = coalesce(var.account_group_name_suffix, "-ag")
  resource_list_name_suffix               = coalesce(var.resource_list_name_suffix, "-rl")
  role_name_suffix                        = coalesce(var.role_name_suffix, "-role")
  dashboard_filter_collection_name_suffix = coalesce(var.dashboard_filter_collection_name_suffix, "-assets")
  compute_collection_name_suffix          = coalesce(var.compute_collection_name_suffix, "-workloads")
  alert_rule_name_suffix                  = coalesce(var.alert_rule_name_suffix, "-alert-rule")

  # Compute-native Collection name. team_name is caller-supplied, so the charset
  # rule is re-checked on the ASSEMBLED name — validating only the suffix would
  # miss an illegal team_name.
  compute_collection_name = "${var.team_name}${local.compute_collection_name_suffix}"

  # Dedicated dashboard Collection name (distinct from the per-Resource-List
  # auto-spawned Collections).
  dashboard_filter_collection_name = "${var.team_name}${local.dashboard_filter_collection_name_suffix}"

  # Default name for a single Account Group / Resource List whose entry omits
  # its `name` (only valid for a single-entry list; validation forbids >1 null).
  default_account_group_name = "${var.team_name}${local.account_group_name_suffix}"
  default_resource_list_name = "${var.team_name}${local.resource_list_name_suffix}"

  # ----------------------------------------------------------------
  # Normalize Account Groups to a single internal map.
  #
  # The map KEY is the entry's resolved name (an unnamed single entry falls
  # back to the default name). The resolved `name` attribute is carried in the
  # value.
  # ----------------------------------------------------------------
  effective_account_groups = {
    for ag in var.account_groups : coalesce(ag.name, local.default_account_group_name) => {
      name                      = coalesce(ag.name, local.default_account_group_name)
      description               = ag.description
      account_ids               = ag.account_ids
      non_onboarded_account_ids = ag.non_onboarded_account_ids
    }
  }

  # ----------------------------------------------------------------
  # Normalize Resource Lists to a single internal map (same keying scheme).
  # ----------------------------------------------------------------
  effective_resource_lists = {
    for rl in var.resource_lists : coalesce(rl.name, local.default_resource_list_name) => {
      name                 = coalesce(rl.name, local.default_resource_list_name)
      description          = rl.description
      compute_access_group = rl.compute_access_group
    }
  }
}

resource "prismacloud_account_group" "team" {
  for_each = local.effective_account_groups

  name        = each.value.name
  description = each.value.description != null ? each.value.description : local.description
  account_ids = each.value.account_ids

  # NOTE (tuan_test branch): the prismacloud provider v1.7.1 does not accept a
  # `non_onboarded_account_ids` argument on prismacloud_account_group, so it is
  # omitted here to pass validation. The value is still accepted in teams.yaml /
  # the module variable but is not wired to the resource on this provider version.
}

# Side effect: each Resource List auto-spawns a read-only Collection named
# "<name> - Access Group (RBAC)". Surfaced via auto_collection_expected_names output.
resource "prismacloud_resource_list" "team" {
  for_each = local.effective_resource_lists

  name               = each.value.name
  description        = each.value.description != null ? each.value.description : local.description
  resource_list_type = "COMPUTE_ACCESS_GROUP"

  members {
    compute_access_groups {
      clusters   = each.value.compute_access_group.clusters
      namespaces = each.value.compute_access_group.namespaces
      images     = each.value.compute_access_group.images
      containers = each.value.compute_access_group.containers
      hosts      = each.value.compute_access_group.hosts
      labels     = each.value.compute_access_group.labels
      app_id     = each.value.compute_access_group.app_id
      functions  = each.value.compute_access_group.functions
      code_repos = each.value.compute_access_group.code_repos
    }
  }
}

# ----------------------------------------------------------------
# Dedicated dashboard filter Collection (one per team).
#
# This is SEPARATE from the read-only Collections that Prisma Cloud auto-spawns
# per Resource List. It exists so dashboard filters/widgets/functions that require
# a Collection can be scoped to the team. Scoped to the team's Account Group(s).
#
# CONSTRAINT: the prismacloud_collection resource only supports asset_groups by
# account_group_ids / account_ids / repository_ids — it does NOT support the
# workload-level (CAG) dimensions (clusters, namespaces, images, ...) that the
# Resource List carries. So this Collection scopes by Account Group, not by
# workload filters.
# ----------------------------------------------------------------
resource "prismacloud_collection" "team_dashboard_filter" {
  name        = local.dashboard_filter_collection_name
  description = var.dashboard_filter_collection_description != null ? var.dashboard_filter_collection_description : local.description

  asset_groups {
    account_group_ids = [for ag in prismacloud_account_group.team : ag.group_id]
  }

  # Create this dedicated Collection only after the Resource Lists exist. Each
  # Resource List auto-spawns its own Collection; creating this one concurrently
  # raced that side effect and produced a transient "object already exists".
  depends_on = [prismacloud_resource_list.team]
}

# ----------------------------------------------------------------
# Compute-native Collection (opt-in via compute_collection_enabled).
#
# WHY THIS EXISTS, given the team already gets two CSPM Collections:
#
#   1. CSPM and Compute keep SEPARATE collection stores. A prismacloud_collection
#      is invisible to the Compute console, so it cannot scope a runtime policy.
#   2. The Collection auto-spawned per Resource List IS visible to Compute, but
#      is named "<rl> - Access Group (RBAC)". The runtime-policy endpoint only
#      accepts names matching ^[A-Za-z0-9_:-]+$, so the spaces and parentheses
#      make every one of those Collections permanently unusable there.
#
# This resource is the only route to a Compute Collection that can actually be
# attached to a runtime rule by the compute-runtime-policies module. It mirrors
# the team's Resource List workload filters, so the runtime policy applies to
# the same workloads the team's RBAC scope covers.
# ----------------------------------------------------------------
resource "prismacloudcompute_collection" "team_workloads" {
  count = var.compute_collection_enabled ? 1 : 0

  name        = local.compute_collection_name
  description = local.description

  # Compute treats an empty list as "match nothing", so every unspecified
  # dimension must be an explicit ["*"] to mean "any".
  clusters          = length(var.compute_collection_clusters) > 0 ? var.compute_collection_clusters : ["*"]
  namespaces        = ["*"]
  images            = ["*"]
  containers        = ["*"]
  hosts             = ["*"]
  labels            = ["*"]
  functions         = ["*"]
  account_ids       = ["*"]
  application_ids   = ["*"]
  code_repositories = ["*"]

  lifecycle {
    precondition {
      condition     = can(regex("^[A-Za-z0-9_:-]+$", local.compute_collection_name))
      error_message = "Compute Collection name '${local.compute_collection_name}' contains characters the Compute runtime-policy API rejects. Allowed: A-Z a-z 0-9 _ - : (no spaces or parentheses). Adjust team_name or compute_collection_name_suffix."
    }
  }
}

# ----------------------------------------------------------------
# Resolve the Collection that Prisma Cloud auto-spawns for each Resource List.
#
# The auto-spawned Collection is named "<resource-list> - Access Group (RBAC)"
# and is NOT managed by Terraform, so we have no ID for it. The singular
# prismacloud_collection data source requires an ID, so we list ALL collections
# and match by the constructed name instead. See resource_list_collection_ids
# output.
# ----------------------------------------------------------------
data "prismacloud_collections" "all" {}

locals {
  # Expected auto-spawned Collection name per Resource List
  auto_collection_expected_names = {
    for k, rl in prismacloud_resource_list.team : rl.name => "${rl.name} - Access Group (RBAC)"
  }

  collections_by_name = {
    for c in data.prismacloud_collections.all.listing : c.name => c.id
  }

  # Resolve each Resource List's auto-spawned Collection ID by name.
  resource_list_collection_ids = {
    for rl_name, coll_name in local.auto_collection_expected_names :
    rl_name => lookup(local.collections_by_name, coll_name, null)
  }
}

resource "prismacloud_user_role" "team" {
  name        = "${var.team_name}${local.role_name_suffix}"
  description = var.role_description != null ? var.role_description : local.description

  # role_type must match the name of the attached Permission Group.
  role_type = var.permission_group_name

  # The single team Role binds ALL of the team's Account Groups and Resource Lists.
  account_group_ids = [for ag in prismacloud_account_group.team : ag.group_id]
  resource_list_ids = [for rl in prismacloud_resource_list.team : rl.id]

  # TODO: add attribute for "On-prem/Other cloud providers" control set to true/enabled
  # https://docs.prismacloud.io/en/enterprise-edition/content-collections/runtime-security/authentication/prisma-cloud-user-roles#:~:text=On%2Dprem/Other,Oracle%2C%20IBM%2C%20etc)

  additional_attributes {
    only_allow_read_access = true

    # SECURITY: AND-gated with computeManageDefenders. See README §security-trade-offs.
    has_defender_permissions = true

    only_allow_compute_access = false
    only_allow_ci_access      = false
  }

  lifecycle {
    ignore_changes = [
      additional_attributes,
    ]
  }
}

# ----------------------------------------------------------------
# Alert Rule (CSPM) — one per team, scoped to the team's Resource List.
# Optional per-team notification target.
#
# This is the CSPM alert surface (config / IAM / network / anomaly policies).
# Compute/CWP findings are NOT routed here — they flow through policy effects and
# the tag-based review workflow.
#
# CONSTRAINT: the Prisma Cloud alert/rule API rejects a target that sets BOTH a
# non-empty account_groups AND a resource_list (400 invalid_param_value
# subject:resource_lists). The target is therefore scoped by Resource List only,
# matching the tenant's working "VA All Cloud Compute Alert Rule".
#
# The notification integration referenced by var.alert_notification.config_type
# must already exist in the tenant; this resource references it, it does not
# create it.
# ----------------------------------------------------------------
resource "prismacloud_alert_rule" "team" {
  name        = "${var.team_name}${local.alert_rule_name_suffix}"
  description = var.alert_rule_description != null ? var.alert_rule_description : local.description

  enabled = true

  # Shared baseline policy selection unless an explicit policy set is supplied.
  scan_all          = length(var.alert_policies) > 0 ? false : var.alert_scan_all
  policies          = var.alert_policies
  excluded_policies = var.alert_excluded_policies

  target {
    # account_groups is intentionally omitted: the API rejects a target that
    # sets both account_groups and resource_list (see resource header comment).
    resource_list {
      compute_access_group_ids = [for rl in prismacloud_resource_list.team : rl.id]
    }

    # Severity baseline (high + critical by default). Omitted entirely when the
    # caller sets an empty/null severity list.
    dynamic "alert_rule_policy_filter" {
      for_each = length(coalesce(var.alert_severity_filter, [])) > 0 ? [1] : []
      content {
        policy_severity = var.alert_severity_filter
      }
    }
  }

  # optional per-team notification config 
  dynamic "notification_config" {
    for_each = var.alert_notification != null ? [var.alert_notification] : []
    content {
      config_type = notification_config.value.config_type
      recipients  = notification_config.value.recipients
      frequency   = notification_config.value.frequency
      enabled     = true
    }
  }

  lifecycle {
    ignore_changes = [target[0].alert_rule_policy_filter]
  }
}

# ----------------------------------------------------------------
# Service Account (optional) — created only when var.service_account_name is set.
# Prisma Cloud mints one access key as a side-effect of creating a
# SERVICE_ACCOUNT profile; the provider captures the create-response key id +
# secret into the computed access_key_id / secret_key attributes (see outputs).
#
# The tenant mandates access-key expiration (platform max 90 days). The absolute
# expiration timestamp is computed ONCE at create by time_offset and stored in
# state, so it does not drift on subsequent plans. access_key_expiration is an
# absolute epoch-MILLISECOND timestamp; time_offset.unix is seconds, so ×1000.
# ----------------------------------------------------------------
resource "time_offset" "access_key_expiration" {
  count = var.service_account_name != null ? 1 : 0

  offset_days = var.access_key_expiration_days
}

resource "prismacloud_user_profile" "service_account" {
  count = var.service_account_name != null ? 1 : 0

  account_type        = "SERVICE_ACCOUNT"
  username            = var.service_account_name
  default_role_id     = var.service_account_role_id
  access_key_name     = "${var.service_account_name}-key"
  role_ids            = [var.service_account_role_id]
  time_zone           = var.service_account_time_zone
  access_keys_allowed = true
  enabled             = true

  # Platform mandates key expiration; supply a compliant absolute timestamp.
  enable_key_expiration = true
  access_key_expiration = time_offset.access_key_expiration[0].unix * 1000

  # The expiration is fixed at create; ignore later clock-driven diffs.
  lifecycle {
    ignore_changes = [access_key_expiration]
  }
}

# ----------------------------------------------------------------
# Team members (optional) — grant the team Role to existing tenant users.
#
# Prisma Cloud has no "add user to role" primitive (the API ignores
# associatedUsers on role writes), so role membership is set via each user's
# profile role_ids. To avoid clobbering a user's other roles, we:
#   1. read each user's current profile (data source),
#   2. import/adopt the existing user into state (import block, keyed by email),
#   3. write back the UNION of their existing role_ids + the team Role.
#
# depends_on ensures all team resources (AGs, RLs, Role, service account) exist
# before any member assignment runs.
#
# DISABLED (tuan_test branch): Terraform only allows `import` blocks in the ROOT
# module, not inside a child module — so `terraform init` fails outright while
# this block lives here, regardless of whether team_members is empty. The test
# config uses no members, so the whole members feature is commented out to unblock
# the RBAC smoke test. Proper fix: hoist the import into the root module keyed by
# team+email (module.prisma_cloud_rbac[team].prismacloud_user_profile.member[email]).
# ----------------------------------------------------------------
# data "prismacloud_user_profile" "member" {
#   for_each = toset(var.team_members)
#
#   profile_id = each.value
# }
#
# import {
#   for_each = toset(var.team_members)
#
#   to = prismacloud_user_profile.member[each.value]
#   id = each.value
# }
#
# resource "prismacloud_user_profile" "member" {
#   for_each = toset(var.team_members)
#
#   # Identity + non-role attributes are fed back from the live profile so the
#   # write does not change anything except adding the team Role.
#   account_type = data.prismacloud_user_profile.member[each.key].account_type
#   username     = data.prismacloud_user_profile.member[each.key].username
#   first_name   = data.prismacloud_user_profile.member[each.key].first_name
#   last_name    = data.prismacloud_user_profile.member[each.key].last_name
#   email        = data.prismacloud_user_profile.member[each.key].email
#   time_zone    = data.prismacloud_user_profile.member[each.key].time_zone
#   enabled      = data.prismacloud_user_profile.member[each.key].enabled
#
#   default_role_id = data.prismacloud_user_profile.member[each.key].default_role_id
#
#   # Union of the user's existing roles + this team's Role. distinct() dedupes
#   # in case the user is already a member.
#   role_ids = distinct(concat(
#     data.prismacloud_user_profile.member[each.key].role_ids,
#     [prismacloud_user_role.team.role_id],
#   ))
#
#   depends_on = [
#     prismacloud_account_group.team,
#     prismacloud_resource_list.team,
#     prismacloud_user_role.team,
#     prismacloud_user_profile.service_account,
#   ]
# }
