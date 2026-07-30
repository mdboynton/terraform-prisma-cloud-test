terraform {
  required_providers {
    prismacloud = {
      source  = "PaloAltoNetworks/prismacloud"
      version = "1.7.1"
    }
    # CSPM and Compute maintain SEPARATE collection stores. A prismacloud_collection
    # is not visible to the Compute console, so a Compute-native collection is
    # required for anything that scopes runtime policies. See the
    # prismacloudcompute_collection resource in main.tf.
    prismacloudcompute = {
      source  = "PaloAltoNetworks/prismacloudcompute"
      version = "~> 0.8"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.9"
    }
  }
}
