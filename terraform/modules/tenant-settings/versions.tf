terraform {
  required_version = "~> 1.13"

  required_providers {
    prismacloud = {
      source  = "PaloAltoNetworks/prismacloud"
      version = ">= 1.6"
    }
  }
}
