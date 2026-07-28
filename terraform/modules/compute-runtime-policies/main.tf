# ============================================================
# compute-runtime-policies — attach an RBAC collection to EXISTING Compute
# runtime policy rules (container + host) without creating/redefining policies.
#
# Mechanism (B): API read-merge-write.
#   - data.external.*_preview : DRY RUN each plan (auth -> GET -> per-association
#     status), so admins see the effect before the gated apply.
#   - null_resource.*_apply   : on apply, GET -> distinct-append collection to the
#     matched rule's collections -> PUT the exact object back (verbatim fidelity).
# ============================================================

locals {
  skip_cert = var.skip_cert_verification ? "true" : "false"

  container_assoc_b64 = base64encode(jsonencode(var.container_associations))
  host_assoc_b64      = base64encode(jsonencode(var.host_associations))

  manage_container = length(var.container_associations) > 0
  manage_host      = length(var.host_associations) > 0

  scripts_dir = "${path.module}/scripts"
}

# ------------------------------------------------------------
# DRY-RUN preview (read-only). Runs on every plan/refresh.
# ------------------------------------------------------------
data "external" "container_preview" {
  count   = local.manage_container ? 1 : 0
  program = ["bash", "${local.scripts_dir}/preview.sh"]

  query = {
    console_url            = var.console_url
    access_key             = var.access_key
    secret_key             = var.secret_key
    policy_kind            = "container"
    skip_cert_verification = local.skip_cert
    associations_json      = local.container_assoc_b64
  }
}

data "external" "host_preview" {
  count   = local.manage_host ? 1 : 0
  program = ["bash", "${local.scripts_dir}/preview.sh"]

  query = {
    console_url            = var.console_url
    access_key             = var.access_key
    secret_key             = var.secret_key
    policy_kind            = "host"
    skip_cert_verification = local.skip_cert
    associations_json      = local.host_assoc_b64
  }
}

# ------------------------------------------------------------
# READ-ONLY listing (enable_list). Both directions:
#   full_dump           = every rule + its collections (Direction 1)
#   rules_by_collection = collection name -> rules referencing it (Direction 2)
# ------------------------------------------------------------
data "external" "container_list" {
  count   = var.enable_list ? 1 : 0
  program = ["bash", "${local.scripts_dir}/list.sh"]

  query = {
    console_url            = var.console_url
    access_key             = var.access_key
    secret_key             = var.secret_key
    policy_kind            = "container"
    skip_cert_verification = local.skip_cert
    collection_filter      = var.list_collection_filter
  }
}

data "external" "host_list" {
  count   = var.enable_list ? 1 : 0
  program = ["bash", "${local.scripts_dir}/list.sh"]

  query = {
    console_url            = var.console_url
    access_key             = var.access_key
    secret_key             = var.secret_key
    policy_kind            = "host"
    skip_cert_verification = local.skip_cert
    collection_filter      = var.list_collection_filter
  }
}

# ------------------------------------------------------------
# APPLY (non-destructive write). Re-runs when the associations change.
# ------------------------------------------------------------
resource "null_resource" "container_apply" {
  count = local.manage_container ? 1 : 0

  triggers = {
    associations = local.container_assoc_b64
    console_url  = var.console_url
    script       = filesha256("${local.scripts_dir}/merge_apply.sh")
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = "${local.scripts_dir}/merge_apply.sh"

    environment = {
      PCC_CONSOLE_URL      = var.console_url
      PCC_ACCESS_KEY       = var.access_key
      PCC_SECRET_KEY       = var.secret_key
      PCC_POLICY_KIND      = "container"
      PCC_SKIP_CERT        = local.skip_cert
      PCC_ASSOCIATIONS_B64 = local.container_assoc_b64
      PCC_DRY_RUN          = "false"
    }
  }
}

resource "null_resource" "host_apply" {
  count = local.manage_host ? 1 : 0

  triggers = {
    associations = local.host_assoc_b64
    console_url  = var.console_url
    script       = filesha256("${local.scripts_dir}/merge_apply.sh")
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = "${local.scripts_dir}/merge_apply.sh"

    environment = {
      PCC_CONSOLE_URL      = var.console_url
      PCC_ACCESS_KEY       = var.access_key
      PCC_SECRET_KEY       = var.secret_key
      PCC_POLICY_KIND      = "host"
      PCC_SKIP_CERT        = local.skip_cert
      PCC_ASSOCIATIONS_B64 = local.host_assoc_b64
      PCC_DRY_RUN          = "false"
    }
  }
}
