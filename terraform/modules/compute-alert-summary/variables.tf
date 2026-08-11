variable "enabled" {
  description = "(Optional) Read Compute finding counts for a collection. Default false so this module costs nothing in workflows that don't need it."
  type        = bool
  default     = false
  nullable    = false
}

variable "collection_name" {
  description = "(Optional) Name of the COMPUTE collection to scope to, exactly as it appears in the Compute console (e.g. \"team-alpha-resource-list - Access Group (RBAC)\"). Required when enabled is true. This is NOT a CSPM collection - the two are separate systems. Compute collections have no id; the name IS the identifier, and the API filter is exact-match and case-sensitive."
  type        = string
  default     = null
}

variable "max_images" {
  description = "(Optional) Cap on how many images are fetched for the vulnerability rollup. The image counts and incident counts are NOT affected by this - only the CVE severity totals, which are summed from the images actually fetched. A page of 100 images is ~48 MB on the wire before reduction, so this bounds runtime and memory."
  type        = number
  default     = 1000
  nullable    = false

  validation {
    condition     = var.max_images >= 1
    error_message = "max_images must be at least 1."
  }
}

# ----------------------------------------------------------------
# Compute Console credentials.
#
# Separate from the CSPM credentials used by the alert-summary module: this is a
# different host with a different auth endpoint. CSWP_URL must include any path
# segment the tenant requires (e.g. https://<region>.cloud.twistlock.com/<id>) -
# stripping it authenticates "successfully" against the wrong scope and returns
# an empty token.
# ----------------------------------------------------------------

variable "console_url" {
  description = "(Optional) Compute Console URL, including any path segment (CSWP_URL). Required when enabled is true."
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

variable "skip_cert_check" {
  description = "(Optional) Skip TLS verification against the Compute Console. Only for self-hosted consoles with a private CA - never against a SaaS console."
  type        = bool
  default     = false
  nullable    = false
}
