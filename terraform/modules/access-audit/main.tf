# ============================================================
# access-audit - who has access to this tenant, and how.
#
# STRICTLY READ-ONLY. This module contains only `data` blocks; there is not a
# single `resource` in it, so it is structurally incapable of changing the
# tenant. Nothing to gate, no apply required.
#
# Answers the questions an access review asks:
#   - which roles exist, and who holds them
#   - which users are disabled, stale, or have never logged in
#   - which permission groups are custom vs built-in
# ============================================================

locals {
  all = var.scope == "all"

  want_roles             = var.enabled && (local.all || var.scope == "roles")
  want_users             = var.enabled && (local.all || var.scope == "users")
  want_permission_groups = var.enabled && (local.all || var.scope == "permission-groups")
}

data "prismacloud_user_roles" "this" {
  count = local.want_roles ? 1 : 0
}

data "prismacloud_user_profiles" "this" {
  count = local.want_users ? 1 : 0
}

data "prismacloud_permission_groups" "this" {
  count = local.want_permission_groups ? 1 : 0
}

locals {
  # ----------------------------------------------------------------
  # last_login_ts is epoch MILLISECONDS, and "never logged in" is -1
  # (verified against the live tenant: min -1, max ~1.78e12, 234 users at -1).
  #
  # -1 is why the stale check can't be a naive "older than cutoff": -1 is older
  # than every cutoff, so a user who never logged in would be counted as stale
  # AND as never-logged-in. The two are separated below so the counts don't
  # double-report the same person.
  #
  # The cutoff is computed with timeadd/timecmp on RFC3339 strings rather than
  # epoch arithmetic - those are exact, whereas approximating a year as a fixed
  # number of milliseconds drifts by a day every few years.
  #
  # plantimestamp() is a pure function, evaluated once per plan. Deliberately
  # NOT time_static: that is a RESOURCE, and a single resource anywhere in this
  # module would break the "contains no resources, therefore cannot write"
  # guarantee that makes it safe to run unguarded.
  # ----------------------------------------------------------------
  stale_cutoff_rfc3339 = timeadd(plantimestamp(), "-${var.stale_login_days * 24}h")

  roles_raw   = local.want_roles ? data.prismacloud_user_roles.this[0].listing : []
  users_raw   = local.want_users ? data.prismacloud_user_profiles.this[0].listing : []
  pgroups_raw = local.want_permission_groups ? data.prismacloud_permission_groups.this[0].listing : []

  # Stable pseudonym so a redacted report is still correlatable across runs
  # (the same person hashes the same) without exposing the address itself.
  redact = var.redact_usernames

  users = [
    for u in local.users_raw : {
      username        = local.redact ? substr(sha256(u.username), 0, 12) : u.username
      display_name    = local.redact ? substr(sha256(u.username), 0, 12) : u.display_name
      account_type    = u.account_type
      enabled         = u.enabled
      role_count      = length(u.role_ids)
      last_login_ts   = u.last_login_ts
      last_login      = u.last_login_ts > 0 ? formatdate("YYYY-MM-DD", timeadd("1970-01-01T00:00:00Z", "${floor(u.last_login_ts / 1000)}s")) : "never"
      never_logged_in = u.last_login_ts <= 0
      stale = u.last_login_ts > 0 && timecmp(
        timeadd("1970-01-01T00:00:00Z", "${floor(u.last_login_ts / 1000)}s"),
        local.stale_cutoff_rfc3339
      ) < 0
    }
  ]

  roles = [
    for r in local.roles_raw : {
      name                = r.name
      role_type           = r.role_type
      role_id             = r.role_id
      account_group_count = length(r.account_groups)
      # An assigned-to-nobody role is the single most useful signal in an access
      # review: it is either newly created, or left behind after offboarding.
      assigned_user_count = length(r.associated_users)
      unassigned          = length(r.associated_users) == 0
      last_modified_by    = r.last_modified_by
      last_modified_ts    = r.last_modified_ts
    }
  ]

  permission_groups = [
    for g in local.pgroups_raw : {
      name                  = g.name
      permission_group_type = g.permission_group_type
      custom                = g.custom
      accept_account_groups = g.accept_account_groups
      accept_resource_lists = g.accept_resource_lists
      last_modified_by      = g.last_modified_by
      last_modified_ts      = g.last_modified_ts
    }
  ]
}

