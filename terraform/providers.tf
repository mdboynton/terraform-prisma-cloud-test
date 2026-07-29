provider "prismacloud" {
  url                        = var.prisma_cloud_api_url
  username                   = var.prisma_cloud_access_key
  password                   = var.prisma_cloud_secret_key
  customer_name              = var.prisma_cloud_customer_name
  protocol                   = var.prisma_cloud_protocol
  port                       = var.prisma_cloud_port
  timeout                    = var.prisma_cloud_timeout
  skip_ssl_cert_verification = var.prisma_cloud_skip_ssl_cert_verification
  json_config_file           = var.prisma_cloud_json_config_file
  json_web_token             = var.prisma_cloud_json_web_token
  logging                    = var.prisma_cloud_logging
  max_retries                = var.prisma_cloud_max_retries
  retry_max_delay            = var.prisma_cloud_retry_max_delay
  retry_type                 = var.prisma_cloud_retry_type
  disable_reconnect          = var.prisma_cloud_disable_reconnect
}

# Compute Console (Twistlock) provider. Authenticates against the Compute Console
# rather than the CSPM API. Reuses the same access key / secret key as the CSPM
# provider (per D3). Used by modules/compute-runtime-policies to attach RBAC
# collections to existing runtime policy rules.
provider "prismacloudcompute" {
  console_url            = var.prisma_compute_console_url
  username               = var.prisma_cloud_access_key
  password               = var.prisma_cloud_secret_key
  project                = var.prisma_compute_project
  skip_cert_verification = var.prisma_compute_skip_cert_verification
}
