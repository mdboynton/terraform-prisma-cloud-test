# team registry (config/teams.yaml)
locals {
  teams = try(
    { for k, v in yamldecode(file("${path.module}/config/teams.yaml")) : k => v },
    {}
  )
}

# compute runtime policy associations (config/compute-runtime-policies.yaml).
# Optional: absent file / empty config => no compute-runtime-policies changes.
locals {
  compute_runtime_policies = try(
    yamldecode(file("${path.module}/config/compute-runtime-policies.yaml")),
    {}
  )
  compute_container_associations = try(local.compute_runtime_policies.container, [])
  compute_host_associations      = try(local.compute_runtime_policies.host, [])
}

# singleton app team permission group features
locals {
  permission_group_features = {
    actionPlanNotificationTemplates     = { read = false, update = false, create = false, delete = false }
    actionPlanOverview                  = { read = false, update = false, create = false, delete = false }
    actionPlanRemediation               = { read = false, update = false, create = false, delete = false }
    actionPlanStatusAndAssignment       = { read = false, update = false, create = false, delete = false }
    alarmCentre                         = { read = false, update = false, create = false, delete = false }
    alarmCentreSettings                 = { read = false, update = false, create = false, delete = false }
    alertsAlertRules                    = { read = false, update = false, create = false, delete = false }
    alertsNotificationTemplates         = { read = true, update = true, create = true, delete = true }
    alertsOverview                      = { read = true, update = false, create = false, delete = false }
    alertsRemediation                   = { read = false, update = false, create = false, delete = false }
    alertsReport                        = { read = true, update = true, create = true, delete = true }
    alertsSavedFilters                  = { read = false, update = false, create = false, delete = false }
    alertsSnoozeDismiss                 = { read = false, update = false, create = false, delete = false }
    application                         = { read = true, update = false, create = false, delete = false }
    assetInventoryFilters               = { read = false, update = false, create = false, delete = false }
    assetInventoryOverview              = { read = true, update = false, create = false, delete = false }
    codeSecurityDashboard               = { read = false, update = false, create = false, delete = false }
    codeSecurityDevPipelinesCodeReviews = { read = false, update = false, create = false, delete = false }
    codeSecurityDevPipelinesProjects    = { read = false, update = false, create = false, delete = false }
    codeSecurityProjects                = { read = false, update = false, create = false, delete = false }
    codeSecuritySupplyChain             = { read = false, update = false, create = false, delete = false }
    complianceFilters                   = { read = false, update = false, create = false, delete = false }
    complianceOverview                  = { read = true, update = false, create = false, delete = false }
    complianceReports                   = { read = true, update = false, create = false, delete = false }
    complianceStandards                 = { read = true, update = false, create = false, delete = false }
    computeAccessUI                     = { read = true, update = false, create = false, delete = false }
    computeAuth                         = { read = true, update = false, create = false, delete = false }
    computeCollections                  = { read = false, update = false, create = false, delete = false }
    computeDownloads                    = { read = true, update = false, create = false, delete = false }
    computeManageAlerts                 = { read = false, update = false, create = false, delete = false }
    computeManageCreds                  = { read = false, update = false, create = false, delete = false }
    computeManageDefenders              = { read = true, update = true, create = false, delete = false }
    computeMonitorAccessDocker          = { read = true, update = false, create = false, delete = false }
    computeMonitorAccessKubernetes      = { read = true, update = false, create = false, delete = false }
    computeMonitorCI                    = { read = true, update = true, create = false, delete = false }
    computeMonitorCNNF                  = { read = false, update = false, create = false, delete = false }
    computeMonitorCloud                 = { read = false, update = false, create = false, delete = false }
    computeMonitorCodeRepos             = { read = true, update = true, create = false, delete = false }
    computeMonitorCompliance            = { read = true, update = false, create = false, delete = false }
    computeMonitorHosts                 = { read = true, update = true, create = false, delete = false }
    computeMonitorImages                = { read = true, update = true, create = false, delete = false }
    computeMonitorRuntimeContainers     = { read = true, update = false, create = false, delete = false }
    computeMonitorRuntimeHosts          = { read = true, update = false, create = false, delete = false }
    computeMonitorRuntimeIncidents      = { read = true, update = false, create = false, delete = false }
    computeMonitorRuntimeServerless     = { read = true, update = false, create = false, delete = false }
    computeMonitorServerless            = { read = true, update = true, create = false, delete = false }
    computeMonitorVuln                  = { read = true, update = true, create = false, delete = false }
    computeMonitorWAAS                  = { read = true, update = false, create = false, delete = false }
    computePolicyAccessDocker           = { read = true, update = false, create = false, delete = false }
    computePolicyAccessKubernetes       = { read = true, update = false, create = false, delete = false }
    computePolicyAccessSecrets          = { read = true, update = false, create = false, delete = false }
    computePolicyCNNF                   = { read = true, update = false, create = false, delete = false }
    computePolicyCloud                  = { read = false, update = false, create = false, delete = false }
    computePolicyCodeRepos              = { read = true, update = false, create = false, delete = false }
    computePolicyComplianceCustomRules  = { read = true, update = false, create = false, delete = false }
    computePolicyContainers             = { read = true, update = false, create = false, delete = false }
    computePolicyCustomRules            = { read = true, update = false, create = false, delete = false }
    computePolicyHosts                  = { read = true, update = false, create = false, delete = false }
    computePolicyRuntimeContainer       = { read = true, update = false, create = false, delete = false }
    computePolicyRuntimeHosts           = { read = true, update = false, create = false, delete = false }
    computePolicyRuntimeServerless      = { read = true, update = false, create = false, delete = false }
    computePolicyServerless             = { read = true, update = false, create = false, delete = false }
    computePolicyWAAS                   = { read = true, update = false, create = false, delete = false }
    computePrivilegedOperations         = { read = false, update = false, create = false, delete = false }
    computeRadarsCloud                  = { read = false, update = false, create = false, delete = false }
    computeRadarsContainers             = { read = true, update = false, create = false, delete = false }
    computeRadarsHosts                  = { read = true, update = false, create = false, delete = false }
    computeRadarsServerless             = { read = true, update = false, create = false, delete = false }
    computeSandbox                      = { read = true, update = false, create = false, delete = false }
    computeSystemLogs                   = { read = false, update = false, create = false, delete = false }
    computeSystemOperations             = { read = true, update = false, create = false, delete = false }
    computeUIEventSubscriber            = { read = true, update = false, create = false, delete = false }
    dashboardSecOps                     = { read = false, update = false, create = false, delete = false }
    dataSecurityPostureManagement       = { read = false, update = false, create = false, delete = false }
    dlpDataDashboard                    = { read = false, update = false, create = false, delete = false }
    dlpDataInventory                    = { read = false, update = false, create = false, delete = false }
    dlpDataPattern                      = { read = false, update = false, create = false, delete = false }
    dlpDataProfile                      = { read = false, update = false, create = false, delete = false }
    dlpResource                         = { read = false, update = false, create = false, delete = false }
    dlpSnippet                          = { read = false, update = false, create = false, delete = false }
    investigateApplicationRql           = { read = false, update = false, create = false, delete = false }
    investigateAssetRql                 = { read = true, update = false, create = false, delete = false }
    investigateConfigRql                = { read = false, update = false, create = false, delete = false }
    investigateEventRql                 = { read = false, update = false, create = false, delete = false }
    investigateNetworkRql               = { read = false, update = false, create = false, delete = false }
    investigateVulnerabilityRql         = { read = true, update = false, create = false, delete = false }
    policies                            = { read = false, update = false, create = false, delete = false }
    policyComplianceMapping             = { read = false, update = false, create = false, delete = false }
    savedSearches                       = { read = true, update = false, create = false, delete = false }
    settingsAccessKeys                  = { read = false, update = false, create = false, delete = false }
    settingsAccountGroup                = { read = false, update = false, create = false, delete = false }
    settingsAlertIpAddresses            = { read = false, update = false, create = false, delete = false }
    settingsAnomalyThreshold            = { read = false, update = false, create = false, delete = false }
    settingsAnomalyTrustedList          = { read = false, update = false, create = false, delete = false }
    settingsAuditLogs                   = { read = false, update = false, create = false, delete = false }
    settingsCloudAccounts               = { read = false, update = false, create = false, delete = false }
    settingsCodeSecurity                = { read = false, update = false, create = false, delete = false }
    settingsEnterprise                  = { read = false, update = false, create = false, delete = false }
    settingsIntegrations                = { read = false, update = false, create = false, delete = false }
    settingsLicensing                   = { read = false, update = false, create = false, delete = false }
    settingsLoginIpAddresses            = { read = false, update = false, create = false, delete = false }
    settingsPermissionGroup             = { read = false, update = false, create = false, delete = false }
    settingsRepositories                = { read = false, update = false, create = false, delete = false }
    settingsResourceList                = { read = false, update = false, create = false, delete = false }
    settingsSSO                         = { read = false, update = false, create = false, delete = false }
    settingsUserRole                    = { read = false, update = false, create = false, delete = false }
    settingsUsers                       = { read = false, update = false, create = false, delete = false }
    vulnerabilityDashboard              = { read = true, update = false, create = false, delete = false }
    vulnerabilityRemediation            = { read = false, update = false, create = false, delete = false }
    #actionPlanNotificationTemplates = { read = false, update = false, create = false, delete = false }
    #alertsAlertRules                    = { read = true, update = true, create = true, delete = false }
    #alertsRemediation                   = { read = false, update = true, create = false, delete = false }
    #alertsReport                        = { read = true, update = true, create = true, delete = false }
    #alertsSnoozeDismiss                 = { read = false, update = true, create = false, delete = false }
    #codeSecurityDashboard               = { read = true, update = false, create = false, delete = false }
    #complianceReports                   = { read = true, update = true, create = true, delete = false }
    #complianceStandards = { read = true, update = true, create = true, delete = false }
    #computeAuth         = { read = false, update = false, create = false, delete = false }
    #computeCollections  = { read = true, update = true, create = true, delete = false }
    #computeDownloads    = { read = false, update = false, create = false, delete = false }
    #computeMonitorCI                   = { read = true, update = false, create = false, delete = false }
    #computeMonitorCNNF                 = { read = true, update = false, create = false, delete = false }
    #computeMonitorCodeRepos            = { read = true, update = false, create = false, delete = false }
    #computeMonitorHosts                = { read = true, update = false, create = false, delete = false }
    #computeMonitorImages               = { read = true, update = false, create = false, delete = false }
    #computeMonitorServerless           = { read = true, update = false, create = false, delete = false }
    #computePolicyAccessDocker          = { read = false, update = false, create = false, delete = false }
    #computePolicyAccessKubernetes      = { read = false, update = false, create = false, delete = false }
    #computePolicyAccessSecrets    = { read = false, update = false, create = false, delete = false }
    #computePolicyCNNF                  = { read = false, update = false, create = false, delete = false }
    #computePolicyCodeRepos             = { read = false, update = false, create = false, delete = false }
    #computePolicyComplianceCustomRules = { read = false, update = false, create = false, delete = false }
    #computePolicyContainers            = { read = false, update = false, create = false, delete = false }
    #computePolicyCustomRules           = { read = false, update = false, create = false, delete = false }
    #computePolicyHosts             = { read = false, update = false, create = false, delete = false }
    #computePolicyRuntimeContainer  = { read = false, update = false, create = false, delete = false }
    #computePolicyRuntimeHosts      = { read = false, update = false, create = false, delete = false }
    #computePolicyRuntimeServerless = { read = false, update = false, create = false, delete = false }
    #computePolicyServerless        = { read = false, update = false, create = false, delete = false }
    #computePolicyWAAS             = { read = false, update = false, create = false, delete = false }
    #computeRadarsContainers       = { read = false, update = false, create = false, delete = false }
    #computeRadarsHosts            = { read = false, update = false, create = false, delete = false }
    #computeRadarsServerless       = { read = false, update = false, create = false, delete = false }
    #computeSystemOperations       = { read = false, update = false, create = false, delete = false }
    #investigateApplicationRql     = { read = true, update = false, create = false, delete = false }
    #investigateConfigRql        = { read = true, update = false, create = false, delete = false }
    #investigateEventRql         = { read = true, update = false, create = false, delete = false }
    #investigateNetworkRql       = { read = true, update = false, create = false, delete = false }
    #policies                    = { read = true, update = true, create = true, delete = false }
    #policyComplianceMapping    = { read = false, update = true, create = false, delete = false }
    #savedSearches              = { read = true, update = false, create = true, delete = false }
    #vulnerabilityRemediation   = { read = false, update = false, create = true, delete = false }
  }
}
