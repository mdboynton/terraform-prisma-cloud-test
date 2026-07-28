terraform {
  # for_each in import blocks requires >= 1.7
  # Pinned to the installed version to prevent accidental upgrades.
  required_version = "~> 1.13"

  required_providers {
    prismacloud = {
      source  = "PaloAltoNetworks/prismacloud"
      version = "1.7.1"
    }
    # Compute Console provider (Twistlock). Separate from the CSPM `prismacloud`
    # provider above: it authenticates against the Compute Console, not the CSPM
    # API, and owns the Host/Container policy resources (see modules/compute-policies).
    prismacloudcompute = {
      source  = "PaloAltoNetworks/prismacloudcompute"
      version = "~> 0.8"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
  }
}
