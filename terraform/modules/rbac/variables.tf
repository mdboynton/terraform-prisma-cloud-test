variable "team_name" {
  description = "(Required) A short, lowercase-hyphenated identifier for the team (e.g. 'team-alpha'). Used in the creation of the Account Group, Resource List and Role for the target team (named '<team_name>-account-group', '<team_name>-resource-list', and '<team_name>-role' respectively)."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]*[a-z0-9]$", var.team_name))
    error_message = "The team_name must be lowercase alphanumeric with hyphens, and must not start or end with a hyphen."
  }
}

variable "team_description" {
  description = "(Optional) A human-readable description applied to the Account Group, Resource List, and Role created for this team. Defaults to empty."
  type        = string
  default     = null
}

# Per-resource description overrides for the team's singleton resources. Each
# falls back to the team-level description when null; an explicit "" is honored
# and sets an empty description in the tenant. (Per-Account-Group and
# per-Resource-List overrides live on the account_groups/resource_lists objects.)

variable "role_description" {
  description = "(Optional) Description for the team's Role. Null (default) falls back to team_description; an explicit empty string is honored."
  type        = string
  default     = null
}

variable "alert_rule_description" {
  description = "(Optional) Description for the team's CSPM Alert Rule. Null (default) falls back to team_description; an explicit empty string is honored."
  type        = string
  default     = null
}

variable "dashboard_filter_collection_description" {
  description = "(Optional) Description for the team's dedicated dashboard Collection. Null (default) falls back to team_description; an explicit empty string is honored."
  type        = string
  default     = null
}

variable "permission_group_id" {
  description = "(Required) The ID of the shared Permission Group."
  type        = string

  validation {
    condition     = length(var.permission_group_id) > 0
    error_message = "permission_group_id must not be empty."
  }
}

variable "permission_group_name" {
  description = "(Required) The name of the shared Permission Group. Used as the role_type value on the team's User Role — Prisma Cloud requires the role_type to match the Permission Group name when using a custom Permission Group."
  type        = string

  validation {
    condition     = length(var.permission_group_name) > 0
    error_message = "permission_group_name must not be empty."
  }
}

# ============================================================
# Account Groups / Resource Lists
#
# The team's single Role binds ALL account groups and ALL resource lists.
# ============================================================

variable "account_groups" {
  description = "(Optional) List of Account Groups to create for the team. Each entry's `name` defaults to `<team_name><account_group_name_suffix>` when omitted (only sensible for a single entry — provide explicit names when defining more than one). The team Role binds all of them."
  type = list(object({
    name                      = optional(string)
    description               = optional(string)
    account_ids               = optional(list(string), [])
    non_onboarded_account_ids = optional(list(string), [])
  }))
  default = []

  validation {
    condition = alltrue([
      for ag in var.account_groups : ag.name == null || length(ag.name) > 0
    ])
    error_message = "Each account_groups entry's name must be either null (to use the default) or a non-empty string."
  }

  validation {
    # When defining more than one Account Group, every entry must name itself,
    # otherwise the default-name collision would produce duplicate map keys.
    condition     = length(var.account_groups) <= 1 || alltrue([for ag in var.account_groups : ag.name != null])
    error_message = "When account_groups has more than one entry, every entry must specify a unique name."
  }
}

variable "resource_lists" {
  description = "(Optional) List of Resource Lists (Compute Access Groups) to create for the team. Each entry's `name` defaults to `<team_name><resource_list_name_suffix>` when omitted (only sensible for a single entry — provide explicit names when defining more than one). The team Role binds all of them; each auto-spawns its own Collection."
  type = list(object({
    name        = optional(string)
    description = optional(string)
    compute_access_group = optional(object({
      clusters   = optional(list(string), ["*"])
      namespaces = optional(list(string), ["*"])
      images     = optional(list(string), ["*"])
      containers = optional(list(string), ["*"])
      hosts      = optional(list(string), ["*"])
      labels     = optional(list(string), ["*"])
      app_id     = optional(list(string), ["*"])
      functions  = optional(list(string), ["*"])
      code_repos = optional(list(string), ["*"])
    }), {})
  }))
  default = []

  validation {
    condition = alltrue([
      for rl in var.resource_lists : rl.name == null || length(rl.name) > 0
    ])
    error_message = "Each resource_lists entry's name must be either null (to use the default) or a non-empty string."
  }

  validation {
    condition     = length(var.resource_lists) <= 1 || alltrue([for rl in var.resource_lists : rl.name != null])
    error_message = "When resource_lists has more than one entry, every entry must specify a unique name."
  }
}

# ============================================================
# Naming overrides (optional)
#
# Each suffix is concatenated onto `var.team_name` to form the corresponding
# resource's `name`. Passing `null` from the root module instantiation falls
# back to the default below — this allows per-team YAML overrides without
# every team having to specify every suffix.
# ============================================================

variable "account_group_name_suffix" {
  description = "(Optional) Suffix appended to team_name to form the Account Group's name. Default: `<team_name>-account-group`."
  type        = string
  default     = "-account-group"
  nullable    = true

  validation {
    condition     = var.account_group_name_suffix == null || length(var.account_group_name_suffix) > 0
    error_message = "The account_group_name_suffix must be either null (to use the default) or a non-empty string."
  }
}

variable "resource_list_name_suffix" {
  description = "(Optional) Suffix appended to team_name to form the Resource List (Compute Access Group)'s name. Default: `<team_name>-resource-list`. Note: this name is also embedded in the auto-spawned Collection's name (see `auto_collection_expected_name` output)."
  type        = string
  default     = "-resource-list"
  nullable    = true

  validation {
    condition     = var.resource_list_name_suffix == null || length(var.resource_list_name_suffix) > 0
    error_message = "The resource_list_name_suffix must be either null (to use the default) or a non-empty string."
  }
}

variable "role_name_suffix" {
  description = "(Optional) Suffix appended to team_name to form the Role's name. Default: `<team_name>-role`."
  type        = string
  default     = "-role"
  nullable    = true

  validation {
    condition     = var.role_name_suffix == null || length(var.role_name_suffix) > 0
    error_message = "The role_name_suffix must be either null (to use the default) or a non-empty string."
  }
}

variable "dashboard_filter_collection_name_suffix" {
  description = "(Optional) Suffix appended to team_name to form the dedicated dashboard Collection's name. This is a SEPARATE Collection from the one Prisma Cloud auto-spawns per Resource List; it exists so dashboards/functionality that require a Collection can be scoped to the team. NOTE: the prismacloud_collection resource scopes only by account group / account / repository — NOT by workload (CAG) filters. Default: `<team_name>-collection`."
  type        = string
  default     = "-collection"
  nullable    = true

  validation {
    condition     = var.dashboard_filter_collection_name_suffix == null || length(var.dashboard_filter_collection_name_suffix) > 0
    error_message = "The dashboard_filter_collection_name_suffix must be either null (to use the default) or a non-empty string."
  }
}

# ============================================================
# Compute Collection (Compute console — SEPARATE store from CSPM)
# ============================================================

variable "compute_collection_enabled" {
  description = "(Optional) Create a Compute-native Collection for the team, scoped by the same workload filters as the team's Resource List. Required if you want to attach the team to a runtime policy rule: CSPM Collections are not visible to Compute, and the auto-spawned `<rl> - Access Group (RBAC)` Collections are rejected by the runtime-policy API (illegal characters). Default: false."
  type        = bool
  default     = false
  nullable    = false
}

variable "compute_collection_name_suffix" {
  description = "(Optional) Suffix appended to team_name to form the Compute Collection's name. Default: `<team_name>-workloads`. The resulting name must satisfy the Compute API charset rule (A-Z a-z 0-9 _ - :)."
  type        = string
  default     = "-workloads"
  nullable    = true

  validation {
    condition     = var.compute_collection_name_suffix == null || length(var.compute_collection_name_suffix) > 0
    error_message = "The compute_collection_name_suffix must be either null (to use the default) or a non-empty string."
  }

  # Gate the charset at PLAN time. Without this the failure surfaces only as an
  # opaque HTTP 400 from the runtime-policy endpoint, at apply, after the
  # Collection already exists.
  validation {
    condition = (
      var.compute_collection_name_suffix == null ||
      can(regex("^[A-Za-z0-9_:-]+$", var.compute_collection_name_suffix))
    )
    error_message = "The compute_collection_name_suffix may only contain A-Z a-z 0-9 _ - : — no spaces or parentheses. The Compute runtime-policy API rejects any collection name outside this set."
  }
}

variable "compute_collection_clusters" {
  description = "(Optional) Cluster names for the team's Compute Collection. Defaults to [\"*\"] (all clusters) when empty, matching Compute's own default."
  type        = list(string)
  default     = []
  nullable    = false
}

# ============================================================
# Alert Rule (CSPM)
# ============================================================

variable "alert_rule_name_suffix" {
  description = "(Optional) Suffix appended to team_name to form the Alert Rule's name. Default: `<team_name>-alert-rule`."
  type        = string
  default     = "-alert-rule"
  nullable    = true

  validation {
    condition     = var.alert_rule_name_suffix == null || length(var.alert_rule_name_suffix) > 0
    error_message = "The alert_rule_name_suffix must be either null (to use the default) or a non-empty string."
  }
}

variable "alert_severity_filter" {
  description = "(Optional) Shared baseline list of policy severities the Alert Rule fires on (applied via the alert_rule_policy_filter). Default: high + critical. Set to [] to disable the severity filter."
  type        = list(string)
  default     = ["high", "critical"]
  nullable    = true

  validation {
    condition = var.alert_severity_filter == null || alltrue([
      for s in var.alert_severity_filter : contains(["informational", "low", "medium", "high", "critical"], s)
    ])
    error_message = "Each alert_severity_filter entry must be one of: informational, low, medium, high, critical."
  }
}

variable "alert_scan_all" {
  description = "(Optional) When true, the Alert Rule evaluates all policies (subject to the severity filter). When false, only the explicit `alert_policies` set is evaluated. Default: true."
  type        = bool
  default     = true
}

variable "alert_policies" {
  description = "(Optional) Explicit list of policy IDs the Alert Rule evaluates. Overrides scan_all when non-empty. Default: [] (use scan_all)."
  type        = list(string)
  default     = []
}

variable "alert_excluded_policies" {
  description = "(Optional) List of policy IDs to exclude from the Alert Rule's scan. Default: []."
  type        = list(string)
  default     = []
}

variable "alert_notification" {
  description = "(Optional) Per-team notification target for the Alert Rule. Null (default) = no notification_config (the rule is still created; alerts are visible in-console). The referenced integration/channel must ALREADY EXIST in the tenant — this does not create it. `config_type` is the channel kind (email, slack, jira, ...); `recipients` are channel-specific targets (e.g. email addresses); `frequency` controls digest cadence."
  type = object({
    config_type = string
    recipients  = optional(list(string), [])
    frequency   = optional(string, "asItHappens")
  })
  default = null

  validation {
    condition = var.alert_notification == null || contains(
      ["email", "slack", "splunk", "amazonSqs", "microsoftTeams", "jira", "webhook", "awsSecurityHub", "googleCscc", "serviceNow", "pagerDuty", "demisto", "azureServiceBusQueue", "snowflake", "awsS3"],
      try(var.alert_notification.config_type, "")
    )
    error_message = "alert_notification.config_type must be a supported Prisma Cloud integration type (e.g. email, slack, jira, serviceNow, pagerDuty, webhook)."
  }

  validation {
    condition = var.alert_notification == null || contains(
      ["asItHappens", "daily", "weekly", "monthly"],
      try(var.alert_notification.frequency, "asItHappens")
    )
    error_message = "alert_notification.frequency must be one of: asItHappens, daily, weekly, monthly."
  }
}

# ============================================================
# Service Account
# (Skipped if `service_account_name` is not set)
# ============================================================

variable "service_account_name" {
  description = "(Optional) When set (together with service_account_role_id), creates a Prisma Cloud SERVICE_ACCOUNT user profile for the team plus one access key. Unset = no service account."
  type        = string
  default     = null

  validation {
    condition     = var.service_account_name == null || length(var.service_account_name) > 0
    error_message = "service_account_name must be either null (no service account) or a non-empty string."
  }
}

variable "service_account_role_id" {
  description = "(Required when service_account_name is set) The Role ID assigned to the team's service account. Also used as the service account's default_role_id."
  type        = string
  default     = null

  validation {
    condition     = var.service_account_name == null || (var.service_account_role_id != null && length(var.service_account_role_id) > 0)
    error_message = "service_account_role_id is required (non-empty) when service_account_name is set."
  }
}

variable "service_account_time_zone" {
  description = "(Optional) Time zone for the service account profile (e.g. America/New_York)."
  type        = string
  default     = "America/New_York"

  validation {
    condition     = length(var.service_account_time_zone) > 0
    error_message = "service_account_time_zone must not be empty."
  }
}

variable "access_key_expiration_days" {
  description = "(Optional) Number of days from creation until the service account's access key expires. The tenant mandates key expiration with a platform maximum of 90 days, so this must be between 1 and 90. The absolute expiration timestamp is computed ONCE at create via the time_offset resource and stored in state, so it does not drift on subsequent plans."
  type        = number
  default     = 90

  validation {
    condition     = var.access_key_expiration_days >= 1 && var.access_key_expiration_days <= 90
    error_message = "access_key_expiration_days must be between 1 and 90 (the tenant's platform maximum)."
  }
}

# ============================================================
# Team members (optional)
#
# A list of email addresses for users that ALREADY EXIST in the Prisma Cloud
# tenant who should be granted the team Role. Prisma Cloud has no "add user to
# role" primitive — role membership is derived from each user's profile
# `role_ids` (the API silently ignores associatedUsers on role writes). So the
# module adopts each listed user (via an import block keyed by email) and writes
# back the UNION of their existing roles plus this team's Role, preserving any
# other roles they already hold.
#
# IMPORTANT: when a user is listed here, Terraform takes ownership of that user's
# entire profile (all role_ids, time_zone, enabled, etc.). Removing an email from
# the list removes the user from Terraform state but does NOT revoke the role —
# that must be done manually or by keeping the user listed with the role removed
# upstream. Assignment runs AFTER all other team resources via depends_on.
# ============================================================

variable "team_members" {
  description = "(Optional) List of email addresses of EXISTING tenant users to grant the team Role. The module preserves each user's other roles (union). Terraform takes ownership of these user profiles. Empty (default) = no members managed."
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for m in var.team_members : can(regex("^[^@[:space:]]+@[^@[:space:]]+$", m))
    ])
    error_message = "Each team_members entry must be a valid email address."
  }
}
