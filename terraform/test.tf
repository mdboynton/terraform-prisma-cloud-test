# AGENTS: ignore this

## Copy of readonly singleton with policy configuration permissions 
#resource "prismacloud_permission_group" "singleton_with_policy_permissions" {
#  name                  = "appowner-policy-self-manage-test"
#  description           = "Test PG for self-service policy management."
#  permission_group_type = "Custom"
#  custom                = true
#  accept_account_groups = true
#  accept_resource_lists = true
#
#  dynamic "features" {
#    for_each = local.permission_group_features
#    content {
#      feature_name = features.key
#      operations {
#        read   = features.value.read
#        update = features.value.update
#        create = features.value.create
#        delete = features.value.delete
#      }
#    }
#  }
#}
