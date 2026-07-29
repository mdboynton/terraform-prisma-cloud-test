# ----------------------------------------------------------------
# tenant-access outputs. Empty/null when the module is disabled.
# ----------------------------------------------------------------

output "trusted_login_ip_ids" {
  description = "Map of trusted login IP entry name => Prisma Cloud trusted login IP ID."
  value       = { for name, r in prismacloud_trusted_login_ip.this : name => r.trusted_login_ip_id }
}

output "trusted_alert_ip_uuids" {
  description = "Map of trusted alert IP group name => Prisma Cloud UUID."
  value       = { for name, r in prismacloud_trusted_alert_ip.this : name => r.uuid }
}

output "trusted_alert_ip_cidr_counts" {
  description = "Map of trusted alert IP group name => number of CIDRs in the group (as reported by the tenant)."
  value       = { for name, r in prismacloud_trusted_alert_ip.this : name => r.cidr_count }
}

output "login_ip_enforcement_enabled" {
  description = "Whether tenant-wide login IP enforcement is being managed and to what value. Null when the enforcement toggle is not managed by this module."
  value       = local.manage_login_ip_status ? prismacloud_trusted_login_ip_status.this[0].enabled : null
}
