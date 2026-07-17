terraform {
  required_providers {
    prismacloud = {
      source  = "PaloAltoNetworks/prismacloud"
      version = "1.7.1"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.9"
    }
  }
}
