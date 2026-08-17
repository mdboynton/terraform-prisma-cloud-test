variable "enabled" {
  description = "(Optional) Report which runtime rules are still firing. Default false so this module costs nothing in workflows that don't need it."
  type        = bool
  default     = false
  nullable    = false
}

variable "window_days" {
  description = "(Optional) How far back to look for runtime incidents. A rule that produced an incident inside this window is 'still firing'. NOTE: this is a RECURRENCE window, not a grace timer - see the module README for why age is not the measure."
  type        = number
  default     = 14
  nullable    = false

  validation {
    condition     = var.window_days >= 1 && var.window_days <= 3650
    error_message = "window_days must be between 1 and 3650."
  }
}

variable "max_alerts" {
  description = "(Optional) Cap on how many alerts are fetched for grouping. The window and tenant TOTALS are never capped by this - only the grouped table, which reports when it is incomplete."
  type        = number
  default     = 2000
  nullable    = false

  validation {
    condition     = var.max_alerts >= 1 && var.max_alerts <= 10000
    error_message = "max_alerts must be between 1 and 10000."
  }
}

variable "alert_status" {
  description = "(Optional) Which alert lifecycle state to report on. `open` is the digest's normal mode; `dismissed` is useful for reviewing what teams have accepted."
  type        = string
  default     = "open"
  nullable    = false

  validation {
    condition     = contains(["open", "resolved", "dismissed", "snoozed"], var.alert_status)
    error_message = "alert_status must be one of: open, resolved, dismissed, snoozed."
  }
}

# ----------------------------------------------------------------
# CSPM credentials.
#
# This module reads the CSPM alerts API - the same host and auth as the
# alert-summary module, NOT the Compute Console. Runtime incidents are promoted
# into CSPM as `workload_incident` alerts, and the promoted copy carries both
# the runtime rule name and the full dismissal lifecycle. See the README.
# ----------------------------------------------------------------

variable "cspm_url" {
  description = "(Optional) Prisma Cloud CSPM API host, e.g. \"api2.prismacloud.io\". Required when enabled is true."
  type        = string
  default     = null
}

variable "access_key" {
  description = "(Optional) Prisma Cloud access key id. Required when enabled is true."
  type        = string
  default     = null
  sensitive   = true
}

variable "secret_key" {
  description = "(Optional) Prisma Cloud secret key. Required when enabled is true."
  type        = string
  default     = null
  sensitive   = true
}
