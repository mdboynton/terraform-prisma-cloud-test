# Null vs [] is meaningful throughout: null means "not in scope for this run",
# an empty list means "read the tenant and found none".

output "summary" {
  description = "Counts only - safe to print anywhere, contains no usernames. This is what the workflow renders as a table."
  value = {
    roles = local.want_roles ? {
      total      = length(local.roles)
      unassigned = length([for r in local.roles : r if r.unassigned])
      custom     = length([for r in local.roles : r if r.role_type != "System Admin"])
    } : null

    users = local.want_users ? {
      total            = length(local.users)
      enabled          = length([for u in local.users : u if u.enabled])
      disabled         = length([for u in local.users : u if !u.enabled])
      never_logged_in  = length([for u in local.users : u if u.never_logged_in])
      stale            = length([for u in local.users : u if u.stale])
      service_accounts = length([for u in local.users : u if u.account_type == "SERVICE_ACCOUNT"])
      no_roles         = length([for u in local.users : u if u.role_count == 0])
    } : null

    permission_groups = local.want_permission_groups ? {
      total   = length(local.permission_groups)
      custom  = length([for g in local.permission_groups : g if g.custom])
      builtin = length([for g in local.permission_groups : g if !g.custom])
    } : null

    stale_threshold_days = var.stale_login_days
    usernames_redacted   = var.redact_usernames
  }
}

# ----------------------------------------------------------------
# Findings - the subset an access review actually acts on. Separated from the
# full listings because these are the rows worth a human's attention, and a
# reviewer should not have to scan 845 users to find the 234 that matter.
# ----------------------------------------------------------------
output "findings" {
  description = "Rows that warrant review: unassigned roles, disabled/stale/never-logged-in users, users with no roles. Honors redact_usernames."
  value = {
    unassigned_roles = local.want_roles ? [
      for r in local.roles : { name = r.name, last_modified_by = r.last_modified_by }
      if r.unassigned
    ] : null

    never_logged_in = local.want_users ? [
      for u in local.users : { username = u.username, account_type = u.account_type, enabled = u.enabled }
      if u.never_logged_in
    ] : null

    stale_users = local.want_users ? [
      for u in local.users : { username = u.username, last_login = u.last_login, account_type = u.account_type }
      if u.stale
    ] : null

    disabled_users = local.want_users ? [
      for u in local.users : { username = u.username, account_type = u.account_type }
      if !u.enabled
    ] : null

    users_without_roles = local.want_users ? [
      for u in local.users : { username = u.username, account_type = u.account_type, enabled = u.enabled }
      if u.role_count == 0
    ] : null
  }
}

output "roles" {
  description = "Every role with its type, account-group count, and assigned-user count. Null when out of scope."
  value       = local.want_roles ? local.roles : null
}

output "users" {
  description = "Every user profile with enabled/stale/never-logged-in flags and role count. Honors redact_usernames. Null when out of scope."
  value       = local.want_users ? local.users : null
}

output "permission_groups" {
  description = "Every permission group with its type and custom flag. Null when out of scope."
  value       = local.want_permission_groups ? local.permission_groups : null
}
