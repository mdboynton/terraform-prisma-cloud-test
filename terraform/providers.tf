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
