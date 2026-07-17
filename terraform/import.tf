# Import blocks adopting pre-existing live tenant artifacts into Terraform state
# for the teams declared in config/teams.yaml. IDs come from the live
# tenant snapshot in tmp/*.json. dtc and mhv are already present in state and are
# therefore NOT re-imported here.
#
# Only artifacts that actually EXIST in the live tenant are imported. The module
# also declares a per-team alert rule (<team>-alert-rule) and dashboard
# collection (<team>-assets); those do not exist for these teams and will show
# as planned creations (accepted).

# ---------------------------------------------------------------
# ccra  (role: ccra-readonly-role; resource list: ccra-app-rl)
# ---------------------------------------------------------------
import {
  to = module.prisma_cloud_rbac["ccra"].prismacloud_resource_list.team["ccra-app-rl"]
  id = "e41cae55-9ee8-4632-8766-35e3a425fb30"
}

import {
  to = module.prisma_cloud_rbac["ccra"].prismacloud_user_role.team
  id = "e73bb382-3b28-46a0-9c8f-206500c8a5e2"
}

# ---------------------------------------------------------------
# cpe  (role: cp&e-readonly-role; resource list: cp&e-app-rl)
# ---------------------------------------------------------------
import {
  to = module.prisma_cloud_rbac["cpe"].prismacloud_resource_list.team["cp&e-app-rl"]
  id = "28bf4927-dcbd-43b5-a828-132fff22e3e7"
}



import {
  to = module.prisma_cloud_rbac["cpe"].prismacloud_user_role.team
  id = "cd536d30-2a5d-4936-a67f-b70679e17ed5"
}

# ---------------------------------------------------------------
# de  (role: de-readonly-role; AGs: de-prod-ag/de-dev-ag/de-preprod-ag;
#      resource list: de-app-rl)
# ---------------------------------------------------------------
import {
  to = module.prisma_cloud_rbac["de"].prismacloud_account_group.team["de-prod-ag"]
  id = "4e14ecf8-b825-4713-a1a3-024c65a495d1"
}

import {
  to = module.prisma_cloud_rbac["de"].prismacloud_account_group.team["de-dev-ag"]
  id = "a6010b50-f764-4874-b8a8-5afdc56dcb27"
}

import {
  to = module.prisma_cloud_rbac["de"].prismacloud_account_group.team["de-preprod-ag"]
  id = "b1e4ee12-a1b1-437d-92d1-1a13850f6b2e"
}

import {
  to = module.prisma_cloud_rbac["de"].prismacloud_resource_list.team["de-app-rl"]
  id = "cf0ffc0c-49db-4813-ab5a-bdc7d7f9ab07"
}

import {
  to = module.prisma_cloud_rbac["de"].prismacloud_user_role.team
  id = "73df85bd-c44a-476f-938e-d7563fae4e35"
}

# ---------------------------------------------------------------
# fmbt  (role: fmbt-readonly-role; resource list: fmbt-app-rl)
# ---------------------------------------------------------------
#import {
#  to = module.prisma_cloud_rbac["fmbt"].prismacloud_resource_list.team["fmbt-app-rl"]
#  id = "7f673479-4598-4ddd-85ca-4deb5541988a"
#}
#
#import {
#  to = module.prisma_cloud_rbac["fmbt"].prismacloud_user_role.team
#  id = "dfc01c5d-4cfa-4f11-a0c8-1777b983f62b"
#}

# ---------------------------------------------------------------
# fsc-filnet  (role: fsc-filnet-readonly-role; AG: om-fsc-dev-ag;
#              resource list: fsc-filenet-rl)
# ---------------------------------------------------------------
import {
  to = module.prisma_cloud_rbac["fsc-filnet"].prismacloud_account_group.team["om-fsc-dev-ag"]
  id = "59852669-e40a-454a-b726-3bafdf3965e2"
}

import {
  to = module.prisma_cloud_rbac["fsc-filnet"].prismacloud_resource_list.team["fsc-filenet-rl"]
  id = "845defb2-f522-453e-9c76-e651bb42a954"
}

import {
  to = module.prisma_cloud_rbac["fsc-filnet"].prismacloud_user_role.team
  id = "e4cd4bae-f197-4be5-ac6b-ac74028c7350"
}

# ---------------------------------------------------------------
# hdr  (role: hdr-readonly-role; AG: hdr-dev-ag; resource list: hdr-app-rl)
# ---------------------------------------------------------------
import {
  to = module.prisma_cloud_rbac["hdr"].prismacloud_account_group.team["hdr-dev-ag"]
  id = "cd24a6d8-bce2-4ff7-92c4-bad3af785cb3"
}

import {
  to = module.prisma_cloud_rbac["hdr"].prismacloud_resource_list.team["hdr-app-rl"]
  id = "a23f63bf-e5b3-431e-b363-240107de4fa8"
}

import {
  to = module.prisma_cloud_rbac["hdr"].prismacloud_user_role.team
  id = "0e67597d-4178-4b14-b5fb-84face3e46c3"
}

# ---------------------------------------------------------------
# lhdi  (role: lhdi-readonly-role; AGs: lhdi-aws-dev-ag/lhdi-aws-nonprod-ag;
#        resource lists: lhdi-aws-dev-rl/lhdi-aws-nonprod-rl)
# ---------------------------------------------------------------
#import {
#  to = module.prisma_cloud_rbac["lhdi"].prismacloud_account_group.team["lhdi-aws-dev-ag"]
#  id = "5d8e02d5-3407-48bb-89f5-acce3d17086b"
#}
#
#import {
#  to = module.prisma_cloud_rbac["lhdi"].prismacloud_account_group.team["lhdi-aws-nonprod-ag"]
#  id = "918440fb-8fa9-4e4c-b935-39ab60681dd4"
#}
#
#import {
#  to = module.prisma_cloud_rbac["lhdi"].prismacloud_resource_list.team["lhdi-aws-dev-rl"]
#  id = "71ab174a-44eb-4a5a-ad38-2d40cdfee947"
#}
#
#import {
#  to = module.prisma_cloud_rbac["lhdi"].prismacloud_resource_list.team["lhdi-aws-nonprod-rl"]
#  id = "a153fa37-da2b-4938-906d-be97a2d4b775"
#}
#
#import {
#  to = module.prisma_cloud_rbac["lhdi"].prismacloud_user_role.team
#  id = "27fd9115-4a24-4b65-9f20-b5a2ab9eaaf9"
#}
