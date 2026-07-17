# ============================================================
# Required authentication variables
# These must be set via tfvars or the corresponding env vars.
# ============================================================

variable "prisma_cloud_api_url" {
  description = "(Required) The Prisma Cloud API URL for the target tenant (e.g. \"api.prismacloud.io\"). Can be supplied via the PRISMACLOUD_API_URL environment variable instead."
  type        = string
  default     = null

  validation {
    condition = var.prisma_cloud_api_url == null || var.prisma_cloud_api_url == "" || can(regex(
      "^api[234]?\\.(anz|eu|gov|ca|sg|uk|ind|jp|fr|id)?\\.?prismacloud\\.(io|cn)$",
      var.prisma_cloud_api_url
    ))
    error_message = "The prisma_cloud_api_url must be a valid Prisma Cloud API endpoint (e.g. api.prismacloud.io, api2.prismacloud.io, api.gov.prismacloud.io, api.eu.prismacloud.io, api.prismacloud.cn)."
  }
}

variable "prisma_cloud_access_key" {
  description = "(Required) The Prisma Cloud access key ID (UUID format) used for authentication. Can be supplied via the PRISMACLOUD_USERNAME environment variable instead."
  type        = string
  sensitive   = true
  default     = null

  validation {
    condition = var.prisma_cloud_access_key == null || var.prisma_cloud_access_key == "" || can(regex(
      "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$",
      var.prisma_cloud_access_key
    ))
    error_message = "The prisma_cloud_access_key must be a valid UUID (e.g. '00000000-0000-0000-0000-000000000000')."
  }
}

variable "prisma_cloud_secret_key" {
  description = "(Required) The Prisma Cloud secret key used for authentication. Can be supplied via the PRISMACLOUD_PASSWORD environment variable instead."
  type        = string
  sensitive   = true
  default     = null
}

# ============================================================
# Optional provider configuration variables
# ============================================================

variable "prisma_cloud_customer_name" {
  description = "(Optional) The Prisma Cloud customer/tenant name. Required only when multiple tenants share the same credentials. Defaults to empty (single-tenant). Can be supplied via the PRISMACLOUD_CUSTOMER_NAME environment variable."
  type        = string
  default     = null
}

variable "prisma_cloud_protocol" {
  description = "(Optional) The protocol used to connect to the Prisma Cloud API. Defaults to 'https'. Can be supplied via the PRISMACLOUD_PROTOCOL environment variable."
  type        = string
  default     = null

  validation {
    condition     = var.prisma_cloud_protocol == null || contains(["https", "http"], var.prisma_cloud_protocol)
    error_message = "The prisma_cloud_protocol must be either 'https' or 'http'."
  }
}

variable "prisma_cloud_port" {
  description = "(Optional) A non-standard port to use for the Prisma Cloud API connection. Defaults to the standard port for the configured protocol (443 for https, 80 for http). Can be supplied via the PRISMACLOUD_PORT environment variable."
  type        = number
  default     = null

  validation {
    condition     = var.prisma_cloud_port == null || (var.prisma_cloud_port >= 1 && var.prisma_cloud_port <= 65535)
    error_message = "The prisma_cloud_port must be a valid port number between 1 and 65535."
  }
}

variable "prisma_cloud_timeout" {
  description = "(Optional) The HTTP request timeout in seconds for all Prisma Cloud API communications. Defaults to 90 seconds."
  type        = number
  default     = null

  validation {
    condition     = var.prisma_cloud_timeout == null || var.prisma_cloud_timeout > 0
    error_message = "The prisma_cloud_timeout must be a positive number of seconds."
  }
}

variable "prisma_cloud_skip_ssl_cert_verification" {
  description = "(Optional) If true, disables SSL certificate verification for Prisma Cloud API connections. Defaults to false. Not recommended for production. Can be supplied via the PRISMACLOUD_SKIP_SSL_CERT_VERIFICATION environment variable."
  type        = bool
  default     = null
}

variable "prisma_cloud_json_config_file" {
  description = "(Optional) Path to a JSON file containing Prisma Cloud provider configuration. When set, values in the file are used as defaults and can be overridden by other variables. Defaults to empty (not used)."
  type        = string
  default     = null
}

variable "prisma_cloud_json_web_token" {
  description = "(Optional) A JSON Web Token (JWT) to use in place of username/password authentication. Defaults to empty (username/password used). Can be supplied via the PRISMACLOUD_JSON_WEB_TOKEN environment variable."
  type        = string
  sensitive   = true
  default     = null
}

variable "prisma_cloud_logging" {
  description = "(Optional) A map of logging flags to enable for the Prisma Cloud provider API connection (e.g. { send = true, receive = true }). Defaults to no logging."
  type        = map(bool)
  default     = null
}

variable "prisma_cloud_max_retries" {
  description = "(Optional) The maximum number of retries for failed Prisma Cloud API requests due to rate limiting. Defaults to 5."
  type        = number
  default     = null

  validation {
    condition     = var.prisma_cloud_max_retries == null || var.prisma_cloud_max_retries >= 0
    error_message = "The prisma_cloud_max_retries must be a non-negative integer."
  }
}

variable "prisma_cloud_retry_max_delay" {
  description = "(Optional) The maximum delay in seconds between retries when using exponential backoff. Defaults to 30 seconds."
  type        = number
  default     = null

  validation {
    condition     = var.prisma_cloud_retry_max_delay == null || var.prisma_cloud_retry_max_delay >= 0
    error_message = "The prisma_cloud_retry_max_delay must be a non-negative number."
  }
}

variable "prisma_cloud_retry_type" {
  description = "(Optional) The retry strategy for failed Prisma Cloud API requests. Valid values: 'exponential_backoff', 'linear_backoff'. Defaults to 'exponential_backoff'."
  type        = string
  default     = null

  validation {
    condition     = var.prisma_cloud_retry_type == null || contains(["exponential_backoff", "linear_backoff"], var.prisma_cloud_retry_type)
    error_message = "The prisma_cloud_retry_type must be either 'exponential_backoff' or 'linear_backoff'."
  }
}

variable "prisma_cloud_disable_reconnect" {
  description = "(Optional) If true, disables automatic token reconnection when the JWT session expires. Defaults to false."
  type        = bool
  default     = null
}

# ============================================================
# Shared Permission Group naming
# Feature catalog lives in locals.tf; not configurable via variables.
# ============================================================

variable "permission_group_name" {
  description = "(Optional) Name of the shared Permission Group. If a PG of this name already exists in the tenant, either delete it in the UI before first apply, or set existing_permission_group_id to its UUID so Terraform adopts it instead of colliding."
  type        = string
  default     = "appowner-readonly-prmgrp"

  validation {
    condition     = length(var.permission_group_name) > 0
    error_message = "The permission_group_name must not be empty."
  }
}

variable "existing_permission_group_id" {
  description = "(Optional) UUID of a pre-existing Permission Group named permission_group_name in the tenant. When set, Terraform imports and adopts the existing PG on the next apply instead of attempting to create a new one (which would fail with a name-collision error). Leave null when no pre-existing PG exists."
  type        = string
  default     = "2235d5e3-1879-49f3-ac28-d43d1f418c10"
}

variable "permission_group_description" {
  description = "(Optional) Description for the shared Permission Group. Default mirrors the live tenant payload."
  type        = string
  default     = "VA Application Owner Read Only Permissions Group.  Assigned roles will be scoped to specific account groups and resource lists."
}
