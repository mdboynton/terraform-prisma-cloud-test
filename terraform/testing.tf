# Plan-validation sentinel team. Toggle by uncommenting the block below.
# Apply, verify in UI, re-comment, apply to destroy.
# See module README §plan-validation-team for the full procedure.
#
# WARNINGS:
#   1. Do NOT rename the module label "ci_validation_team" — orphans state.
#   2. account_ids = ["999999999999"] is a sentinel; lab-verify the API accepts it.
#   3. Only `namespaces` is narrowed; other CAG fields default to ["*"] but are
#      inert because the bound Account Group contains a non-real account.
#   4. Attached to the SHARED PG — catalog/rename changes will recreate it.

# module "ci_validation_team" {
#   source = "./modules/rbac"
#
#   providers = {
#     prismacloud = prismacloud
#   }
#
#   team_name             = "ci-validation-team"
#   team_description      = "Sentinel team for plan-validation only. Not a real onboarded team."
#   permission_group_id   = prismacloud_permission_group.app_owner_readonly_singleton.id
#   permission_group_name = prismacloud_permission_group.app_owner_readonly_singleton.name
#
#   account_groups = [
#     {
#       name        = "ci-validation-team-account-group"
#       account_ids = ["999999999999"]
#     },
#   ]
#
#   resource_lists = [
#     {
#       name = "ci-validation-team-resource-list"
#       compute_access_group = {
#         namespaces = ["ci-validation-only-*"]
#       }
#     },
#   ]
# }

# ----------------------------------------------------------------
# Extended sentinel exercising the multi-AG/RL + service account paths.
# Use INSTEAD of the block above (not in addition) when smoke-testing the
# enhanced module. Re-comment + apply to destroy when done.
#
# WARNINGS (in addition to those above):
#   5. Two AGs / two RLs each require a unique name (default name collides).
#   6. The service account mints a real access key; retrieve + revoke it as
#      part of the smoke test:
#        terraform output -json team_service_account_secret_keys
#   7. service_account.role_id below references the sentinel team's own role,
#      which only exists AFTER first apply — for a clean first apply, either
#      omit the service_account block or supply a known existing role ID.
# ----------------------------------------------------------------
# module "ci_validation_team" {
#   source = "./modules/rbac"
#
#   providers = {
#     prismacloud = prismacloud
#   }
#
#   team_name             = "ci-validation-team"
#   team_description      = "Sentinel team for plan-validation only. Not a real onboarded team."
#   permission_group_id   = prismacloud_permission_group.app_owner_readonly_singleton.id
#   permission_group_name = prismacloud_permission_group.app_owner_readonly_singleton.name
#
#   account_groups = [
#     {
#       name                      = "ci-validation-team-ag-1"
#       account_ids               = ["999999999999"]
#       non_onboarded_account_ids = ["888888888888"]
#     },
#     {
#       name        = "ci-validation-team-ag-2"
#       account_ids = ["777777777777"]
#     },
#   ]
#
#   resource_lists = [
#     {
#       name = "ci-validation-team-rl-1"
#       compute_access_group = {
#         namespaces = ["ci-validation-only-1-*"]
#       }
#     },
#     {
#       name = "ci-validation-team-rl-2"
#       compute_access_group = {
#         namespaces = ["ci-validation-only-2-*"]
#       }
#     },
#   ]
#
#   # Omit on first apply (role doesn't exist yet) or use a known role ID.
#   # service_account = {
#   #   name    = "ci-validation-team-service-account"
#   #   role_id = "<existing-role-id>"
#   # }
# }
