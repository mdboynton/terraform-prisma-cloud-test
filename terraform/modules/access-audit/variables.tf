variable "enabled" {
  description = "(Optional) Read the tenant's access-control objects. Default false so this module costs nothing in workflows that don't need it."
  type        = bool
  default     = false
  nullable    = false
}

variable "scope" {
  description = "(Optional) Which category to read: all | roles | users | permission-groups. Anything out of scope reads nothing and its output is null (distinct from an empty list, which means 'read, found nothing')."
  type        = string
  default     = "all"
  nullable    = false

  validation {
    condition = contains([
      "all",
      "roles",
      "users",
      "permission-groups",
    ], var.scope)
    error_message = "scope must be one of: all, roles, users, permission-groups."
  }
}

variable "redact_usernames" {
  description = "(Optional) Replace each username/display name with a stable SHA-256 prefix. Usernames are email addresses, so this must be true anywhere output could be published (a public repo, an artifact shared outside the team). Off by default because the primary use — an access review — needs real names."
  type        = bool
  default     = false
  nullable    = false
}

variable "stale_login_days" {
  description = "(Optional) A user whose last login is older than this many days is reported as stale. Users who have NEVER logged in are always reported separately, regardless of this value."
  type        = number
  default     = 90
  nullable    = false

  validation {
    condition     = var.stale_login_days >= 1
    error_message = "stale_login_days must be at least 1."
  }
}
