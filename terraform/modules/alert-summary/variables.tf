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

# ----------------------------------------------------------------
# Per-alert detail (opt-in, additive).
#
# The counts above come from the provider's data source. The detail below comes
# from a script, because the provider's `listing` carries no policy name, no
# resource name and no severity. The two paths are deliberately independent:
# `total` is always the SERVER's count and never becomes "however many rows we
# happened to fetch".
# ----------------------------------------------------------------

variable "include_detail" {
  description = "(Optional) Also fetch per-alert detail (policy name, resource name, type, region) for the severities in detail_severities. Adds one paged API call. Counts are unaffected either way."
  type        = bool
  default     = false
  nullable    = false
}

variable "detail_severities" {
  description = "(Optional) Which severities to fetch detail for. Defaults to critical only: detail is ~263 bytes per alert, so widening this to every severity on a large collection produces a large artifact and a slow run. Everything fetched here lands in the JSON artifact; only critical is rendered in the workflow summary."
  type        = list(string)
  default     = ["critical"]
  nullable    = false

  validation {
    condition = length(setsubtract(toset(var.detail_severities),
    toset(["critical", "high", "medium", "low", "informational"]))) == 0
    error_message = "detail_severities may only contain: critical, high, medium, low, informational."
  }

  validation {
    condition     = length(var.detail_severities) > 0
    error_message = "detail_severities must not be empty. Set include_detail = false instead."
  }
}

variable "detail_limit" {
  description = "(Optional) Hard cap on how many alert detail rows to fetch. Exists to bound runtime and artifact size on large collections - the tenant holds ~9,000 open alerts. When the cap truncates, the `detail` output sets truncated = true and still reports the true total_matching."
  type        = number
  default     = 500
  nullable    = false

  validation {
    condition     = var.detail_limit >= 1 && var.detail_limit <= 5000
    error_message = "detail_limit must be between 1 and 5000."
  }
}

variable "cspm_url" {
  description = "(Optional) Prisma Cloud CSPM API host, e.g. \"api2.prismacloud.io\". Required only when include_detail is true - the detail script calls the REST API directly, so it cannot borrow the provider's configuration."
  type        = string
  default     = null
}

variable "access_key" {
  description = "(Optional) Prisma Cloud access key ID. Required only when include_detail is true."
  type        = string
  default     = null
  sensitive   = true
}

variable "secret_key" {
  description = "(Optional) Prisma Cloud secret key. Required only when include_detail is true."
  type        = string
  default     = null
  sensitive   = true
}
