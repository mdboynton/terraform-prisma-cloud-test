terraform {
  required_version = "~> 1.13"

  required_providers {
    prismacloud = {
      source  = "PaloAltoNetworks/prismacloud"
      version = "1.7.1"
    }

    # Used only by the opt-in per-alert detail fetch. `data "external"` is a
    # DATA source, so adding it does not introduce any resource - this module
    # still cannot change anything.
    external = {
      source  = "hashicorp/external"
      version = "~> 2.3"
    }
  }
}
