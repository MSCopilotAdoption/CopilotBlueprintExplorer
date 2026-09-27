<#
.SYNOPSIS
    Collects Purview DLP policies and sensitivity labels, and writes them to the job output as JSON.

.DESCRIPTION
    Microsoft exposes no usable API for DLP policy or sensitivity label configuration. Security &
    Compliance PowerShell is the only supported route, and it accepts only certificate-based
    app-only authentication - managed identity is documented for Connect-ExchangeOnline alone. So
    this runs here, where the Automation Account holds the certificate, rather than in the web app.

    The result is written to the job output rather than posted back. That keeps the flow one-way:
    the app reads the job output over ARM with its own managed identity, so this runbook needs no
    inbound credential and no network path back into the app.

    Requires: the ExchangeOnlineManagement module, an Automation certificate asset, and an app
    registration holding the matching public key with Exchange.ManageAsApp plus a directory role.

    It also reads the tenant settings the posture engine cannot reach through Graph. Each of those
    reads is independent and carries its own error, so a refused one is reported by name and never
    stops the DLP collection:
      - Security & Compliance (the role groups above): information barriers, label-policy defaults,
        DSPM for AI collection policies, and - only if the role groups allow it - Insider Risk,
        Communication Compliance and audit retention policies.
      - Exchange Online: unified audit ingestion and Outlook add-in roles. Exchange app-only accepts
        only an Entra directory role; Global Reader is the least-privileged read-only one.
      - SharePoint Online (optional): tenant sharing, device access and per-site restrictions. Needs
        the Microsoft.Online.SharePoint.PowerShell module and the SharePoint application permission
        Sites.FullControl.All, the only permission Get-SPOTenant accepts app-only. Skipped, with the
        reason recorded, when either is missing.
#>

param(
    [Parameter(Mandatory = $true)] [string] $AppId,
    [Parameter(Mandatory = $true)] [string] $Organization,
    [string] $CertificateName = 'CbxPurviewCert',
    [string] $TenantId = '',
    [string] $SharePointAdminUrl = ''
)

$ErrorActionPreference = 'Stop'

# Sensitivity labels appear inside rule conditions as GUIDs. Populated once, best-effort.
$script:CbxLabelNames = @{}
# Sensitive information type names, looked up only if a policy names a type by id.
$script:CbxSitNames = $null

# Label-policy settings that decide default and mandatory labelling. Settings arrive as strings
# shaped "[key, value]"; anything else in them is irrelevant here.
$script:CbxPolicySettingKeys = @(
    'mandatory', 'defaultlabelid', 'disablemandatoryinoutlook', 'outlookdefaultlabel',
    'teamworkmandatory', 'teamworkdefaultlabelid', 'siteandgroupmandatory', 'siteandgroupdefaultlabelid',
    'powerbimandatory', 'powerbidefaultlabelid'
)

# A property the module version does not emit must stay null. Casting a missing property with
# [bool] would publish "false" as a measured fact about a setting nobody actually read.
function Get-CbxBool {
    param($Object, [string] $Name)
    if ($null -eq $Object) { return $null }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop -or $null -eq $prop.Value) { return $null }
    return [bool]$prop.Value
}

function Get-CbxInt {
    param($Object, [string] $Name)
    if ($null -eq $Object) { return $null }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop -or $null -eq $prop.Value) { return $null }
    return [int]$prop.Value
}

function Get-CbxText {
    param($Object, [string] $Name)
    if ($null -eq $Object) { return $null }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop -or $null -eq $prop.Value) { return $null }
    return [string]$prop.Value
}

function Get-CbxPolicySettings {
    param($Policy)

    $found = [ordered]@{}
    foreach ($entry in @($Policy.Settings)) {
        $match = [regex]::Match("$entry", '^\[\s*([^,\]]+?)\s*,\s*(.*?)\s*\]$')
        if (-not $match.Success) { continue }
        $key = $match.Groups[1].Value.ToLowerInvariant()
        if ($script:CbxPolicySettingKeys -notcontains $key) { continue }
        $value = $match.Groups[2].Value
        # Default labels are stored as GUIDs; the name is what a reader can act on.
        if ($key -like '*defaultlabel*') { $value = Resolve-CbxName -Value $value }
        $found[$key] = $value
    }
    return $found
}

<#
    Reads a cmdlet only if the collector's role groups expose it. Security & Compliance simply does
    not load a cmdlet the caller has no role for, so absence means "not permitted", not "empty".
#>
function Get-CbxOptionalRead {
    param([string] $Cmdlet, [scriptblock] $Shape)

    $result = [ordered]@{ available = $false; items = @(); error = $null }
    if (-not (Get-Command -Name $Cmdlet -ErrorAction SilentlyContinue)) { return $result }

    $result.available = $true
    try { $result.items = @(& $Cmdlet -ErrorAction Stop | ForEach-Object $Shape) }
    catch { $result.error = $_.Exception.Message }
    return $result
}

function Get-CbxFirstProp {
    param($Object, [string[]] $Names)
    foreach ($n in $Names) {
        $v = Get-CbxText $Object $n
        if ($v) { return $v }
    }
    return $null
}

<#
    A SharePoint Advanced Management insights report, collected in three stages across runs:
    start data collection if it is off, generate a report once data exists, read the latest
    completed report. A report older than seven days is regenerated, and the old one still read.
#>
function Get-CbxInsightReport {
    param([string] $Entity, [string] $Kind)

    $result = [ordered]@{
        collection    = $null
        action        = $null
        reportId      = $null
        reportStatus  = $null
        reportCreated = $null
        rowCount      = $null
        rows          = @()
        error         = $null
    }
    try {
        $status = @(Get-SPOAuditDataCollectionStatusForActivityInsights -ReportEntity $Entity -ErrorAction Stop) | Select-Object -First 1
        $result.collection = Get-CbxText $status 'DataCollectionStatus'
        if ($result.collection -eq 'NotStarted') {
            Start-SPOAuditDataCollectionForActivityInsights -ReportEntity $Entity -ErrorAction Stop | Out-Null
            $result.action = 'collection_started'
            return $result
        }

        $getCmd = "Get-SPO${Kind}InsightsReport"
        $startCmd = "Start-SPO${Kind}InsightsReport"
        $idNames = @('ReportId', 'Id')
        $statusNames = @('Status', 'ReportStatus', 'State')
        $dateNames = @('CreatedDateTime', 'TriggeredDateTime', 'CreatedTime', 'StartTime', 'ReportStartDateTime')

        $reports = @(& $getCmd -ErrorAction Stop | Where-Object { Get-CbxFirstProp $_ $idNames })
        $latest = $reports | Sort-Object { $d = Get-CbxFirstProp $_ $dateNames; if ($d) { [datetime]$d } else { [datetime]::MinValue } } -Descending |
            Select-Object -First 1
        $completed = $reports | Where-Object { (Get-CbxFirstProp $_ $statusNames) -match 'Complet|Succe' } |
            Sort-Object { $d = Get-CbxFirstProp $_ $dateNames; if ($d) { [datetime]$d } else { [datetime]::MinValue } } -Descending |
            Select-Object -First 1

        $latestDate = $null
        if ($latest) {
            $raw = Get-CbxFirstProp $latest $dateNames
            if ($raw) { $latestDate = [datetime]$raw }
        }
        $running = $latest -and (Get-CbxFirstProp $latest $statusNames) -match 'Progress|Running|NotStarted|Queued'
        if (-not $running -and ($null -eq $latestDate -or $latestDate -lt (Get-Date).AddDays(-7))) {
            try {
                & $startCmd -ReportPeriodInDays 28 -Force -ErrorAction Stop | Out-Null
                $result.action = 'report_started'
            }
            catch { $result.error = $_.Exception.Message }
        }
        elseif ($running) { $result.action = 'report_running' }

        if ($completed) {
            $result.reportId = Get-CbxFirstProp $completed $idNames
            $result.reportStatus = Get-CbxFirstProp $completed $statusNames
            $result.reportCreated = Get-CbxFirstProp $completed $dateNames
            $view = @{ ReportId = $result.reportId; Action = 'View'; ErrorAction = 'Stop' }
            if ($Kind -eq 'CopilotAgent') { $view['Content'] = 'CopilotAgentsOnSites' }
            $rows = @(& $getCmd @view)
            $result.rowCount = $rows.Count
            # Flattened to text: the report's columns are not documented, so nothing is assumed.
            $result.rows = @($rows | Select-Object -First 20 | ForEach-Object {
                    (($_.PSObject.Properties | Where-Object { $null -ne $_.Value -and "$($_.Value)" } |
                        Select-Object -First 8 | ForEach-Object { '{0}={1}' -f $_.Name, $_.Value }) -join '; ')
                })
        }
        elseif ($latest) {
            $result.reportStatus = Get-CbxFirstProp $latest $statusNames
            $result.reportCreated = Get-CbxFirstProp $latest $dateNames
        }
    }
    catch { $result.error = $_.Exception.Message }
    return $result
}

<#
    Data access governance reports that already exist, per report entity. Listing only: the
    collector never starts one, because which report to run is an administrator's decision.
#>
function Get-CbxDagReports {
    $result = [ordered]@{ reports = @(); unavailable = @(); error = $null }
    if (-not (Get-Command -Name 'Get-SPODataAccessGovernanceInsight' -ErrorAction SilentlyContinue)) {
        $result.error = 'Get-SPODataAccessGovernanceInsight is not in the imported SharePoint module version.'
        return $result
    }

    $statusNames = @('Status', 'ReportStatus', 'State')
    $dateNames = @('CreatedDateTime', 'TriggeredDateTime', 'CreatedTime', 'CreatedDate', 'StartTime', 'ReportStartDateTime', 'LastRefreshedDateTime')
    $reports = New-Object System.Collections.ArrayList
    $unavailable = New-Object System.Collections.ArrayList
    $entities = @('SharingLinks_Anyone', 'SharingLinks_PeopleInYourOrg', 'SharingLinks_Guests',
        'EveryoneExceptExternalUsersAtSite', 'EveryoneExceptExternalUsersForItems', 'SensitivityLabelForFiles', 'PermissionedUsers')
    foreach ($entity in $entities) {
        try {
            foreach ($r in @(Get-SPODataAccessGovernanceInsight -ReportEntity $entity -ErrorAction Stop)) {
                if ($null -eq $r) { continue }
                [void]$reports.Add([pscustomobject]@{
                        entity     = $entity
                        status     = (Get-CbxFirstProp $r $statusNames)
                        created    = (Get-CbxFirstProp $r $dateNames)
                        workload   = (Get-CbxText $r 'Workload')
                        reportType = (Get-CbxText $r 'ReportType')
                    })
                if ($reports.Count -ge 60) { break }
            }
        }
        catch {
            $why = $_.Exception.Message
            if ($why.Length -gt 200) { $why = $why.Substring(0, 200) }
            [void]$unavailable.Add(('{0}: {1}' -f $entity, $why))
        }
    }
    $result.reports = @($reports.ToArray())
    $result.unavailable = @($unavailable.ToArray())
    return $result
}

function Resolve-CbxName {
    param([string] $Value)

    if (-not $Value) { return $Value }
    if ($script:CbxLabelNames.ContainsKey($Value)) { return $script:CbxLabelNames[$Value] }
    return $Value
}

function Write-Result {
    param($Payload)
    # A single line so the caller can find it unambiguously among any host output.
    Write-Output ('CBX_DLP_JSON:' + ($Payload | ConvertTo-Json -Depth 8 -Compress))
}

<#
    Renders a condition's Value. Sensitive-information conditions nest the interesting part several
    levels down (Value > Groups > Sensitivetypes > Name), and everything is flattened to strings
    here so the JSON depth limit can never silently truncate a condition.
#>
function Format-CbxConditionValue {
    param($Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) { return $Value }
    if ($Value -is [bool]) { return $Value.ToString() }

    $names = New-Object System.Collections.ArrayList
    foreach ($entry in @($Value)) {
        if ($null -eq $entry) { continue }
        if ($entry -is [string]) { [void]$names.Add($entry); continue }

        if ($entry.PSObject.Properties.Name -contains 'Groups') {
            foreach ($group in @($entry.Groups)) {
                foreach ($sit in @($group.Sensitivetypes)) {
                    if ($sit.Name) { [void]$names.Add((Resolve-CbxName ([string]$sit.Name))) }
                }
                foreach ($label in @($group.Labels)) {
                    if ($label.Name) { [void]$names.Add((Resolve-CbxName ([string]$label.Name))) }
                }
            }
            continue
        }

        if ($entry.PSObject.Properties.Name -contains 'Name' -and $entry.Name) {
            [void]$names.Add((Resolve-CbxName ([string]$entry.Name)))
        }
    }

    if ($names.Count -eq 0) { return $null }
    return (($names | Select-Object -Unique) -join ', ')
}

function Add-CbxConditions {
    param($Node, [System.Collections.ArrayList] $Into)

    if ($null -eq $Node) { return }

    $props = $Node.PSObject.Properties.Name
    if ($props -contains 'SubConditions' -and $Node.SubConditions) {
        foreach ($sub in @($Node.SubConditions)) { Add-CbxConditions -Node $sub -Into $Into }
        return
    }

    if ($props -contains 'ConditionName' -and $Node.ConditionName) {
        $rendered = Format-CbxConditionValue -Value $Node.Value
        if ($rendered) {
            [void]$Into.Add("$($Node.ConditionName): $rendered")
        }
        else {
            [void]$Into.Add([string]$Node.ConditionName)
        }
    }
}

function Get-CbxRuleConditions {
    param($Rule)

    $found = New-Object System.Collections.ArrayList

    if ($Rule.AdvancedRule) {
        try {
            $parsed = $Rule.AdvancedRule | ConvertFrom-Json
            Add-CbxConditions -Node $parsed.Condition -Into $found
        }
        catch {
            [void]$found.Add('Could not parse the advanced rule definition.')
        }
    }

    # Simple (non-advanced) rules express conditions as plain properties instead.
    if ($found.Count -eq 0) {
        $simple = @(
            @('ContentContainsSensitiveInformation', 'Content contains'),
            @('ContentPropertyContainsWords', 'Content property contains'),
            @('SubjectContainsWords', 'Subject contains'),
            @('ContentFileTypeMatches', 'File type matches'),
            @('AccessScope', 'Access scope'),
            @('SharedByIRMUserRisk', 'User risk')
        )
        foreach ($pair in $simple) {
            $value = $Rule.($pair[0])
            if ($null -eq $value) { continue }
            $rendered = Format-CbxConditionValue -Value $value
            if ($rendered) { [void]$found.Add("$($pair[1]): $rendered") }
        }
    }

    return , @($found.ToArray())
}

<#
    The `Workload` property is NOT the set of locations a policy is switched on for - it reports
    Exchange, SharePoint and OneDriveForBusiness on virtually every policy regardless. The real
    answer is the per-location properties (populated only when that location is enabled) plus the
    `Locations` JSON, which is where the newer Copilot location lives.
#>
$script:CbxLocationProps = [ordered]@{
    ExchangeLocation             = 'Exchange email'
    SharePointLocation           = 'SharePoint sites'
    OneDriveLocation             = 'OneDrive accounts'
    TeamsLocation                = 'Teams chat and channel messages'
    EndpointDlpLocation          = 'Devices'
    ThirdPartyAppDlpLocation     = 'Managed cloud apps'
    OnPremisesScannerDlpLocation = 'On-premises repositories'
    PowerBIDlpLocation           = 'Fabric and Power BI workspaces'
    ExchangeOnPremisesLocation   = 'Exchange on-premises'
    SharePointOnPremisesLocation = 'SharePoint on-premises'
}

$script:CbxJsonLocationNames = @{
    'Copilot.M365' = 'Microsoft 365 Copilot and Copilot Chat'
}

function Format-CbxScope {
    param($Value, $Exceptions)

    $items = @($Value | ForEach-Object { "$_" } | Where-Object { $_ })
    if ($items.Count -eq 0) { return $null }

    $text = if ($items.Count -eq 1 -and $items[0] -eq 'All') { 'All users & groups' } else { $items -join ', ' }

    $excluded = @($Exceptions | ForEach-Object { "$_" } | Where-Object { $_ })
    if ($excluded.Count -gt 0) { $text = "$text (excluding $($excluded -join ', '))" }
    return $text
}

function Get-CbxPolicyLocations {
    param($Policy)

    $found = New-Object System.Collections.ArrayList

    foreach ($prop in $script:CbxLocationProps.Keys) {
        $value = $Policy.$prop
        if (-not $value -or @($value).Count -eq 0) { continue }
        [void]$found.Add([pscustomobject]@{
                name  = $script:CbxLocationProps[$prop]
                scope = (Format-CbxScope -Value $value -Exceptions $Policy."${prop}Exception")
            })
    }

    if ($Policy.Locations) {
        try {
            foreach ($loc in @($Policy.Locations | ConvertFrom-Json)) {
                if (-not $loc.Location) { continue }
                $name = if ($script:CbxJsonLocationNames.ContainsKey([string]$loc.Location)) {
                    $script:CbxJsonLocationNames[[string]$loc.Location]
                }
                else { [string]$loc.Location }
                $inclusions = @($loc.Inclusions | ForEach-Object { if ($_.DisplayName) { [string]$_.DisplayName } elseif ($_.Name) { [string]$_.Name } })
                [void]$found.Add([pscustomobject]@{
                        name  = $name
                        scope = (Format-CbxScope -Value $inclusions -Exceptions $null)
                    })
            }
        }
        catch { }
    }

    return , @($found.ToArray())
}

function Get-CbxLabelProtection {
    param($Label)

    $actions = New-Object System.Collections.ArrayList
    $removesProtection = $false

    foreach ($raw in @($Label.LabelActions)) {
        try {
            $action = $raw | ConvertFrom-Json
        }
        catch { continue }

        $settings = @{}
        foreach ($s in @($action.Settings)) {
            if ($s.Key) { $settings[[string]$s.Key] = [string]$s.Value }
        }
        if ($settings['disabled'] -eq 'true') { continue }

        switch ([string]$action.Type) {
            'encrypt' {
                if ($settings['protectiontype'] -eq 'removeprotection') {
                    $removesProtection = $true
                    [void]$actions.Add('Removes encryption')
                }
                else {
                    [void]$actions.Add('Encryption')
                }
            }
            'applycontentmarking' { [void]$actions.Add('Content marking') }
            'applywatermarking' { [void]$actions.Add('Watermark') }
            'applydynamicwatermarking' { [void]$actions.Add('Dynamic watermark') }
            default { if ($action.Type) { [void]$actions.Add([string]$action.Type) } }
        }
    }

    $encrypts = ($Label.EncryptionEnabled -eq $true) -and -not $removesProtection
    return [pscustomobject]@{
        encrypts = $encrypts
        actions  = @(($actions | Select-Object -Unique))
    }
}

function Get-CbxRuleActions {
    param($Rule)
    $actions = New-Object System.Collections.ArrayList

    if ($Rule.BlockAccess -eq $true) {
        if ($Rule.BlockAccessScope) {
            [void]$actions.Add("Block access ($($Rule.BlockAccessScope))")
        }
        else {
            [void]$actions.Add('Block access')
        }
    }
    if ($Rule.RestrictWebGrounding -eq $true) { [void]$actions.Add('Block web grounding') }
    if ($Rule.RestrictBrowserAccess -eq $true) { [void]$actions.Add('Restrict browser access') }
    if ($Rule.Quarantine -eq $true) { [void]$actions.Add('Quarantine') }
    if ($Rule.MoveToQuarantineLocation -eq $true -or $Rule.SPMoveToQuarantineLocation -eq $true) {
        [void]$actions.Add('Move to quarantine location')
    }
    if ($Rule.RemoveRMSTemplate -eq $true) { [void]$actions.Add('Remove encryption') }
    if ($Rule.BlockDomainsOrUsers -eq $true) { [void]$actions.Add('Block domains or users') }
    if ($Rule.RestrictAccess -and @($Rule.RestrictAccess).Count -gt 0) { [void]$actions.Add('Restrict access') }
    if ($Rule.NotifyUser -and @($Rule.NotifyUser).Count -gt 0) { [void]$actions.Add('Notify user') }
    if ($Rule.GenerateAlert -and @($Rule.GenerateAlert).Count -gt 0) {
        if ($Rule.ReportSeverityLevel) {
            [void]$actions.Add("Generate alert ($($Rule.ReportSeverityLevel))")
        }
        else {
            [void]$actions.Add('Generate alert')
        }
    }
    if ($Rule.StopPolicyProcessing -eq $true) { [void]$actions.Add('Stop further policy processing') }

    if ($actions.Count -eq 0) { [void]$actions.Add('Audit only - no enforcement action configured') }

    return , @($actions.ToArray())
}

<#
    Per-activity settings behind 'Audit or restrict activities': EndpointDlpRestrictions on devices
    (Print, RemovableMedia, CloudEgress, ...) and RestrictAccess on Copilot and cloud apps. Each
    becomes "Endpoint:Setting=Value" or "Access:Setting=Value". The module has returned these as
    hashtables, objects and JSON strings in different versions, so each shape is handled and an
    unrecognised one is kept as its text rather than dropped.
#>
function Get-CbxRuleRestrictions {
    param($Rule)
    $found = New-Object System.Collections.ArrayList

    foreach ($pair in @(@('EndpointDlpRestrictions', 'Endpoint'), @('RestrictAccess', 'Access'))) {
        if (-not ($pair -is [array])) { continue }
        $prop = $Rule.PSObject.Properties[$pair[0]]
        if ($null -eq $prop -or $null -eq $prop.Value) { continue }

        foreach ($entry in @($prop.Value)) {
            if ($null -eq $entry) { continue }
            $setting = $null
            $value = $null
            if ($entry -is [System.Collections.IDictionary]) {
                foreach ($k in @($entry.Keys)) {
                    if ("$k" -ieq 'setting') { $setting = [string]$entry[$k] }
                    elseif ("$k" -ieq 'value') { $value = [string]$entry[$k] }
                }
            }
            elseif ($entry -isnot [string] -and $entry.PSObject.Properties['Setting']) {
                $setting = [string]$entry.Setting
                $value = [string]$entry.Value
            }
            else {
                $text = [string]$entry
                $parsed = [regex]::Match($text, '(?i)setting\W+([A-Za-z0-9_]+).*?value\W+([A-Za-z0-9_]+)')
                if ($parsed.Success) {
                    $setting = $parsed.Groups[1].Value
                    $value = $parsed.Groups[2].Value
                }
                else { $setting = $text }
            }
            if (-not $setting) { continue }
            $item = if ($value) { '{0}:{1}={2}' -f $pair[1], $setting, $value } else { '{0}:{1}' -f $pair[1], $setting }
            if ($item.Length -gt 160) { $item = $item.Substring(0, 160) }
            [void]$found.Add($item)
            if ($found.Count -ge 40) { break }
        }
    }

    return , @($found.ToArray())
}

<#
    Per-policy configuration for Insider Risk, Communication Compliance, DSPM for AI and information
    barriers. Values stay Purview's own identifiers and the console words them. Who an Insider Risk or
    Communication Compliance policy watches is recorded as a count only: being named in one is itself
    sensitive, so the names never leave Purview.
#>
function ConvertFrom-CbxJson {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) {
        $text = $Value.Trim()
        if ($text.Length -lt 2) { return $null }
        try { return (ConvertFrom-Json -InputObject $text -ErrorAction Stop) } catch { return $null }
    }
    # Some properties (ContentSources, SensitivityLabels) are a collection of JSON strings.
    if ($Value -is [System.Collections.IEnumerable]) {
        foreach ($v in $Value) { ConvertFrom-CbxJson $v }
        return
    }
    return $Value
}

function Add-CbxFacet {
    param([System.Collections.ArrayList] $Into, [string] $Key, $Items, [string] $Group = '')
    $list = @(@($Items) | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
    if ($list.Count -eq 0) { return }
    [void]$Into.Add([pscustomobject]@{
            key   = $Key
            group = if ($Group) { $Group } else { $null }
            items = $list
        })
}

function Get-CbxJsonNames {
    param($Values)
    $names = New-Object System.Collections.ArrayList
    foreach ($raw in @($Values)) {
        foreach ($o in @(ConvertFrom-CbxJson $raw)) {
            if ($null -ne $o -and "$($o.Name)" -and -not $names.Contains("$($o.Name)")) { [void]$names.Add("$($o.Name)") }
        }
    }
    return , @($names.ToArray())
}

function Get-CbxUtc {
    param($Object, [string[]] $Names)
    foreach ($n in $Names) {
        $prop = $Object.PSObject.Properties[$n]
        if ($null -eq $prop -or $null -eq $prop.Value) { continue }
        try {
            $when = if ($prop.Value -is [datetime]) { $prop.Value } else { [datetime]::Parse("$($prop.Value)", [Globalization.CultureInfo]::InvariantCulture) }
            $when = if ($n -like '*utc*') { [datetime]::SpecifyKind($when, 'Utc') } else { $when.ToUniversalTime() }
            return $when.ToString('o')
        }
        catch { continue }
    }
    return $null
}

function Resolve-CbxSits {
    param($Ids)
    $out = New-Object System.Collections.ArrayList
    foreach ($id in @($Ids)) {
        $k = "$id"
        if (-not $k) { continue }
        if ($k -eq 'All') { [void]$out.Add('All'); continue }
        if ($null -eq $script:CbxSitNames) {
            $script:CbxSitNames = @{}
            try {
                foreach ($sit in @(Get-DlpSensitiveInformationType -ErrorAction Stop)) { $script:CbxSitNames["$($sit.Id)"] = "$($sit.Name)" }
            }
            catch { }
        }
        [void]$out.Add($(if ($script:CbxSitNames.ContainsKey($k)) { $script:CbxSitNames[$k] } else { $k }))
    }
    return , @($out.ToArray())
}

# Communication Compliance advanced rules nest conditions; trainable classifiers sit under datamodels.
function Add-CbxCcCondition {
    param($Node, [System.Collections.ArrayList] $Classifiers, [System.Collections.ArrayList] $Conditions)
    if ($null -eq $Node) { return }
    foreach ($sub in @($Node.subconditions)) {
        if ($null -ne $sub) { Add-CbxCcCondition -Node $sub -Classifiers $Classifiers -Conditions $Conditions }
    }
    $name = "$($Node.conditionname)"
    if (-not $name) { return }
    $models = @(@($Node.value.datamodels) | Where-Object { $_ })
    if ($models.Count -gt 0) {
        foreach ($m in $models) {
            if ("$($m.name)" -and -not $Classifiers.Contains("$($m.name)")) { [void]$Classifiers.Add("$($m.name)") }
        }
        return
    }
    $rendered = Format-CbxConditionValue -Value $Node.value
    [void]$Conditions.Add($(if ($rendered) { "${name}: $rendered" } else { $name }))
}

function New-CbxPolicyRecord {
    param($Source, $Mode, $Enabled, $AiRelated, $Template, $Health, [System.Collections.ArrayList] $Facets)
    [pscustomobject]@{
        name           = Get-CbxText $Source 'Name'
        description    = Get-CbxText $Source 'Comment'
        mode           = $Mode
        enabled        = $Enabled
        aiRelated      = $AiRelated
        template       = $Template
        distribution   = Get-CbxText $Source 'DistributionStatus'
        health         = $Health
        createdBy      = Get-CbxText $Source 'CreatedBy'
        lastModifiedBy = Get-CbxText $Source 'LastModifiedBy'
        created        = Get-CbxUtc $Source @('CreationTimeUtc', 'WhenCreatedUTC', 'WhenCreated')
        lastModified   = Get-CbxUtc $Source @('ModificationTimeUtc', 'WhenChangedUTC', 'WhenChanged')
        facets         = @($Facets.ToArray())
    }
}

try {
    $certificate = Get-AutomationCertificate -Name $CertificateName
    if ($null -eq $certificate) {
        throw "Automation certificate '$CertificateName' was not found."
    }

    # ---- Tenant posture: Teams -------------------------------------------------------------
    # Read before ExchangeOnlineManagement loads: both modules ship an authentication library and
    # the first one loaded wins, and this order is the one verified to work in Windows PowerShell.
    $teams = [ordered]@{
        connected           = $false
        error               = $null
        permissionPolicy    = $null
        permissionPolicies  = $null
        setupPolicies       = $null
        sideloadingPolicies = @()
        customAppsEnabled   = $null
    }
    if (-not $TenantId) {
        $teams.error = 'not_configured: the tenant id was not supplied.'
    }
    elseif (-not (Get-Module -ListAvailable -Name MicrosoftTeams)) {
        $teams.error = 'module_missing: MicrosoftTeams is not imported into the Automation account.'
    }
    else {
        try {
            Import-Module MicrosoftTeams -ErrorAction Stop
            Connect-MicrosoftTeams -Certificate $certificate -ApplicationId $AppId -TenantId $TenantId -ErrorAction Stop | Out-Null
            $teams.connected = $true

            $globalPolicy = Get-CsTeamsAppPermissionPolicy -Identity Global -ErrorAction Stop
            $teams.permissionPolicy = [pscustomobject]@{
                microsoftApps  = (Get-CbxText $globalPolicy 'DefaultCatalogAppsType')
                microsoftList  = @($globalPolicy.DefaultCatalogApps | ForEach-Object { "$($_.Id)" })
                thirdPartyApps = (Get-CbxText $globalPolicy 'GlobalCatalogAppsType')
                thirdPartyList = @($globalPolicy.GlobalCatalogApps | ForEach-Object { "$($_.Id)" })
                customApps     = (Get-CbxText $globalPolicy 'PrivateCatalogAppsType')
                customList     = @($globalPolicy.PrivateCatalogApps | ForEach-Object { "$($_.Id)" })
            }
            $teams.permissionPolicies = @(Get-CsTeamsAppPermissionPolicy -ErrorAction Stop).Count

            $setup = @(Get-CsTeamsAppSetupPolicy -ErrorAction Stop)
            $teams.setupPolicies = $setup.Count
            $teams.sideloadingPolicies = @($setup | Where-Object { $_.AllowSideLoading -eq $true } |
                    ForEach-Object { "$($_.Identity)" -replace '^Tag:', '' })
            $teams.customAppsEnabled = Get-CbxBool (Get-CsTeamsSettingsCustomApp -ErrorAction Stop) 'IsSideloadedAppsInteractionEnabled'
        }
        catch { $teams.error = $_.Exception.Message }
        finally {
            try { Disconnect-MicrosoftTeams -ErrorAction SilentlyContinue | Out-Null } catch { }
        }
    }

    Import-Module ExchangeOnlineManagement -ErrorAction Stop

    Connect-IPPSSession `
        -Certificate $certificate `
        -AppId $AppId `
        -Organization $Organization `
        -ShowBanner:$false `
        -ErrorAction Stop | Out-Null

    $raw = @(Get-DlpCompliancePolicy -ErrorAction Stop)

    # Best-effort: a label read failure must not lose the whole policy collection, it only means
    # conditions keep showing the raw GUID.
    try {
        foreach ($label in @(Get-Label -ErrorAction Stop)) {
            $display = [string]$label.DisplayName
            if (-not $display) { continue }
            foreach ($key in @([string]$label.Guid, [string]$label.Name)) {
                if ($key -and -not $script:CbxLabelNames.ContainsKey($key)) {
                    $script:CbxLabelNames[$key] = $display
                }
            }
        }
    }
    catch { }

    # One call for every rule, then grouped locally - per-policy calls would be 60+ round trips.
    $rulesByPolicy = @{}
    foreach ($rule in @(Get-DlpComplianceRule -ErrorAction Stop)) {
        $parent = [string]$rule.ParentPolicyName
        if (-not $parent) { continue }
        if (-not $rulesByPolicy.ContainsKey($parent)) {
            $rulesByPolicy[$parent] = New-Object System.Collections.ArrayList
        }
        [void]$rulesByPolicy[$parent].Add([pscustomobject]@{
                name       = [string]$rule.Name
                priority   = if ($null -ne $rule.Priority) { [int]$rule.Priority } else { $null }
                disabled   = if ($null -ne $rule.Disabled) { [bool]$rule.Disabled } else { $null }
                # No @() here: the helpers already return a non-unrolling array, and wrapping again
                # nests it one level deeper.
                conditions = (Get-CbxRuleConditions -Rule $rule)
                actions    = (Get-CbxRuleActions -Rule $rule)
                restrictions = (Get-CbxRuleRestrictions -Rule $rule)
            })
    }

    $policies = @($raw | ForEach-Object {
            $workloads = @()
            if ($_.Workload) {
                $workloads = @($_.Workload -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            }

            # Copilot scope is carried as an "Applications" location named Copilot.M365, which is
            # more precise than the workload alone.
            $copilotLocations = New-Object System.Collections.ArrayList
            if ($_.Locations) {
                try {
                    foreach ($loc in @($_.Locations | ConvertFrom-Json)) {
                        if ($loc.Workload -eq 'Applications' -and $loc.Location) {
                            [void]$copilotLocations.Add([string]$loc.Location)
                        }
                    }
                }
                catch { }
            }

            $policyName = [string]$_.Name
            $policyRules = @()
            if ($rulesByPolicy.ContainsKey($policyName)) {
                $policyRules = @($rulesByPolicy[$policyName].ToArray())
            }

            [pscustomobject]@{
                name             = $policyName
                mode             = [string]$_.Mode
                priority         = if ($null -ne $_.Priority) { [int]$_.Priority } else { $null }
                # Left null when the cmdlet did not report it. Coercing to false would publish
                # "disabled" as a measured fact about a policy nobody actually checked.
                enabled          = if ($null -ne $_.Enabled) { [bool]$_.Enabled } else { $null }
                workloads        = $workloads
                locations        = (Get-CbxPolicyLocations -Policy $_)
                copilotLocations = @($copilotLocations.ToArray())
                appliesToCopilot = ($copilotLocations.Count -gt 0)
                rules            = $policyRules
                createdBy        = [string]$_.CreatedBy
                lastModifiedBy   = (Get-CbxText $_ 'LastModifiedBy')
                comment          = (Get-CbxText $_ 'Comment')
                # Purview's own AI mark, and the set its DSPM for AI policies page lists.
                category         = (Get-CbxText $_ 'PolicyCategory')
                lastModified     = if ($_.WhenChanged) { ([datetime]$_.WhenChanged).ToUniversalTime().ToString('o') } else { $null }
            }
        })

    # Auto-labelling conditions are stored on the LABEL itself as a nested And/Or tree whose leaves
    # are sensitive information types. Walk it rather than assuming a shape.
    function Get-CbxConditionLeaves {
        param($Node, [System.Collections.ArrayList]$Into)

        if ($null -eq $Node) { return }
        foreach ($op in @('And', 'Or')) {
            if ($Node.PSObject.Properties[$op]) {
                foreach ($child in @($Node.$op)) { Get-CbxConditionLeaves -Node $child -Into $Into }
            }
        }
        if ($Node.PSObject.Properties['Key'] -and "$($Node.Key)") { [void]$Into.Add($Node) }
    }

    function Get-CbxAutoLabel {
        param($Label)

        $raw = "$($Label.Conditions)".Trim()
        if ($raw.Length -lt 3) { return $null }

        try { $parsed = $raw | ConvertFrom-Json -ErrorAction Stop }
        catch { return [pscustomobject]@{ mode = 'Unreadable'; conditions = @(); tip = $null } }

        $leaves = New-Object System.Collections.ArrayList
        Get-CbxConditionLeaves -Node $parsed -Into $leaves
        if ($leaves.Count -eq 0) { return $null }

        # Purview writes autoapplytype only when the label is RECOMMENDED; its absence means the
        # label is applied without asking the user.
        $mode = 'Automatic'
        $tip = $null
        $items = New-Object System.Collections.ArrayList

        foreach ($leaf in $leaves) {
            $s = @{}
            foreach ($kv in @($leaf.Settings)) {
                if ($kv -and "$($kv.Key)") { $s["$($kv.Key)".ToLowerInvariant()] = "$($kv.Value)" }
            }

            if ($s['autoapplytype'] -eq 'Recommend') { $mode = 'Recommended' }
            if ($s['policytip']) { $tip = $s['policytip'] }

            $detail = New-Object System.Collections.ArrayList
            if ($s.ContainsKey('mincount')) {
                $max = $s['maxcount']
                if ($max -and $max -ne '-1') { [void]$detail.Add("$($s['mincount'])-$max occurrences") }
                else { [void]$detail.Add("$($s['mincount'])+ occurrences") }
            }
            if ($s['confidencelevel']) { [void]$detail.Add("$($s['confidencelevel'])".ToLowerInvariant() + ' confidence') }

            [void]$items.Add([pscustomobject]@{
                    name   = if ($s['name']) { $s['name'] } else { "$($leaf.Value)" }
                    detail = ($detail -join ', ')
                })
        }

        [pscustomobject]@{ mode = $mode; conditions = @($items); tip = $tip }
    }

    $labels = @()
    $labelPolicies = @()
    $labelDefaults = @()
    $labelError = $null
    try {
        $publishedIn = @{}
        foreach ($policy in @(Get-LabelPolicy -ErrorAction Stop)) {
            $labelPolicies += [pscustomobject]@{
                name       = [string]$policy.Name
                mode       = [string]$policy.Mode
                enabled    = if ($null -ne $policy.Enabled) { [bool]$policy.Enabled } else { $null }
                labelCount = @($policy.Labels).Count
                scope      = (Format-CbxScope -Value $policy.ExchangeLocation -Exceptions $policy.ExchangeLocationException)
            }
            $labelDefaults += [pscustomobject]@{
                policy   = [string]$policy.Name
                enabled  = if ($null -ne $policy.Enabled) { [bool]$policy.Enabled } else { $null }
                scope    = (Format-CbxScope -Value $policy.ExchangeLocation -Exceptions $policy.ExchangeLocationException)
                settings = (Get-CbxPolicySettings -Policy $policy)
            }
            # Policies reference labels by display name OR by GUID, so index whatever is there.
            foreach ($key in @($policy.Labels)) {
                $k = "$key"
                if (-not $k) { continue }
                if (-not $publishedIn.ContainsKey($k)) { $publishedIn[$k] = New-Object System.Collections.ArrayList }
                [void]$publishedIn[$k].Add([string]$policy.Name)
            }
        }

        $raw = @(Get-Label -IncludeDetailedLabelActions -ErrorAction Stop)
        $byId = @{}
        foreach ($label in $raw) { $byId["$($label.Guid)"] = [string]$label.DisplayName }

        $labels = @($raw | ForEach-Object {
                $protection = Get-CbxLabelProtection -Label $_

                $appliesTo = @()
                if ($_.ContentType -and "$($_.ContentType)" -ne 'None') {
                    $appliesTo = @("$($_.ContentType)" -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                }

                $published = New-Object System.Collections.ArrayList
                foreach ($key in @("$($_.Guid)", "$($_.Name)", "$($_.DisplayName)")) {
                    if ($key -and $publishedIn.ContainsKey($key)) {
                        foreach ($p in $publishedIn[$key]) { [void]$published.Add($p) }
                    }
                }

                $parentId = "$($_.ParentId)"

                [pscustomobject]@{
                    id           = "$($_.Guid)"
                    name         = [string]$_.DisplayName
                    tooltip      = [string]$_.Tooltip
                    parentId     = if ($parentId) { $parentId } else { $null }
                    parentName   = if ($parentId -and $byId.ContainsKey($parentId)) { $byId[$parentId] } else { $null }
                    isGroup      = ($_.IsParent -eq $true)
                    appliesTo    = $appliesTo
                    mode         = [string]$_.Mode
                    priority     = if ($null -ne $_.Priority) { [int]$_.Priority } else { $null }
                    disabled     = if ($null -ne $_.Disabled) { [bool]$_.Disabled } else { $null }
                    encrypts     = $protection.encrypts
                    actions      = @($protection.actions)
                    publishedIn  = @(($published | Select-Object -Unique))
                    autoLabel    = (Get-CbxAutoLabel -Label $_)
                    lastModified = if ($_.WhenChanged) { ([datetime]$_.WhenChanged).ToUniversalTime().ToString('o') } else { $null }
                }
            })
    }
    catch {
        # Labels are secondary here: a failure must not lose the DLP collection. Left as empty
        # arrays with the reason attached rather than pretending none exist.
        $labelError = $_.Exception.Message
    }

    # Service-side auto-labelling (SharePoint, OneDrive, Exchange) is a separate mechanism from the
    # client-side conditions carried on the label, so it is collected separately.
    $autoLabelPolicies = @()
    $autoLabelError = $null
    try {
        foreach ($alp in @(Get-AutoSensitivityLabelPolicy -ErrorAction Stop)) {
            $autoLabelPolicies += [pscustomobject]@{
                name    = [string]$alp.Name
                label   = (Resolve-CbxName -Value "$($alp.ApplySensitivityLabel)")
                mode    = [string]$alp.Mode
                enabled = if ($null -ne $alp.Enabled) { [bool]$alp.Enabled } else { $null }
                status  = [string]$alp.DistributionStatus
            }
        }
    }
    catch {
        $autoLabelError = $_.Exception.Message
    }

    $retentionLabels = @()
    $retentionPolicies = @()
    $retentionPosture = New-Object System.Collections.ArrayList
    $retentionError = $null
    try {
        $retPolicyByGuid = @{}
        foreach ($rp in @(Get-RetentionCompliancePolicy -ErrorAction Stop)) {
            $retPolicyByGuid["$($rp.Guid)"] = $rp
            $retentionPolicies += [pscustomobject]@{
                name    = [string]$rp.Name
                enabled = if ($null -ne $rp.Enabled) { [bool]$rp.Enabled } else { $null }
                mode    = [string]$rp.Mode
                type    = [string]$rp.Type
                status  = [string]$rp.DistributionStatus
            }

            # Which locations it covers, by Purview's own property names. The Copilot location's
            # property is not documented, so every populated *Location and the Applications value
            # are kept and the console decides.
            $covered = @($rp.PSObject.Properties | Where-Object {
                    $_.Name -like '*Location' -and $null -ne $_.Value -and @($_.Value).Count -gt 0 -and "$(@($_.Value)[0])"
                } | ForEach-Object { [string]$_.Name })
            $apps = @()
            $appProp = $rp.PSObject.Properties['Applications']
            if ($appProp -and $null -ne $appProp.Value) {
                $apps = @(@($appProp.Value) | ForEach-Object { [string]$_ } | Where-Object { $_ } | Select-Object -First 20)
            }
            [void]$retentionPosture.Add([pscustomobject]@{
                    name         = [string]$rp.Name
                    enabled      = if ($null -ne $rp.Enabled) { [bool]$rp.Enabled } else { $null }
                    mode         = [string]$rp.Mode
                    locations    = $covered
                    applications = $apps
                })
        }

        # A label's own Policy property points at its container, NOT at a retention policy. The only
        # link between a label and the policy that publishes it lives on the rules.
        $publishRules = @{}
        $applyRules = @{}
        foreach ($rule in @(Get-RetentionComplianceRule -ErrorAction SilentlyContinue)) {
            $owner = $retPolicyByGuid["$($rule.Policy)"]
            $ownerName = if ($owner) { [string]$owner.Name } else { "$($rule.Policy)" }

            foreach ($key in ("$($rule.PublishComplianceTag)" -split ',')) {
                $k = $key.Trim()
                if (-not $k) { continue }
                if (-not $publishRules.ContainsKey($k)) { $publishRules[$k] = New-Object System.Collections.ArrayList }
                [void]$publishRules[$k].Add($ownerName)
            }

            $applied = "$($rule.ApplyComplianceTag)"
            if ($applied) {
                $how = New-Object System.Collections.ArrayList
                if ("$($rule.ContentMatchQuery)") { [void]$how.Add("content matching $($rule.ContentMatchQuery)") }
                if ($rule.ContentContainsSensitiveInformation) { [void]$how.Add('content with a sensitive information type') }
                $detail = if ($how.Count -gt 0) { ($how -join '; ') } else { 'all content in the policy locations' }

                foreach ($key in ($applied -split ',')) {
                    $k = $key.Trim()
                    if (-not $k) { continue }
                    if (-not $applyRules.ContainsKey($k)) { $applyRules[$k] = New-Object System.Collections.ArrayList }
                    [void]$applyRules[$k].Add([pscustomobject]@{ policy = $ownerName; how = $detail })
                }
            }
        }

        foreach ($tag in @(Get-ComplianceTag -ErrorAction Stop)) {
            $days = $null
            $durationText = "$($tag.RetentionDuration)".Trim()
            $parsedDays = 0
            if ([int]::TryParse($durationText, [ref]$parsedDays)) { $days = $parsedDays; $durationText = $null }
            elseif (-not $durationText) { $durationText = $null }

            $pub = New-Object System.Collections.ArrayList
            $auto = New-Object System.Collections.ArrayList
            foreach ($k in @("$($tag.Guid)", "$($tag.Name)")) {
                if ($k -and $publishRules.ContainsKey($k)) { foreach ($v in $publishRules[$k]) { [void]$pub.Add($v) } }
                if ($k -and $applyRules.ContainsKey($k)) { foreach ($v in $applyRules[$k]) { [void]$auto.Add($v) } }
            }

            $retentionLabels += [pscustomobject]@{
                name          = [string]$tag.Name
                description   = [string]$tag.Comment
                days          = $days
                durationText  = $durationText
                action        = [string]$tag.RetentionAction
                trigger       = [string]$tag.RetentionType
                isRecord      = ($tag.IsRecordLabel -eq $true)
                regulatory    = ($tag.Regulatory -eq $true)
                publishedIn   = @(($pub | Select-Object -Unique))
                autoAppliedBy = @($auto)
                lastModified  = if ($tag.WhenChanged) { ([datetime]$tag.WhenChanged).ToUniversalTime().ToString('o') } else { $null }
            }
        }
    }
    catch {
        $retentionError = $_.Exception.Message
    }

    $violations = $null
    $violationError = $null
    try {
        # Activity Explorer only accepts a window strictly inside the last 30 days.
        $windowDays = 28
        $endTime = (Get-Date).AddHours(-1)
        $startTime = $endTime.AddDays(-$windowDays)

        $byUser = @{}
        $byPolicy = @{}
        $scanned = 0
        $matched = 0
        $cookie = $null
        $pages = 0
        $lastPage = $false

        do {
            # Not $args: that is an automatic variable and splatting into it silently misbehaves.
            $query = @{
                StartTime    = $startTime
                EndTime      = $endTime
                OutputFormat = 'Json'
                PageSize     = 500
                ErrorAction  = 'Stop'
            }
            if ($cookie) { $query['PageCookie'] = $cookie }

            $page = Export-ActivityExplorerData @query
            # Property is WaterMark with a capital M, and LastPage is what ends the loop.
            $cookie = $page.WaterMark
            $lastPage = [bool]$page.LastPage
            $pages++

            foreach ($chunk in @($page.ResultData)) {
                # Each ResultData entry is a JSON ARRAY of activity rows, not one row. Without this
                # expansion every property read returns an array and all rows collapse into one.
                try { $rows = $chunk | ConvertFrom-Json } catch { continue }

                foreach ($row in @($rows)) {
                    $scanned++

                    # NOT $policies - that name already holds the DLP policy array built above.
                    $matchedPolicies = @($row.MatchedPolicies | Where-Object { $_.PolicyName })
                    if ($matchedPolicies.Count -eq 0 -and $row.PolicyMatchInfo.PolicyName) {
                        $matchedPolicies = @($row.PolicyMatchInfo)
                    }
                    if ($matchedPolicies.Count -eq 0) { continue }

                    $matched++
                    $user = [string]$row.User
                    if (-not $user) { $user = '(unattributed)' }

                    if (-not $byUser.ContainsKey($user)) {
                        $byUser[$user] = [pscustomobject]@{
                            user      = $user
                            count     = 0
                            blocked   = 0
                            policies  = New-Object System.Collections.ArrayList
                            workloads = New-Object System.Collections.ArrayList
                            lastAt    = $null
                        }
                    }
                    $entry = $byUser[$user]
                    $entry.count++
                    if ("$($row.EnforcementMode)" -eq 'Block') { $entry.blocked++ }
                    if ($row.Workload -and -not $entry.workloads.Contains([string]$row.Workload)) {
                        [void]$entry.workloads.Add([string]$row.Workload)
                    }
                    if ($row.Happened) {
                        $when = ([datetime]$row.Happened).ToUniversalTime()
                        if ($null -eq $entry.lastAt -or $when -gt $entry.lastAt) { $entry.lastAt = $when }
                    }

                    foreach ($p in $matchedPolicies) {
                        $name = [string]$p.PolicyName
                        if (-not $name) { continue }
                        if (-not $entry.policies.Contains($name)) { [void]$entry.policies.Add($name) }
                        if (-not $byPolicy.ContainsKey($name)) {
                            $byPolicy[$name] = [pscustomobject]@{
                                policy = $name
                                count  = 0
                                users  = New-Object System.Collections.ArrayList
                            }
                        }
                        $byPolicy[$name].count++
                        if (-not $byPolicy[$name].users.Contains($user)) { [void]$byPolicy[$name].users.Add($user) }
                    }
                }
            }
        } while (-not $lastPage -and $cookie -and $pages -lt 20)

        $violations = [pscustomobject]@{
            windowDays       = $windowDays
            activitiesScanned = $scanned
            matchedActivities = $matched
            truncated        = (-not $lastPage)
            users            = @($byUser.Values | ForEach-Object {
                    [pscustomobject]@{
                        user      = $_.user
                        count     = $_.count
                        blocked   = $_.blocked
                        policies  = @($_.policies.ToArray())
                        workloads = @($_.workloads.ToArray())
                        lastAt    = if ($_.lastAt) { $_.lastAt.ToString('o') } else { $null }
                    }
                } | Sort-Object -Property count -Descending)
            policies         = @($byPolicy.Values | ForEach-Object {
                    [pscustomobject]@{
                        policy = $_.policy
                        count  = $_.count
                        users  = $_.users.Count
                    }
                } | Sort-Object -Property count -Descending)
        }
    }
    catch {
        $violationError = $_.Exception.Message
    }

    # ---- Tenant posture: Security & Compliance ---------------------------------------------
    $informationBarriers = [ordered]@{ policies = @(); segments = @(); error = $null }
    $ibSegmentsRaw = @()
    $ibPoliciesRaw = @()
    try {
        $ibSegmentsRaw = @(Get-OrganizationSegment -ErrorAction Stop)
        $informationBarriers.segments = @($ibSegmentsRaw | ForEach-Object { [string]$_.Name })
        $ibPoliciesRaw = @(Get-InformationBarrierPolicy -ErrorAction Stop)
        $informationBarriers.policies = @($ibPoliciesRaw | ForEach-Object {
                [pscustomobject]@{
                    name    = [string]$_.Name
                    state   = [string]$_.State
                    segment = [string]$_.AssignedSegment
                }
            })
    }
    catch { $informationBarriers.error = $_.Exception.Message }

    # DSPM for AI stores its collection policies as feature configurations. EnforcementPlanes says
    # what each one covers: CopilotExperiences, Application (enterprise AI apps) or Browser.
    $aiCollection = [ordered]@{ policies = @(); error = $null }
    $aiRaw = @()
    try {
        # -FeatureScenario is mandatory in practice: without it the cmdlet prompts and the job hangs.
        $aiRaw = @(Get-FeatureConfiguration -FeatureScenario KnowYourData -ErrorAction Stop)
        $aiCollection.policies = @($aiRaw | ForEach-Object {
                $feature = $_
                $planes = @()
                $activities = @()
                $ingestion = $null
                try {
                    $config = "$($feature.ScenarioConfig)" | ConvertFrom-Json -ErrorAction Stop
                    $planes = @($config.EnforcementPlanes | ForEach-Object { "$_" } | Where-Object { $_ })
                    $activities = @($config.Activities | ForEach-Object { "$_" } | Where-Object { $_ })
                    if ($null -ne $config.IsIngestionEnabled) { $ingestion = [bool]$config.IsIngestionEnabled }
                }
                catch { }
                [pscustomobject]@{
                    name       = [string]$feature.Name
                    mode       = [string]$feature.Mode
                    category   = [string]$feature.PolicyCategory
                    planes     = $planes
                    activities = $activities
                    ingestion  = $ingestion
                }
            })
    }
    catch { $aiCollection.error = $_.Exception.Message }

    # Microsoft ships these cmdlets only in write-capable roles (the collector holds Compliance
    # Administrator for them and calls nothing but these Get cmdlets). Without the role they are
    # simply not loaded, which is reported as "not permitted" rather than as "none".
    # Read raw once: the posture summary and the per-policy detail below both come from it.
    $irmRead = Get-CbxOptionalRead -Cmdlet 'Get-InsiderRiskPolicy' -Shape { $_ }
    # The tenant-settings record is stored as a policy but is not one.
    $irmRaw = @(@($irmRead.items) | Where-Object { $_ -and (Get-CbxText $_ 'InsiderRiskScenario') -ne 'TenantSetting' })
    $insiderRisk = [ordered]@{
        available = $irmRead.available
        items     = @($irmRaw | ForEach-Object {
                [pscustomobject]@{
                    name    = [string]$_.Name
                    detail  = (Get-CbxText $_ 'InsiderRiskScenario')
                    scope   = (Get-CbxText $_ 'PolicyCategory')
                    enabled = ((Get-CbxBool $_ 'Enabled') -ne $false -and (Get-CbxText $_ 'Mode') -ne 'Disable')
                }
            })
        error     = $irmRead.error
    }

    # Workloads live on the rules (ContentSources JSON), so rules are read once and keyed by policy.
    $ccWorkloads = @{}
    $ccRulesByPolicy = @{}
    if (Get-Command -Name Get-SupervisoryReviewRule -ErrorAction SilentlyContinue) {
        try {
            foreach ($ccRule in @(Get-SupervisoryReviewRule -ErrorAction Stop)) {
                $sources = $null
                try { $sources = "$($ccRule.ContentSources)" | ConvertFrom-Json -ErrorAction Stop } catch { }
                $key = "$($ccRule.Policy)"
                if (-not $ccWorkloads.ContainsKey($key)) { $ccWorkloads[$key] = New-Object System.Collections.ArrayList }
                foreach ($w in @($sources.Workloads)) { if ($w -and -not $ccWorkloads[$key].Contains("$w")) { [void]$ccWorkloads[$key].Add("$w") } }
                if (-not $ccRulesByPolicy.ContainsKey($key)) { $ccRulesByPolicy[$key] = New-Object System.Collections.ArrayList }
                [void]$ccRulesByPolicy[$key].Add($ccRule)
            }
        }
        catch { }
    }
    $ccRead = Get-CbxOptionalRead -Cmdlet 'Get-SupervisoryReviewPolicyV2' -Shape { $_ }
    $communicationCompliance = [ordered]@{
        available = $ccRead.available
        items     = @(@($ccRead.items) | Where-Object { $_ } | ForEach-Object {
                $key = "$($_.Guid)"
                [pscustomobject]@{
                    name    = [string]$_.Name
                    detail  = (Get-CbxText $_ 'Comment')
                    scope   = if ($ccWorkloads.ContainsKey($key)) { ($ccWorkloads[$key] -join ', ') } else { $null }
                    enabled = (Get-CbxBool $_ 'Enabled')
                }
            })
        error     = $ccRead.error
    }
    $auditRetention = Get-CbxOptionalRead -Cmdlet 'Get-UnifiedAuditLogRetentionPolicy' -Shape {
        [pscustomobject]@{
            name    = [string]$_.Name
            detail  = (Get-CbxText $_ 'RetentionDuration')
            scope   = ((@($_.RecordTypes) | ForEach-Object { "$_" } | Where-Object { $_ }) -join ', ')
            enabled = $null
        }
    }

    # ---- Purview policy detail (CBX-POLICY-DETAIL-BEGIN) -------------------------------------
    # One try per solution, so a shape Purview changes breaks that solution's detail only.
    $purviewPolicies = [ordered]@{
        irm  = [ordered]@{ available = $irmRead.available; error = $irmRead.error; policies = @() }
        cc   = [ordered]@{ available = $ccRead.available; error = $ccRead.error; policies = @() }
        dspm = [ordered]@{ available = $true; error = $aiCollection.error; policies = @() }
        ib   = [ordered]@{ available = $true; error = $informationBarriers.error; policies = @(); segments = @() }
    }

    try {
        $purviewPolicies.irm.policies = @($irmRaw | ForEach-Object {
                $p = $_
                $facets = New-Object System.Collections.ArrayList

                $scope = @(@($p.ExchangeLocation) | ForEach-Object { "$_" } | Where-Object { $_ })
                if ($scope.Count -eq 1 -and $scope[0] -eq 'All') { Add-CbxFacet $facets 'users' @('All') }
                elseif ($scope.Count -gt 0) { Add-CbxFacet $facets 'usersCount' @("$($scope.Count)") }
                $except = @(@($p.ExchangeLocationException) | ForEach-Object { "$_" } | Where-Object { $_ })
                if ($except.Count -gt 0) { Add-CbxFacet $facets 'excludedCount' @("$($except.Count)") }

                Add-CbxFacet $facets 'sites' (Get-CbxJsonNames $p.SharepointSites)
                $labelNames = New-Object System.Collections.ArrayList
                foreach ($raw in @($p.SensitivityLabels)) {
                    foreach ($l in @(ConvertFrom-CbxJson $raw)) {
                        if ($null -eq $l) { continue }
                        $g = "$($l.Guid)"
                        $n = if ($g -and $script:CbxLabelNames.ContainsKey($g)) { $script:CbxLabelNames[$g] } else { Resolve-CbxName "$($l.Name)" }
                        if ($n -and -not $labelNames.Contains($n)) { [void]$labelNames.Add($n) }
                    }
                }
                Add-CbxFacet $facets 'labels' @($labelNames.ToArray())
                Add-CbxFacet $facets 'sensitiveTypes' (Get-CbxJsonNames $p.DlpSensitiveTypes)
                $priorityOnly = Get-CbxBool $p 'IsPriorityContentOnlyScoring'
                if ($null -ne $priorityOnly) { Add-CbxFacet $facets 'priorityOnly' @($(if ($priorityOnly) { 'Yes' } else { 'No' })) }

                Add-CbxFacet $facets 'triggers' @($p.Triggers)
                Add-CbxFacet $facets 'dlpTriggers' (Get-CbxJsonNames $p.DlpPoliciesAsTrigger)
                Add-CbxFacet $facets 'ccTrigger' @((Get-CbxText $p 'CCPolicyName'))
                foreach ($raw in @($p.TriggerInsightGroups)) {
                    foreach ($grp in @(ConvertFrom-CbxJson $raw)) {
                        if ($null -eq $grp -or -not "$($grp.Name)") { continue }
                        $on = @(@($grp.Insights) | Where-Object { $_ -and $_.Enabled -eq $true } | ForEach-Object { "$($_.Name)" })
                        Add-CbxFacet $facets 'triggerThresholds' $on "$($grp.Name)"
                    }
                }

                $scored = New-Object System.Collections.ArrayList
                foreach ($raw in (@($p.Indicators) + @($p.ExtensibleIndicators))) {
                    foreach ($grp in @(ConvertFrom-CbxJson $raw)) {
                        if ($grp -and $grp.UseInScoring -eq $true -and "$($grp.Name)" -and -not $scored.Contains("$($grp.Name)")) { [void]$scored.Add("$($grp.Name)") }
                    }
                }
                Add-CbxFacet $facets 'scoredIndicators' @($scored.ToArray())
                Add-CbxFacet $facets 'activationDays' @((Get-CbxText $p 'InScopeTimeSpan'))
                Add-CbxFacet $facets 'historyDays' @((Get-CbxText $p 'HistoricTimeSpan'))

                $health = $null
                $h = ConvertFrom-CbxJson $p.PolicyHealth
                if ($h -and "$($h.HealthStatus)") {
                    $notes = @(@($h.ValidationDetails) | Where-Object { $_ } | ForEach-Object {
                            $detail = @()
                            if ($_.Details) { $detail = @($_.Details.PSObject.Properties.Name) }
                            if ($detail.Count -gt 0) { "$($_.Status) ($($detail -join ', '))" } else { "$($_.Status)" }
                        })
                    $health = if ($notes.Count -gt 0) { "$($h.HealthStatus): $($notes -join '; ')" } else { "$($h.HealthStatus)" }
                }

                New-CbxPolicyRecord -Source $p -Mode (Get-CbxText $p 'Mode') -Enabled (Get-CbxBool $p 'Enabled') `
                    -AiRelated ((Get-CbxText $p 'PolicyCategory') -eq 'ApplicableToAI') `
                    -Template (Get-CbxText $p 'InsiderRiskScenario') -Health $health -Facets $facets
            })
    }
    catch { $purviewPolicies.irm.error = "Detail could not be read: $($_.Exception.Message)" }

    try {
        $purviewPolicies.cc.policies = @(@($ccRead.items) | Where-Object { $_ } | ForEach-Object {
                $p = $_
                $facets = New-Object System.Collections.ArrayList
                $rules = @()
                if ($ccRulesByPolicy.ContainsKey("$($p.Guid)")) { $rules = @($ccRulesByPolicy["$($p.Guid)"].ToArray()) }
                $locations = New-Object System.Collections.ArrayList
                $genAi = $false

                foreach ($rule in $rules) {
                    $group = if ($rules.Count -gt 1) { "$($rule.Name)" } else { '' }
                    $all = $false
                    $named = New-Object System.Collections.ArrayList
                    foreach ($src in @(ConvertFrom-CbxJson $rule.ContentSources)) {
                        if ($null -eq $src) { continue }
                        $who = "$($src.RevieweeName)"
                        if ($who -eq 'AllUsersGroupsOfTenant') { $all = $true }
                        elseif ($who -and -not $named.Contains($who)) { [void]$named.Add($who) }
                        if (@(@($src.UnifiedGenAIWorkloads) | Where-Object { $_ }).Count -gt 0) { $genAi = $true }
                        foreach ($w in (@($src.Workloads) + @($src.ThirdPartyWorkloads) + @($src.UnifiedGenAIWorkloads))) {
                            if ($null -eq $w) { continue }
                            $wName = if ($w -is [string]) { $w } else { Get-CbxFirstProp $w @('Name', 'DisplayName') }
                            if ($wName -and -not $locations.Contains($wName)) { [void]$locations.Add($wName) }
                        }
                    }
                    if ($all) { Add-CbxFacet $facets 'users' @('All') $group }
                    elseif ($named.Count -gt 0) { Add-CbxFacet $facets 'usersCount' @("$($named.Count)") $group }

                    $directions = @([regex]::Matches("$($rule.Condition)", 'Direction:(\w+)') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
                    Add-CbxFacet $facets 'direction' $directions $group

                    $classifiers = New-Object System.Collections.ArrayList
                    $conditions = New-Object System.Collections.ArrayList
                    $model = ConvertFrom-CbxJson $rule.ContentMatchesDataModel
                    if ($model) {
                        foreach ($m in @($model.DataModels)) {
                            if ($m -and "$($m.Name)" -and -not $classifiers.Contains("$($m.Name)")) { [void]$classifiers.Add("$($m.Name)") }
                        }
                    }
                    $advanced = ConvertFrom-CbxJson $rule.AdvancedRule
                    if ($advanced) { Add-CbxCcCondition -Node $advanced.condition -Classifiers $classifiers -Conditions $conditions }
                    Add-CbxFacet $facets 'classifiers' @($classifiers.ToArray()) $group
                    Add-CbxFacet $facets 'conditions' @($conditions.ToArray()) $group
                    Add-CbxFacet $facets 'reviewPercent' @((Get-CbxText $rule 'SamplingRate')) $group
                    $ocr = Get-CbxBool $rule 'Ocr'
                    if ($null -ne $ocr) { Add-CbxFacet $facets 'ocr' @($(if ($ocr) { 'Yes' } else { 'No' })) $group }
                }
                Add-CbxFacet $facets 'locations' @($locations.ToArray())
                if ($rules.Count -eq 0) { Add-CbxFacet $facets 'noRule' @('Yes') }

                # Communication Compliance carries no AI category; an AI location is the equivalent mark.
                $ai = $genAi -or @($locations | Where-Object { $_ -in @('Copilot', 'ConnectedAIApp', 'CloudAIApp') }).Count -gt 0
                New-CbxPolicyRecord -Source $p -Mode (Get-CbxText $p 'Mode') -Enabled (Get-CbxBool $p 'Enabled') `
                    -AiRelated $ai -Template $null -Health $null -Facets $facets
            })
    }
    catch { $purviewPolicies.cc.error = "Detail could not be read: $($_.Exception.Message)" }

    try {
        $purviewPolicies.dspm.policies = @($aiRaw | ForEach-Object {
                $p = $_
                $facets = New-Object System.Collections.ArrayList
                $config = ConvertFrom-CbxJson $p.ScenarioConfig
                if ($config) {
                    Add-CbxFacet $facets 'planes' @($config.EnforcementPlanes)
                    Add-CbxFacet $facets 'activities' @($config.Activities)
                    Add-CbxFacet $facets 'sensitiveTypes' (Resolve-CbxSits $config.SensitiveTypeIds)
                    Add-CbxFacet $facets 'excludedSensitiveTypes' (Resolve-CbxSits $config.ExcludedSensitiveTypeIds)
                    Add-CbxFacet $facets 'labels' @(@($config.SensitivityLabelIds) | Where-Object { $_ } | ForEach-Object { Resolve-CbxName "$_" })
                    Add-CbxFacet $facets 'fileExtensions' @($config.FileExtensions)
                    $size = @()
                    if ($config.MinFileSizeInBytes) { $size += "min $($config.MinFileSizeInBytes) bytes" }
                    if ($config.MaxFileSizeInBytes) { $size += "max $($config.MaxFileSizeInBytes) bytes" }
                    Add-CbxFacet $facets 'fileSize' $size
                    if ($null -ne $config.IsIngestionEnabled) { Add-CbxFacet $facets 'capture' @($(if ($config.IsIngestionEnabled) { 'Yes' } else { 'No' })) }
                }
                $included = New-Object System.Collections.ArrayList
                $excluded = New-Object System.Collections.ArrayList
                foreach ($loc in @(ConvertFrom-CbxJson $p.Locations)) {
                    if ($null -eq $loc) { continue }
                    foreach ($i in @($loc.Inclusions)) {
                        $n = if ($i) { Get-CbxFirstProp $i @('DisplayName', 'Name', 'Identity') } else { $null }
                        if ($n -and -not $included.Contains($n)) { [void]$included.Add($n) }
                    }
                    foreach ($x in @($loc.Exclusions)) {
                        $n = if ($x) { Get-CbxFirstProp $x @('DisplayName', 'Name', 'Identity') } else { $null }
                        if ($n -and -not $excluded.Contains($n)) { [void]$excluded.Add($n) }
                    }
                }
                Add-CbxFacet $facets 'users' @($included.ToArray())
                Add-CbxFacet $facets 'excludedUsers' @($excluded.ToArray())

                New-CbxPolicyRecord -Source $p -Mode (Get-CbxText $p 'Mode') -Enabled (Get-CbxBool $p 'Enabled') `
                    -AiRelated ((Get-CbxText $p 'PolicyCategory') -eq 'ApplicableToAI') -Template $null -Health $null -Facets $facets
            })
    }
    catch { $purviewPolicies.dspm.error = "Detail could not be read: $($_.Exception.Message)" }

    try {
        $purviewPolicies.ib.segments = @($ibSegmentsRaw | ForEach-Object {
                [pscustomobject]@{ name = (Get-CbxText $_ 'Name'); filter = (Get-CbxText $_ 'UserGroupFilter') }
            })
        $purviewPolicies.ib.policies = @($ibPoliciesRaw | ForEach-Object {
                $p = $_
                $facets = New-Object System.Collections.ArrayList
                Add-CbxFacet $facets 'assignedSegment' @($p.AssignedSegment)
                Add-CbxFacet $facets 'segmentsAllowed' @($p.SegmentsAllowed)
                Add-CbxFacet $facets 'segmentsBlocked' @($p.SegmentsBlocked)
                Add-CbxFacet $facets 'allowedFilter' @($p.SegmentAllowedFilter)
                New-CbxPolicyRecord -Source $p -Mode (Get-CbxText $p 'State') -Enabled $null -AiRelated $null `
                    -Template $null -Health $null -Facets $facets
            })
    }
    catch { $purviewPolicies.ib.error = "Detail could not be read: $($_.Exception.Message)" }
    # ---- (CBX-POLICY-DETAIL-END) --------------------------------------------------------------

    # ---- Tenant posture: Exchange Online ---------------------------------------------------
    # The Security & Compliance copy of Get-AdminAuditLogConfig always reports ingestion as False,
    # so unified audit is read from Exchange Online itself.
    $exchange = [ordered]@{
        connected             = $false
        error                 = $null
        unifiedAuditIngestion = $null
        adminAuditLog         = $null
        appsForOffice         = $null
        defaultPolicy         = $null
        userAddInRoles        = @()
        groupsRead            = $null
        groupsWithoutOwner    = @()
        groupsError           = $null
        copilotUsage          = $null
        copilotUsageError     = $null
        mailProtection        = $null
    }
    try {
        Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
        Connect-ExchangeOnline `
            -Certificate $certificate `
            -AppId $AppId `
            -Organization $Organization `
            -ShowBanner:$false `
            -ErrorAction Stop | Out-Null
        $exchange.connected = $true

        $auditConfig = Get-AdminAuditLogConfig -ErrorAction Stop
        $exchange.unifiedAuditIngestion = Get-CbxBool $auditConfig 'UnifiedAuditLogIngestionEnabled'
        $exchange.adminAuditLog = Get-CbxBool $auditConfig 'AdminAuditLogEnabled'

        $exchange.appsForOffice = Get-CbxBool (Get-OrganizationConfig -ErrorAction Stop) 'AppsForOfficeEnabled'

        $defaultPolicy = @(Get-RoleAssignmentPolicy -ErrorAction Stop | Where-Object { $_.IsDefault -eq $true }) |
            Select-Object -First 1
        if ($defaultPolicy) {
            $exchange.defaultPolicy = [string]$defaultPolicy.Name
            # My Marketplace Apps, My Custom Apps, My ReadWriteMailbox Apps.
            $exchange.userAddInRoles = @($defaultPolicy.AssignedRoles | ForEach-Object { "$_" } | Where-Object { $_ -match 'Apps$' })
        }

        # Group-connected sites carry no owner in SharePoint; the group's owners are the site's.
        try {
            $groups = @(Get-UnifiedGroup -ResultSize Unlimited -ErrorAction Stop)
            $exchange.groupsRead = $groups.Count
            $exchange.groupsWithoutOwner = @($groups | Where-Object { @($_.ManagedBy | Where-Object { $_ }).Count -eq 0 } |
                    ForEach-Object { "$($_.ExternalDirectoryObjectId)" })
        }
        catch { $exchange.groupsError = $_.Exception.Message }

        # ---- Defender for Office 365 and Exchange Online Protection -------------------------
        # Prompt injection protection needs no switch: Defender for Office 365 Plan 2 classifies
        # injection content during mail flow and files it under High confidence phishing. So the
        # setting that decides the outcome is that verdict's action, which every tenant has through
        # Exchange Online Protection. Safe Links is the Defender-only half, and its cmdlets simply
        # do not exist without the licence - which is how an unlicensed tenant is told apart from a
        # failed read, rather than being scored as though the control were absent by choice.
        $mail = [ordered]@{
            licensed       = $null
            error          = $null
            spamPolicies   = @()
            spamError      = $null
            safeLinks      = @()
            safeLinksError = $null
        }
        try {
            $mail.spamPolicies = @(Get-HostedContentFilterPolicy -ErrorAction Stop | ForEach-Object {
                    [ordered]@{
                        name                     = [string]$_.Name
                        isDefault                = Get-CbxBool $_ 'IsDefault'
                        highConfidencePhishAction = "$($_.HighConfidencePhishAction)"
                    }
                })
        }
        catch { $mail.spamError = $_.Exception.Message }

        if (-not (Get-Command Get-SafeLinksPolicy -ErrorAction SilentlyContinue)) {
            $mail.licensed = $false
            $mail.safeLinksError = 'cmdlet_absent'
        }
        else {
            try {
                # A policy only applies through an enabled rule, so the rules decide the real scope.
                $safeLinksRules = @(Get-SafeLinksRule -ErrorAction Stop)
                $mail.safeLinks = @(Get-SafeLinksPolicy -ErrorAction Stop | ForEach-Object {
                        $policyName = [string]$_.Name
                        $rules = @($safeLinksRules | Where-Object { "$($_.SafeLinksPolicy)" -eq $policyName })
                        $enabled = @($rules | Where-Object { "$($_.State)" -eq 'Enabled' })
                        # No recipient condition at all means the rule covers everyone.
                        $whole = @($enabled | Where-Object {
                                @($_.SentTo).Count -eq 0 -and @($_.SentToMemberOf).Count -eq 0 -and @($_.RecipientDomainIs).Count -eq 0
                            }).Count -gt 0
                        [ordered]@{
                            name        = $policyName
                            email       = Get-CbxBool $_ 'EnableSafeLinksForEmail'
                            teams       = Get-CbxBool $_ 'EnableSafeLinksForTeams'
                            office      = Get-CbxBool $_ 'EnableSafeLinksForOffice'
                            scanUrls    = Get-CbxBool $_ 'ScanUrls'
                            trackClicks = Get-CbxBool $_ 'TrackClicks'
                            ruleEnabled = $enabled.Count -gt 0
                            wholeTenant = $whole
                        }
                    })
                $mail.licensed = $true
            }
            catch {
                $message = $_.Exception.Message
                # Defender refuses the cmdlet outright when the tenant holds no plan for it.
                if ($message -match 'not licensed|no licen[cs]e|subscription') { $mail.licensed = $false }
                $mail.safeLinksError = $message
            }
        }
        $exchange.mailProtection = $mail

        # Evidence of what Copilot actually did, which no setting can show: where it ran and which
        # model providers processed prompts. Auto-routed requests do not always name a model.
        try {
            $auditEnd = (Get-Date).ToUniversalTime()
            $auditStart = $auditEnd.AddDays(-30)
            $auditSession = [guid]::NewGuid().ToString()
            $auditUsers = @{}
            $auditHosts = @{}
            $providerRecords = @{}
            $providerUsers = @{}
            $auditRecords = 0
            $auditPages = 0
            do {
                $batch = @(Search-UnifiedAuditLog -StartDate $auditStart -EndDate $auditEnd -RecordType CopilotInteraction `
                        -SessionId $auditSession -SessionCommand ReturnLargeSet -ResultSize 5000 -ErrorAction Stop)
                $auditPages++
                foreach ($rec in $batch) {
                    $auditRecords++
                    $user = "$($rec.UserIds)"
                    $auditUsers[$user] = $true
                    try { $copilotEvent = ("$($rec.AuditData)" | ConvertFrom-Json -ErrorAction Stop).CopilotEventData } catch { continue }
                    $appHost = "$($copilotEvent.AppHost)"
                    if ($appHost) { $auditHosts[$appHost] = 1 + [int]$auditHosts[$appHost] }
                    foreach ($model in @($copilotEvent.ModelTransparencyDetails)) {
                        $provider = "$($model.ModelProviderName)"
                        if (-not $provider) { continue }
                        $providerRecords[$provider] = 1 + [int]$providerRecords[$provider]
                        if (-not $providerUsers.ContainsKey($provider)) { $providerUsers[$provider] = @{} }
                        $providerUsers[$provider][$user] = $true
                    }
                }
            } while ($batch.Count -gt 0 -and $auditPages -lt 10)

            $exchange.copilotUsage = [pscustomobject]@{
                days      = 30
                records   = $auditRecords
                truncated = ($auditPages -ge 10 -and $batch.Count -gt 0)
                users     = $auditUsers.Count
                hosts     = @($auditHosts.GetEnumerator() | Sort-Object Value -Descending |
                        ForEach-Object { [pscustomobject]@{ name = [string]$_.Key; count = [int]$_.Value } })
                providers = @($providerRecords.GetEnumerator() | Sort-Object Value -Descending |
                        ForEach-Object { [pscustomobject]@{ name = [string]$_.Key; count = [int]$_.Value; users = $providerUsers[$_.Key].Count } })
            }
        }
        catch { $exchange.copilotUsageError = $_.Exception.Message }
    }
    catch { $exchange.error = $_.Exception.Message }

    # ---- Tenant posture: SharePoint Online (optional) --------------------------------------
    $sharePoint = [ordered]@{ connected = $false; error = $null; tenant = $null; sites = $null; appInsights = $null; agentInsights = $null; dag = $null }
    $adminUrl = $SharePointAdminUrl
    if (-not $adminUrl -and $Organization -match '^([^.]+)\.onmicrosoft\.com$') {
        $adminUrl = 'https://{0}-admin.sharepoint.com' -f $Matches[1].ToLowerInvariant()
    }
    if (-not $TenantId -or -not $adminUrl) {
        $sharePoint.error = 'not_configured: the tenant id or SharePoint admin URL was not supplied.'
    }
    elseif (-not (Get-Module -ListAvailable -Name Microsoft.Online.SharePoint.PowerShell)) {
        $sharePoint.error = 'module_missing: Microsoft.Online.SharePoint.PowerShell is not imported into the Automation account.'
    }
    else {
        try {
            Import-Module Microsoft.Online.SharePoint.PowerShell -DisableNameChecking -ErrorAction Stop
            Connect-SPOService -Url $adminUrl -ClientId $AppId -TenantId $TenantId -Certificate $certificate -ErrorAction Stop
            $sharePoint.connected = $true

            $spoTenant = Get-SPOTenant -ErrorAction Stop
            $sharePoint.tenant = [pscustomobject]@{
                sharingCapability         = (Get-CbxText $spoTenant 'SharingCapability')
                oneDriveSharingCapability = (Get-CbxText $spoTenant 'OneDriveSharingCapability')
                defaultSharingLinkType    = (Get-CbxText $spoTenant 'DefaultSharingLinkType')
                anonymousLinkExpiryDays   = (Get-CbxInt $spoTenant 'RequireAnonymousLinksExpireInDays')
                conditionalAccessPolicy   = (Get-CbxText $spoTenant 'ConditionalAccessPolicy')
                storeAccessDisabled       = (Get-CbxBool $spoTenant 'DisableSharePointStoreAccess')
                addInsDisabled            = (Get-CbxBool $spoTenant 'IsSharePointAddInsDisabled')
                customAppAuthDisabled     = (Get-CbxBool $spoTenant 'DisableCustomAppAuthentication')
                restrictedAccessControl   = (Get-CbxBool $spoTenant 'EnableRestrictedAccessControl')
                knowledgeAgentScope       = (Get-CbxText $spoTenant 'KnowledgeAgentScope')
            }

            # Both restrictions are per site and are present on the list output, so one call covers
            # every site. OneDrive personal sites are not listed without -IncludePersonalSite.
            $allSites = @(Get-SPOSite -Limit All -ErrorAction Stop)
            $rcd = @($allSites | Where-Object { $_.RestrictContentOrgWideSearch -eq $true } | ForEach-Object { [string]$_.Url })
            $rsa = @($allSites | Where-Object { $_.RestrictedAccessControl -eq $true } | ForEach-Object { [string]$_.Url })

            # Ownership: a group-connected site is owned through its group, anything else through the
            # site Owner. Infrastructure sites (search, app catalogue, my-site host) have no owner by design.
            $systemTemplates = @('SRCHCEN#0', 'SPSMSITEHOST#0', 'APPCATALOG#0', 'REDIRECTSITE#0', 'EDISC#0', 'POINTPUBLISHINGHUB#0', 'POINTPUBLISHINGTOPIC#0', 'TENANTADMIN#0')
            $contentSites = @($allSites | Where-Object { $systemTemplates -notcontains "$($_.Template)".ToUpperInvariant() -and "$($_.Url)" -notmatch '-admin\.sharepoint\.com' })
            $ownerless = $null
            if ($null -ne $exchange.groupsRead) {
                $noOwnerGroups = @{}
                foreach ($g in $exchange.groupsWithoutOwner) { $noOwnerGroups["$g".ToLowerInvariant()] = $true }
                $ownerless = @($contentSites | Where-Object {
                        $groupId = "$($_.GroupId)"
                        # The tenant root site is created without a named owner; SharePoint admins hold it.
                        if (([uri]"$($_.Url)").AbsolutePath -eq '/') { $false }
                        elseif ($groupId -and $groupId -ne '00000000-0000-0000-0000-000000000000') { $noOwnerGroups.ContainsKey($groupId.ToLowerInvariant()) }
                        else { -not "$($_.Owner)" }
                    } | ForEach-Object { [string]$_.Url })
            }

            # Assigned outside the hashtable: an if-expression would unroll a one-element array to a string.
            $ownerlessList = if ($null -ne $ownerless) { $ownerless | Select-Object -First 25 } else { $null }
            $sharePoint.sites = [pscustomobject]@{
                total          = $allSites.Count
                rcdCount       = $rcd.Count
                rsaCount       = $rsa.Count
                rcd            = @($rcd | Select-Object -First 25)
                rsa            = @($rsa | Select-Object -First 25)
                contentSites   = $contentSites.Count
                ownerlessCount = if ($null -ne $ownerless) { $ownerless.Count } else { $null }
                ownerless      = @($ownerlessList)
            }

            # SharePoint Advanced Management reports. Generating one needs its activity-insights data
            # collection running, which the collector starts once if it is off: that records nothing
            # new about users' access, changes no setting, and Microsoft stops it after three months
            # without a report. The first report is available about a day later.
            $sharePoint.appInsights = Get-CbxInsightReport -Entity 'AppInsights' -Kind 'EnterpriseApp'
            $sharePoint.agentInsights = Get-CbxInsightReport -Entity 'CopilotAppInsights' -Kind 'CopilotAgent'
            $sharePoint.dag = Get-CbxDagReports
        }
        catch { $sharePoint.error = $_.Exception.Message }
        finally {
            try { Disconnect-SPOService -ErrorAction SilentlyContinue } catch { }
        }
    }

    Write-Result @{
        status            = 'ok'
        total             = $policies.Count
        policies          = $policies
        labels            = $labels
        labelPolicies     = $labelPolicies
        labelError        = $labelError
        autoLabelPolicies = $autoLabelPolicies
        autoLabelError    = $autoLabelError
        retentionLabels   = $retentionLabels
        retentionPolicies = $retentionPolicies
        retentionError    = $retentionError
        violations        = $violations
        violationError    = $violationError
        purviewPolicies   = $purviewPolicies
        posture           = [ordered]@{
            informationBarriers     = $informationBarriers
            labelDefaults           = $labelDefaults
            labelDefaultsError      = $labelError
            aiCollection            = $aiCollection
            insiderRisk             = $insiderRisk
            communicationCompliance = $communicationCompliance
            auditRetention          = $auditRetention
            exchange                = $exchange
            sharePoint              = $sharePoint
            teams                   = $teams
            retention               = [ordered]@{ policies = @($retentionPosture.ToArray()); error = $retentionError }
        }
    }
}
catch {
    Write-Result @{
        status    = 'failed'
        message   = $_.Exception.Message
        failedAt  = $_.InvocationInfo.Line.Trim()
        stack     = $_.ScriptStackTrace
        psVersion = $PSVersionTable.PSVersion.ToString()
        policies  = @()
    }
    throw
}
finally {
    try { Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue | Out-Null } catch { }
}
