terraform {
  # for_each in import blocks requires >= 1.7
  # Pinned to the installed version to prevent accidental upgrades.
  required_version = "~> 1.13"

  required_providers {
    prismacloud = {
      source  = "PaloAltoNetworks/prismacloud"
      version = "1.7.1"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
  }
}
