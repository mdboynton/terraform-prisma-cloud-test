# ============================================================
# Import blocks — adopt pre-existing tenant artifacts into state.
#
# WHY THIS FILE EXISTS
#
# There is no remote backend (no `backend` block anywhere in this repo), so
# Terraform state is local to whichever machine or CI runner ran the apply, and
# it is gone when that runner is torn down. Every RBAC run therefore starts with
# EMPTY state and believes nothing exists yet.
#
# Without these blocks a second apply tries to CREATE artifacts that are already
# in the tenant, and the API rejects the duplicate:
#
#     Error: object already exists
#
# An `import` block tells Terraform "this already exists, adopt it" instead of
# "create it". State is still thrown away after each run, but each run rebuilds
# the mapping from these blocks, so re-runs converge instead of colliding.
#
# THIS IS A STOPGAP, NOT THE FIX. It only covers artifacts whose IDs are written
# down here, so anything created by a previous run must be added by hand. The
# real fix is a remote backend (S3 + DynamoDB, or Terraform Cloud), which keeps
# state durably and locks it against concurrent applies. Until then, treat this
# file as the state.
#
# WHY THE IDS ARE SAFE TO COMMIT
# These are opaque object identifiers for RBAC scaffolding, the same class of
# value already present in .drift/tenant-snapshot.json. No credentials. Note
# that service account SECRET KEYS are a different matter entirely — they live
# in Terraform state in plaintext, which is the main reason a state file must
# never be committed to this repository.
#
# ============================================================
# REGENERATING THIS FILE FOR ANOTHER TENANT
#
# The IDs below are specific to one tenant; they return HTTP 400 anywhere else.
# The previous version of this file targeted seven production VA teams and was
# deleted in the repo cleanup (commit f093247) — those IDs no longer resolve.
#
# To rebuild for the tenant you are pointed at:
#
#   TOKEN=$(printf '{"username":"%s","password":"%s"}' "$ACCESS_KEY" "$SECRET_KEY" \
#     | curl -s -X POST "https://$CSPM_URL/login" \
#         -H 'Content-Type: application/json' --data @- | jq -r '.token')
#
#   curl -s -H "x-redlock-auth: $TOKEN" "https://$CSPM_URL/user/role"     | jq -r '.[]|"\(.id)  \(.name)"'
#   curl -s -H "x-redlock-auth: $TOKEN" "https://$CSPM_URL/cloud/group"   | jq -r '.[]|"\(.id)  \(.name)"'
#   curl -s -H "x-redlock-auth: $TOKEN" "https://$CSPM_URL/v1/resource_list" | jq -r '.[]|"\(.id)  \(.name)"'
#   curl -s -H "x-redlock-auth: $TOKEN" "https://$CSPM_URL/entitlement/api/v1/collection" | jq -r '.value[]|"\(.id)  \(.name)"'
#   curl -s -H "x-redlock-auth: $TOKEN" "https://$CSPM_URL/v2/alert/rule" | jq -r '.[]|"\(.policyScanConfigId)  \(.name)"'
#
# Then match each id to its resource address. The `to` address must be exact —
# a typo does not error, it just leaves the artifact unimported and Terraform
# tries to create a duplicate. Note the differing shapes:
#
#   account_group / resource_list  are for_each'd, so they need a map key that
#                                  matches the NAME in config/teams.yaml
#   user_role / collection / alert_rule  are singletons, no key
#
# Comment out any block whose artifact does not exist yet; Terraform will create
# it, and it can be imported on the next pass.
# ============================================================

# ------------------------------------------------------------
# tuan-test
#
# Verified present in this tenant (api2.prismacloud.io) at the time of writing:
# each id below was read back from the live API, not copied from a snapshot.
# ------------------------------------------------------------

# for_each key is the account group NAME from config/teams.yaml.
import {
  to = module.prisma_cloud_rbac["tuan-test"].prismacloud_account_group.team["tuan-test-account-group"]
  id = "6b596f59-d228-46f4-9145-5da1205765a8"
}

# for_each key is the resource list NAME from config/teams.yaml.
import {
  to = module.prisma_cloud_rbac["tuan-test"].prismacloud_resource_list.team["tuan-test-resource-list"]
  id = "ac8945a1-6183-4336-8f1a-2a50eaf6ed8e"
}

# Singleton — one role per team, no for_each key.
import {
  to = module.prisma_cloud_rbac["tuan-test"].prismacloud_user_role.team
  id = "31997ee5-0167-4b8b-ae65-cd98aba51dc6"
}

# The dashboard-filter Collection the module creates ("<team>-assets").
# NOT the "<name> - Access Group (RBAC)" collection that Prisma Cloud
# auto-spawns alongside a Resource List — that one is not Terraform-managed.
import {
  to = module.prisma_cloud_rbac["tuan-test"].prismacloud_collection.team_dashboard_filter
  id = "e9f368ed-9a1b-470a-93ab-9ba4a0421690"
}

# Alert rules are identified by policyScanConfigId, not by a field called "id".
import {
  to = module.prisma_cloud_rbac["tuan-test"].prismacloud_alert_rule.team
  id = "c573d456-df7d-4030-8ce5-7b67d12f4d1e"
}

# ------------------------------------------------------------
# NOT imported, deliberately:
#
#   prismacloudcompute_collection.team_workloads
#     Lives in the Compute console, a separate store with its own API. No
#     instance of it was found for this team.
#
#   prismacloud_user_profile.service_account
#     No service account exists for tuan-test (config sets none). Worth knowing
#     before adding one: the API returns its secret key exactly once, at
#     creation, so an imported service account has a NULL secret in state and
#     the credential cannot be recovered through Terraform.
#
#   time_offset.access_key_expiration
#     Not a tenant object — it only exists to compute an expiry timestamp, and
#     is meaningless without the service account above.
# ------------------------------------------------------------
