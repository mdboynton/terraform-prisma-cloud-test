variable "enabled" {
  description = "(Optional) Read alert counts for a collection. Default false so this module costs nothing in workflows that don't need it."
  type        = bool
  default     = false
  nullable    = false
}

variable "collection_name" {
  description = "(Optional) Name of the CSPM Collection to scope alerts to, exactly as it appears in the console. Required when enabled is true. The collection's cloud accounts are what actually scope the query - see the module README for why a collection cannot be passed to the alerts API directly."
  type        = string
  default     = null
}

variable "time_amount" {
  description = "(Optional) Size of the lookback window, paired with time_unit. Alerts are unbounded without a time range, so this is always applied."
  type        = number
  default     = 30
  nullable    = false

  validation {
    condition     = var.time_amount >= 1
    error_message = "time_amount must be at least 1."
  }
}

variable "time_unit" {
  description = "(Optional) Unit of the lookback window: hour | day | week | month | year."
  type        = string
  default     = "day"
  nullable    = false

  validation {
    condition     = contains(["hour", "day", "week", "month", "year"], var.time_unit)
    error_message = "time_unit must be one of: hour, day, week, month, year."
  }
}

variable "alert_status" {
  description = "(Optional) Which alert status to count: open | resolved | dismissed | snoozed."
  type        = string
  default     = "open"
  nullable    = false

  validation {
    condition     = contains(["open", "resolved", "dismissed", "snoozed"], var.alert_status)
    error_message = "alert_status must be one of: open, resolved, dismissed, snoozed."
  }
}

variable "severities" {
  description = "(Optional) Severities to break the count down by. Each produces one additional query."
  type        = list(string)
  default     = ["critical", "high", "medium", "low", "informational"]
  nullable    = false
}
