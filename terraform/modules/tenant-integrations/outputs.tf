# ----------------------------------------------------------------
# tenant-integrations outputs. Empty maps when the module is disabled.
# ----------------------------------------------------------------

output "integration_ids" {
  description = "Map of integration name => Prisma Cloud integration ID."
  value       = { for name, r in prismacloud_integration.this : name => r.integration_id }
}

output "integration_status" {
  description = "Map of integration name => { status, valid }, as reported by the tenant. Useful for spotting integrations that were accepted but fail health checks."
  value = {
    for name, r in prismacloud_integration.this : name => {
      status = r.status
      valid  = r.valid
    }
  }
}

output "report_ids" {
  description = "Map of report name => Prisma Cloud report ID."
  value       = { for name, r in prismacloud_report.this : name => r.report_id }
}

output "report_status" {
  description = "Map of report name => { status, next_schedule }, as reported by the tenant."
  value = {
    for name, r in prismacloud_report.this : name => {
      status        = r.status
      next_schedule = r.next_schedule
    }
  }
}
