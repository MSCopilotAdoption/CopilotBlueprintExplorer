<#
.SYNOPSIS
    Collects Power Platform governance data that no REST API exposes to a web application, and writes
    it to the job output as JSON.

.DESCRIPTION
    The modern Power Platform API (api.powerplatform.com) serves environments, environment settings
    and application packages, and nothing else - apps, flows, AI Builder models and connector DLP
    policies all return 404 there. The data exists only behind the admin PowerShell modules and the
    legacy BAP endpoints, both of which expect an interactive or service-principal sign-in that a
    browser-hosted app cannot perform.

    So it runs here, the same way the Purview collector does: the Automation Account authenticates
    with its own managed identity, calls the admin endpoints directly, and writes the result to the
    job output. The app reads that output over ARM with its own managed identity, so this runbook
    needs no inbound credential and no network path back into the app.

    PREREQUISITES, two of them, both for the Automation Account's own managed identity:

    1. Registered as a Power Platform management application, or every admin endpoint returns 403.
       Microsoft treats a registered application like a Power Platform Administrator and offers no
       narrower registration; this runbook only ever issues GET requests. A Power Platform Administrator
       registers it once:

        Add-PowerAppsAccount
        New-PowerAppManagementApp -ApplicationId <automation-account-managed-identity-client-id>

    2. An application user in each Dataverse environment holding the "CBX agent inventory reader"
       role: organisation-wide Read on Agent (bot) and AI Model, plus the SharePoint document-integration
       privileges Dataverse forces onto every role. Without it the
       Copilot Studio and AI Builder reads return 403. A System Administrator of the environment runs
       scripts/Grant-CbxDataverseReader.ps1.

    The job output reports which of these worked, per environment, so the console can show whether
    they are in place without holding any Power Platform or Dataverse permission itself.

.NOTES
    Requires the Az.Accounts module in the Automation Account. No Power Platform module is used -
    the REST endpoints are called directly, because the modules expect an interactive sign-in.
#>

param(
    [string] $BapResource = 'https://api.bap.microsoft.com',
    [string] $PowerAppsResource = 'https://service.powerapps.com',
    [string] $FlowResource = 'https://service.flow.microsoft.com'
)

$ErrorActionPreference = 'Stop'

function Write-Result {
    param($Payload)
    # A single line so the caller can find it unambiguously among any host output.
    Write-Output ('CBX_PP_JSON:' + ($Payload | ConvertTo-Json -Depth 8 -Compress))
}

function Get-CbxToken {
    param([string] $Resource)
    $token = Get-AzAccessToken -ResourceUrl $Resource -ErrorAction Stop
    return $token.Token
}

<#
    Every block is independent and records its own failure. A tenant without AI Builder, or an
    account that cannot see DLP policies, must not cost us the blocks that did work.
#>
function Invoke-CbxBlock {
    param([string] $Name, [scriptblock] $Action)

    try {
        $value = & $Action
        return [pscustomobject]@{ Name = $Name; Ok = $true; Value = $value; Error = $null; Status = 200 }
    }
    catch {
        $status = $null
        if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
        # The status line alone says only "Forbidden"; the body names the missing privilege.
        $detail = $_.Exception.Message
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            $detail = $_.ErrorDetails.Message
            try { $parsed = $detail | ConvertFrom-Json; if ($parsed.error.message) { $detail = $parsed.error.message } } catch { }
        }
        if ($detail.Length -gt 300) { $detail = $detail.Substring(0, 300) }
        return [pscustomobject]@{
            Name   = $Name
            Ok     = $false
            Value  = $null
            Error  = if ($status) { "$status - $detail" } else { $detail }
            Status = $status
        }
    }
}

try {
    Connect-AzAccount -Identity -ErrorAction Stop | Out-Null

    $bapToken = Get-CbxToken -Resource $BapResource
    $bapHeaders = @{ Authorization = "Bearer $bapToken" }

    # Each workload is served by its own host and audience: environments and connector policies come
    # from BAP, apps and AI Builder from PowerApps, flows from Flow. A BAP token on the PowerApps
    # host returns 404, which reads like a wrong path rather than a wrong token.
    $appsHost = 'https://api.powerapps.com'
    $flowHost = 'https://api.flow.microsoft.com'
    $appsHeaders = @{ Authorization = 'Bearer ' + (Get-CbxToken -Resource $PowerAppsResource) }
    $flowHeaders = @{ Authorization = 'Bearer ' + (Get-CbxToken -Resource $FlowResource) }

    $blocks = @()

    $environments = @()
    $envBlock = Invoke-CbxBlock 'Environments' {
        $url = "$BapResource/providers/Microsoft.BusinessAppPlatform/scopes/admin/environments?api-version=2016-11-01"
        $response = Invoke-RestMethod -Uri $url -Headers $bapHeaders -Method Get
        @($response.value)
    }
    $blocks += $envBlock
    if ($envBlock.Ok) { $environments = @($envBlock.Value) }

    # Connector policies are the control that stops an agent joining business data to the internet.
    $dlpBlock = Invoke-CbxBlock 'DlpPolicies' {
        $url = "$BapResource/providers/PowerPlatform.Governance/v2/policies?api-version=2016-11-01"
        $response = Invoke-RestMethod -Uri $url -Headers $bapHeaders -Method Get
        @($response.value) | ForEach-Object {
            [pscustomobject]@{
                Name              = $_.displayName
                Id                = $_.name
                Type              = $_.environmentType
                CreatedBy         = $_.createdBy.displayName
                LastModified      = $_.lastModifiedTime
                BusinessGroup     = @($_.connectorGroups | Where-Object { $_.classification -eq 'Confidential' } | ForEach-Object { $_.connectors.Count }) -join ','
                NonBusinessGroup  = @($_.connectorGroups | Where-Object { $_.classification -eq 'General' } | ForEach-Object { $_.connectors.Count }) -join ','
                BlockedGroup      = @($_.connectorGroups | Where-Object { $_.classification -eq 'Blocked' } | ForEach-Object { $_.connectors.Count }) -join ','
                EnvironmentsScope = @($_.environments).Count
                # Which environments the policy lists; Type says whether that list is included or excepted.
                EnvironmentIds    = @($_.environments | ForEach-Object { $_.name })
            }
        }
    }
    $blocks += $dlpBlock
    $dlpPolicies = if ($dlpBlock.Ok) { @($dlpBlock.Value) } else { @() }

    $apps = New-Object System.Collections.ArrayList
    $flows = New-Object System.Collections.ArrayList
    $aiModels = New-Object System.Collections.ArrayList
    $agents = New-Object System.Collections.ArrayList
    $copilotSettings = New-Object System.Collections.ArrayList
    $dataverseAccess = New-Object System.Collections.ArrayList

    foreach ($environment in $environments) {
        $envName = $environment.name
        $display = $environment.properties.displayName
        $dataverseUrl = $environment.properties.linkedEnvironmentMetadata.instanceUrl

        $appBlock = Invoke-CbxBlock "Apps:$display" {
            $url = "$appsHost/providers/Microsoft.PowerApps/scopes/admin/environments/$envName/apps?api-version=2016-11-01"
            $response = Invoke-RestMethod -Uri $url -Headers $appsHeaders -Method Get
            @($response.value)
        }
        if ($appBlock.Ok) {
            foreach ($app in @($appBlock.Value)) {
                [void]$apps.Add([pscustomobject]@{
                    Environment = $display
                    Name        = $app.properties.displayName
                    Owner       = $app.properties.owner.displayName
                    Created     = $app.properties.createdTime
                    SharedUsers = $app.properties.sharedUsersCount
                })
            }
        }
        else { $blocks += $appBlock }

        $flowBlock = Invoke-CbxBlock "Flows:$display" {
            $url = "$flowHost/providers/Microsoft.ProcessSimple/scopes/admin/environments/$envName/v2/flows?api-version=2016-11-01"
            $response = Invoke-RestMethod -Uri $url -Headers $flowHeaders -Method Get
            @($response.value)
        }
        if ($flowBlock.Ok) {
            foreach ($flow in @($flowBlock.Value)) {
                [void]$flows.Add([pscustomobject]@{
                    Environment = $display
                    Name        = $flow.properties.displayName
                    State       = $flow.properties.state
                    Created     = $flow.properties.createdTime
                })
            }
        }
        else { $blocks += $flowBlock }

        # AI Builder models and Copilot Studio agents are Dataverse rows, not Power Platform API
        # resources - /aiModels on the admin API returns 404 however the token is scoped.
        if ($dataverseUrl) {
            $dvRoot = $dataverseUrl.TrimEnd('/')
            $dvHeaders = $null
            try {
                $dvHeaders = @{
                    Authorization      = 'Bearer ' + (Get-CbxToken -Resource $dvRoot)
                    Accept             = 'application/json'
                    'OData-MaxVersion' = '4.0'
                    'OData-Version'    = '4.0'
                }
            }
            catch {
                $blocks += [pscustomobject]@{
                    Name = "Dataverse:$display"; Ok = $false; Value = $null
                    Error = 'Could not get a Dataverse token: ' + $_.Exception.Message
                }
            }

            if ($dvHeaders) {
                $access = [pscustomobject]@{
                    Environment = $display; Url = $dvRoot; AppUser = $null; Agents = $null; AiModels = $null; Settings = $null; Error = $null
                }

                # WhoAmI needs no privilege, so it separates "not a user here" from "a user missing a privilege".
                $who = Invoke-CbxBlock "Dataverse:$display" {
                    Invoke-RestMethod -Uri "$dvRoot/api/data/v9.2/WhoAmI" -Headers $dvHeaders -Method Get
                }
                if (-not $who.Ok) {
                    $access.AppUser = $false
                    $access.Error = $who.Error
                    $blocks += [pscustomobject]@{
                        Name = "Dataverse:$display"; Ok = $false; Value = $null
                        Error = 'Dataverse refused the Automation identity, so agents and AI Builder models here were not read. ' +
                                'A System Administrator of this environment grants it under Settings, Roles & permissions, or runs scripts/Grant-CbxDataverseReader.ps1. (' + $who.Error + ')'
                    }
                }
                else {
                    $access.AppUser = $true
                    $dvHeaders.Prefer = 'odata.include-annotations="OData.Community.Display.V1.FormattedValue"'

                    $aiBlock = Invoke-CbxBlock "AIBuilder:$display" {
                        $url = "$dvRoot/api/data/v9.2/msdyn_aimodels?`$select=msdyn_name,statecode,_msdyn_templateid_value&`$top=500"
                        $response = Invoke-RestMethod -Uri $url -Headers $dvHeaders -Method Get
                        @($response.value)
                    }
                    if ($aiBlock.Ok) {
                        $access.AiModels = $true
                        if (@($aiBlock.Value).Count -ge 500) {
                            $blocks += [pscustomobject]@{ Name = "AIBuilder:$display"; Ok = $false; Value = $null; Error = 'Only the first 500 models were read; there may be more.' }
                        }
                        foreach ($model in @($aiBlock.Value)) {
                            [void]$aiModels.Add([pscustomobject]@{
                                Environment = $display
                                Name        = $model.msdyn_name
                                Kind        = $model.'_msdyn_templateid_value@OData.Community.Display.V1.FormattedValue'
                                State       = switch ([string]$model.statecode) { '1' { 'Active' } '0' { 'Inactive' } default { 'Not stated' } }
                            })
                        }
                    }
                    elseif ($aiBlock.Status -eq 404) {
                        # The table exists only where AI Builder is installed; absent is an answer, not a failure.
                        $access.AiModels = $null
                    }
                    else {
                        $access.AiModels = $false
                        $blocks += $aiBlock
                    }

                    $botBlock = Invoke-CbxBlock "CopilotStudio:$display" {
                        $url = "$dvRoot/api/data/v9.2/bots?`$select=name,schemaname,statecode,authenticationmode,accesscontrolpolicy,createdon&`$top=500"
                        $response = Invoke-RestMethod -Uri $url -Headers $dvHeaders -Method Get
                        @($response.value)
                    }
                    if ($botBlock.Ok) {
                        $access.Agents = $true
                        if (@($botBlock.Value).Count -ge 500) {
                            $blocks += [pscustomobject]@{ Name = "CopilotStudio:$display"; Ok = $false; Value = $null; Error = 'Only the first 500 agents were read; there may be more.' }
                        }
                        foreach ($bot in @($botBlock.Value)) {
                            [void]$agents.Add([pscustomobject]@{
                                Environment = $display
                                Name        = $bot.name
                                SchemaName  = $bot.schemaname
                                State       = if ($bot.statecode -eq 0) { 'Active' } else { 'Inactive' }
                                # Values from the Dataverse bot table reference. 1 is the one that matters:
                                # anyone who can reach the agent can use it, signed in or not.
                                AuthMode    = switch ([string]$bot.authenticationmode) {
                                    '1' { 'No authentication' }
                                    '2' { 'Microsoft Entra ID (integrated)' }
                                    '3' { 'Custom Entra ID' }
                                    '4' { 'Generic OAuth 2' }
                                    default { 'Not specified' }
                                }
                                # Dataverse's own label for who may chat with the agent.
                                Access      = $bot.'accesscontrolpolicy@OData.Community.Display.V1.FormattedValue'
                                Created     = $bot.createdon
                            })
                        }
                    }
                    elseif ($botBlock.Status -eq 404) {
                        $access.Agents = $null
                    }
                    else {
                        $access.Agents = $false
                        $blocks += $botBlock
                    }

                    # The environment's Copilot Studio transcript switches, on its settings row. Read without any extra privilege.
                    $settingsBlock = Invoke-CbxBlock "CopilotStudioSettings:$display" {
                        $url = "$dvRoot/api/data/v9.2/organizations?`$select=blocktranscriptrecordingforcopilotstudio,blockaccesstosessiontranscriptsforcopilotstudio"
                        @((Invoke-RestMethod -Uri $url -Headers $dvHeaders -Method Get).value) | Select-Object -First 1
                    }
                    if ($settingsBlock.Ok -and $settingsBlock.Value) {
                        $access.Settings = $true
                        $row = $settingsBlock.Value
                        [void]$copilotSettings.Add([pscustomobject]@{
                            Environment         = $display
                            TranscriptsSaved    = if ($null -ne $row.blocktranscriptrecordingforcopilotstudio) { -not [bool]$row.blocktranscriptrecordingforcopilotstudio } else { $null }
                            TranscriptsViewable = if ($null -ne $row.blockaccesstosessiontranscriptsforcopilotstudio) { -not [bool]$row.blockaccesstosessiontranscriptsforcopilotstudio } else { $null }
                        })
                    }
                    elseif ($settingsBlock.Status -eq 400) {
                        # An environment too old to have the columns: nothing to read, not a refusal.
                        $access.Settings = $null
                    }
                    else {
                        $access.Settings = $false
                        $blocks += [pscustomobject]@{
                            Name = "CopilotStudioSettings:$display"; Ok = $false; Value = $null
                            Error = 'The transcript settings were not read. (' + $settingsBlock.Error + ')'
                        }
                    }
                }

                [void]$dataverseAccess.Add($access)
            }
        }
    }

    Write-Result ([pscustomobject]@{
        CollectedAt      = (Get-Date).ToUniversalTime().ToString('o')
        EnvironmentCount = $environments.Count
        Environments     = @($environments | ForEach-Object {
            [pscustomobject]@{
                Name        = $_.properties.displayName
                Id          = $_.name
                Sku         = $_.properties.environmentSku
                IsDefault   = [bool]$_.properties.isDefault
                Region      = $_.location
                HasDataverse = [bool]$_.properties.linkedEnvironmentMetadata
            }
        })
        Apps     = @($apps)
        Flows    = @($flows)
        AiModels = @($aiModels)
        Agents   = @($agents)
        CopilotSettings = @($copilotSettings)
        DlpPolicies = @($dlpPolicies)
        Access   = [pscustomobject]@{
            # Environments is the first admin call; 401/403 there means the registration is missing.
            ManagementApp = if ($envBlock.Ok) { $true } elseif ($envBlock.Status -in 401, 403) { $false } else { $null }
            Dataverse     = @($dataverseAccess)
        }
        Blocks   = @($blocks | Select-Object Name, Ok, Error)
    })
}
catch {
    Write-Result ([pscustomobject]@{
        CollectedAt = (Get-Date).ToUniversalTime().ToString('o')
        Failed      = $true
        Error       = $_.Exception.Message
        Hint        = 'The Automation Account managed identity must be registered as a Power Platform ' +
                      'management application with New-PowerAppManagementApp, or every admin endpoint returns 403.'
    })
}
