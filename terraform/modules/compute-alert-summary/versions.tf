terraform {
  required_version = "~> 1.13"

  required_providers {
    # Read path only — calls scripts/summary.sh. `external` is a DATA source, so
    # this module contributes zero resources to a plan.
    external = {
      source  = "hashicorp/external"
      version = "~> 2.3"
    }
  }
}
