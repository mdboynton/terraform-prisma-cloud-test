terraform {
  required_version = "~> 1.13"

  required_providers {
    # Read path (dry-run preview) — calls scripts/preview.sh.
    external = {
      source  = "hashicorp/external"
      version = "~> 2.3"
    }
    # Write path (non-destructive merge/apply) — calls scripts/merge_apply.sh.
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}
