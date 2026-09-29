metadata description = 'Copilot Blueprint Explorer: every Azure resource in one click. Run this first, then the single Cloud Shell block in README.md Stage 1.2, which creates the Entra objects and writes the settings that depend on them.'

targetScope = 'resourceGroup'

// ---------------------------------------------------------------------------
// Set by the Stage 1.2 block after this deployment, not here.
//
// These four identify Entra objects that do not exist yet when the button runs. Leaving them empty
// is the normal path: the block creates the objects against the real web app and identity, then
// writes these same settings. Supply them only when the Entra objects already exist.
// ---------------------------------------------------------------------------

@description('Leave empty. Application (client) ID of the "Copilot Blueprint Explorer" app registration, which the Stage 1.2 block creates and fills in.')
param apiClientId string = ''

@description('Leave empty. Object ID of the Entra security group whose members may use the console. The Stage 1.2 block creates the group and fills this in.')
param securityGroupObjectId string = ''

@description('Leave empty. Application (client) ID of the "CBX Purview Collector" app registration, which the Stage 1.2 block creates and fills in.')
param purviewCollectorAppId string = ''

@description('Leave empty. Your tenant\'s primary onmicrosoft.com domain. The Stage 1.2 block reads it from the tenant and fills it in.')
param purviewOrganization string = ''

// ---------------------------------------------------------------------------
// The deployer
// ---------------------------------------------------------------------------

@description('Object ID of the person who will run Stage 2. They get Contributor on this resource group only. Leave empty if the administrator runs Stage 2 too.')
param deployerObjectId string = ''

@description('Sign-in name (UPN) of the deployer, for example alex@contoso.com. Recorded once as the first named person so they can sign in before an access group exists. Remove or re-role them later under Settings, Users. Leave empty to skip.')
param deployerUpn string = ''

// ---------------------------------------------------------------------------
// Hosting
// ---------------------------------------------------------------------------

@description('Short prefix for resource names. Lowercase letters and digits only.')
@minLength(2)
@maxLength(6)
param namePrefix string = 'cbx'

@description('Location for every resource.')
param location string = resourceGroup().location

@description('Web app name, which becomes https://<name>.azurewebsites.net and must be globally unique. Leave empty to generate one.')
param webAppName string = ''

@description('App Service plan size. B1 is enough for one customer.')
@allowed(['B1', 'B2', 'P0v3', 'P1v3'])
param webAppSku string = 'B1'

// ---------------------------------------------------------------------------
// Collection from Purview and Power Platform. The Automation account is always created: without it
// the Purview, Exchange, Teams, SharePoint and Power Platform readings have nowhere to run and the
// controls behind them stay manual, which is most of what makes this assessment worth running.
// ---------------------------------------------------------------------------

@description('Leave empty. The Deploy to Azure button then imports the runbooks from the runbooks folder next to this template. Only set it to use another copy: a public base URL ending in a slash. Loaded from a file, the template imports nothing and the Stage 1.2 block imports them instead.')
param runbookBaseUrl string = ''

param tags object = {
  workload: 'copilot-blueprint-explorer'
}

// ---------------------------------------------------------------------------

var suffix = toLower(uniqueString(resourceGroup().id))
var siteName = empty(webAppName) ? '${namePrefix}-app-${suffix}' : webAppName
var automationName = '${namePrefix}-aa-${suffix}'
// Set only when deployed from a URL (the button, --template-uri); a template loaded from a file has no link.
var templateUri = deployment().properties.?templateLink.?uri ?? ''
var runbookBase = !empty(runbookBaseUrl) ? runbookBaseUrl : (empty(templateUri) ? '' : uri(templateUri, 'runbooks/'))
var importRunbooks = !empty(runbookBase)

// Built-in role definition IDs.
var roles = {
  contributor: 'b24988ac-6180-42a0-ab88-20f7382dd24c'
  reader: 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
  automationJobOperator: '4fe576fe-1146-4730-92eb-48519fa6bf9f'
}

// Versions proven with the runbooks on Windows PowerShell 5.1. MicrosoftTeams 8.0.0 (22 MB) is imported in
// Stage 2 instead: ARM waits for every module import, and a slow or stuck one held the whole deployment.
var modules = [
  { name: 'ExchangeOnlineManagement', version: '3.5.1' }
  { name: 'Microsoft.Online.SharePoint.PowerShell', version: '16.0.27612.12000' }
]

var runbooks = ['Get-CbxDlpPolicies', 'Get-CbxPowerPlatform']

// Exists only as the federated credential that lets the API act for the signed-in person without a secret.
resource uami 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${namePrefix}-uami-${suffix}'
  location: location
  tags: tags
}

resource plan 'Microsoft.Web/serverfarms@2024-11-01' = {
  name: '${namePrefix}-plan-${suffix}'
  location: location
  tags: tags
  kind: 'linux'
  sku: {
    name: webAppSku
  }
  properties: {
    reserved: true
  }
}

resource site 'Microsoft.Web/sites@2024-11-01' = {
  name: siteName
  location: location
  tags: tags
  kind: 'app,linux'
  identity: {
    // System-assigned does every app-only read; the user-assigned one is only the sign-in credential.
    type: 'SystemAssigned, UserAssigned'
    userAssignedIdentities: {
      '${uami.id}': {}
    }
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: 'DOTNETCORE|8.0'
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
      http20Enabled: true
      alwaysOn: true
      healthCheckPath: '/api/health'
      appSettings: [
        { name: 'SCM_DO_BUILD_DURING_DEPLOYMENT', value: 'false' }
        { name: 'Cbx__TenantId', value: subscription().tenantId }
        { name: 'Cbx__ApiClientId', value: apiClientId }
        { name: 'Cbx__SpaClientId', value: apiClientId }
        { name: 'Cbx__UserAssignedClientId', value: uami.properties.clientId }
        { name: 'Cbx__SecurityGroupObjectId', value: securityGroupObjectId }
        // Seeds the first named person on first start, so the deployer can sign in before an access
        // group exists. An ordinary entry from then on: re-role or remove it under Settings, Users.
        { name: 'Cbx__DeployerUpn', value: deployerUpn }
        { name: 'Cbx__SubscriptionId', value: subscription().subscriptionId }
        // Every deployment carries the assistant; whether it is switched on, and which Foundry
        // project answers, is decided later in Settings. Asking at deploy time only produced
        // deployments that could never enable it without an app-setting change.
        { name: 'Cbx__DeploymentOption', value: 'AskCbx' }
        { name: 'Cbx__AutomationResourceGroup', value: resourceGroup().name }
        { name: 'Cbx__AutomationAccountName', value: automationName }
        { name: 'Cbx__PurviewCollectorAppId', value: purviewCollectorAppId }
        { name: 'Cbx__PurviewOrganization', value: purviewOrganization }
      ]
    }
  }
}

resource automation 'Microsoft.Automation/automationAccounts@2023-11-01' = {
  name: automationName
  location: location
  tags: tags
  identity: {
    // Runs the Power Platform runbook; the Purview one signs in with the collector's certificate instead.
    type: 'SystemAssigned'
  }
  properties: {
    sku: {
      name: 'Basic'
    }
  }
}

// One at a time: Automation imports that run in parallel are prone to stalling.
@batchSize(1)
resource automationModules 'Microsoft.Automation/automationAccounts/modules@2023-11-01' = [for m in modules: {
  parent: automation
  name: m.name
  properties: {
    contentLink: {
      uri: 'https://www.powershellgallery.com/api/v2/package/${m.name}/${m.version}'
    }
  }
}]

resource automationRunbooks 'Microsoft.Automation/automationAccounts/runbooks@2023-11-01' = [for r in runbooks: if (importRunbooks) {
  parent: automation
  name: r
  location: location
  tags: tags
  properties: {
    // PowerShell means Windows PowerShell 5.1, which the SharePoint module needs.
    runbookType: 'PowerShell'
    logProgress: false
    logVerbose: false
    publishContentLink: {
      uri: '${runbookBase}${r}.ps1'
    }
  }
}]

// The console starts the runbooks and reads their output with the web app's own identity; nothing wider.
resource jobOperator 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(automation.id, site.id, roles.automationJobOperator)
  scope: automation
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.automationJobOperator)
    principalId: site.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource jobReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(automation.id, site.id, roles.reader)
  scope: automation
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.reader)
    principalId: site.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource deployerContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(deployerObjectId)) {
  name: guid(resourceGroup().id, deployerObjectId, roles.contributor)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.contributor)
    principalId: deployerObjectId
    principalType: 'User'
  }
}

// ---------------------------------------------------------------------------
// Outputs: copy these into the handover sheet in README.md
// ---------------------------------------------------------------------------

output webAppName string = site.name
output webAppUrl string = 'https://${site.properties.defaultHostName}'
output managedIdentityName string = uami.name
output managedIdentityClientId string = uami.properties.clientId
output managedIdentityPrincipalId string = uami.properties.principalId
output webAppSystemIdentityPrincipalId string = site.identity.principalId
output automationAccountName string = automation.name
output automationAccountPrincipalId string = automation.identity.principalId
output resourceGroupName string = resourceGroup().name
output runbooksImportedFrom string = importRunbooks ? runbookBase : 'not imported: the Stage 1.2 block imports them'
output nextStep string = 'Run the single Cloud Shell block in README.md, Stage 1.2. It creates the Entra objects against this deployment and writes the settings they fill in.'
