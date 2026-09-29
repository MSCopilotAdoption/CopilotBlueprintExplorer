# Copilot Blueprint Explorer: deployment kit

Copilot Blueprint Explorer (CBX) is a web console that assesses a Microsoft 365 tenant's readiness and security posture for Microsoft 365 Copilot and agents. It runs in your own Azure subscription, reads your tenant with identities you control, and stores its results in the web app's own storage. It holds no secret, and your data goes to no third party.

Deployment takes **three stages**. Stage 1 is one button and one Cloud Shell block; Stage 2 is one Cloud Shell block; Stage 3 happens inside the console itself.

| Stage | Who | What | Where |
|---|---|---|---|
| **1** | Global Administrator, or an administrator with the minimum roles below | **One click** creates every Azure resource, then **one Cloud Shell block** creates the access group, both app registrations, the redirect URI, the federated credential and the collector certificate, and writes the settings that join them up | Azure portal and its Cloud Shell |
| **2** | Deployer (Contributor on the resource group) | **One Cloud Shell block** fetches the release from the repository, checks it against its own checksum and deploys it | Azure portal's Cloud Shell |
| **3** | Global Administrator | Signs in, grants the two basic permissions, tests with **No scan**, then grants the rest for a full scan | The console itself |

---

## What is in this folder

| Path | Purpose |
|---|---|
| `azuredeploy.json` | The one-click ARM template (compiled from `main.bicep`). Used by the **Deploy to Azure** button. |
| `main.bicep` | The template's readable source. |
| `runbooks/Get-CbxDlpPolicies.ps1` | Automation runbook: reads Purview, Exchange Online, Teams and (optionally) SharePoint settings that no Graph API exposes. |
| `runbooks/Get-CbxPowerPlatform.ps1` | Automation runbook: reads Power Platform environments, connector DLP policies and Copilot Studio agents. |
| **Handed over separately** `release/cbx-app.zip` | The application, ready to deploy. Not in the public repository: Stage 2 fetches it from the private release folder with a read-only token, or your Microsoft contact gives it to you directly. |
| **Handed over separately** `release/cbx-app.zip.sha256` | Its SHA-256 checksum. Stage 2 checks the zip against it automatically and refuses to deploy a file that does not match. |

### What gets created in Azure

| Resource | Purpose |
|---|---|
| App Service plan (Linux, B1) | Hosts the web app. |
| Web app (.NET 8, Linux) | The console and its API. HTTPS only, TLS 1.2, FTP disabled, Always On, health check on `/api/health`. |
| Web app **system-assigned** managed identity | Every app-only read of Microsoft Graph and Azure. Starts and reads the collection runbooks. |
| **User-assigned** managed identity | Nothing but the federated credential that lets the API act for the signed-in person without a client secret. |
| Automation account (Basic) | Always created. Runs the two collection runbooks. Holds the Purview collector's certificate. Its own identity reads Power Platform. The template imports two PowerShell modules into it; the third (MicrosoftTeams) is imported by the Stage 1.2 block, which does not wait for it. |

Two Azure role assignments are made, and nothing wider: the web app's identity gets **Automation Job Operator** and **Reader** on the Automation account. If a deployer is named, they get **Contributor** on the resource group.

---

## Before you start

### Minimum roles

| Stage | Microsoft Entra | Azure |
|---|---|---|
| 1 | **Cloud Application Administrator** (app registrations, admin consent to delegated permissions, enterprise app assignment, federated credential) **and Groups Administrator** (the security group). Or Global Administrator. | **Owner** of the subscription, or **Contributor + Role Based Access Control Administrator**. You create a resource group and role assignments. |
| 2 | None. | **Contributor** on the resource group, and a **fine-grained GitHub token** with *Contents: Read-only* on the release repository (2.1). |
| 3 | **Global Administrator**. Or split: Privileged Role Administrator (Graph application permissions and Entra roles), Purview **Organization Management** (role groups), **Power Platform Administrator**, and **System Administrator** in each Dataverse environment. | Only if Stage 1 created the resources by hand: Owner or User Access Administrator on the Automation account. |

### Licensing note

Assigning a **group** to an enterprise application requires Microsoft Entra ID P1, which is included in Microsoft 365 E3 and E5. Without it, assign users individually in step 1.2.

### Values you will collect

Keep the **handover sheet** (step 1.3) open as you go. Stage 2 and Stage 3 need every value on it, and the Stage 1.2 block prints all of them.

---

## Stage 1: Administrator

Two steps: one button, then one Cloud Shell block. The button creates every Azure resource; the block creates every Entra object against what the button made, and writes the settings that connect the two.

They run in that order because the Entra objects depend on real values — the web app's address for the redirect URI, the managed identity's principal for the federated credential, the Automation account for the collector certificate. Creating them first means guessing those values; creating them second means reading them.

To use Cloud Shell: open it from the `>_` icon in the Azure portal's top bar and choose **PowerShell**. Edit the parameters at the top of the block, paste the whole block, press Enter. It reuses whatever already exists, so it is safe to run again.

### 1.1 Create the Azure resources

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FMSCopilotAdoption%2FCopilotBlueprintExplorer%2Fmain%2Fazuredeploy.json)

On the form, choose your subscription and then **Resource group → Create new** (for example `rg-copilot-blueprint`) — there is no need to create it beforehand. Then fill in:

| Parameter | Value |
|---|---|
| **Deployer Object Id** | The deployer's Object ID (**Entra → Users →** the person **→ Object ID**). They get Contributor on this resource group only. Leave empty if you run Stage 2 yourself. |
| **Deployer Upn** | The deployer's sign-in name, for example `alex@contoso.com`. Recorded once as the first **named person** and given the Super Admin role, so they can administer the console before the access group exists (see 3.1). **It must be exactly the name they sign in with.** A different alias or domain form seeds a role that matches nobody, and because the role book is then no longer empty it also stops the first person who signs in from claiming Super Admin — leaving the deployment with no administrator at all. If the deployer is a **guest**, either form works: their own address, or the `alex_contoso.com#EXT#@yourtenant.onmicrosoft.com` name Entra stores them under. **Leave it empty if you are deploying for yourself** — the first person to sign in then becomes Super Admin automatically. |
| Name Prefix | `cbx` (default). Lowercase letters and digits, 2–6 characters. |
| Web App Name | Leave empty to generate a unique one, or choose a globally unique name. It becomes `https://<name>.azurewebsites.net`. |
| Web App Sku | `B1` is enough. |
| Runbook Base Url | **Leave empty.** Through the button, the two runbooks are imported automatically from the `runbooks` folder next to the template. |
| Api Client Id, Security Group Object Id, Purview Collector App Id, Purview Organization | **Leave all four empty.** These name Entra objects that do not exist yet. Step 1.2 creates them and writes these same settings. |

**Review + create → Create.** It takes about five to ten minutes, most of it importing two PowerShell modules into the Automation account.

> The button needs the template repository to be **publicly readable**, because the Azure portal fetches the template anonymously. If the button reports that it cannot download the template, download `azuredeploy.json` from this repository, then in the portal search **Deploy a custom template → Build your own template in the editor → Load file**, select it and **Save**. The form that follows is the same, but the runbooks are then not imported automatically — step 1.2 imports them instead.

When it finishes, open **Outputs** and keep them to hand.

<details>
<summary><strong>What this creates, and what it deliberately does not</strong></summary>

| Resource | Purpose |
|---|---|
| App Service plan (Linux, B1) | Hosts the web app. |
| Web app (.NET 8, Linux) | The console and its API. HTTPS only, TLS 1.2, FTP disabled, Always On, health check on `/api/health`. |
| Web app **system-assigned** managed identity | Every app-only read of Microsoft Graph and Azure. Starts and reads the collection runbooks. |
| **User-assigned** managed identity | Nothing but the federated credential that lets the API act for the signed-in person without a client secret. |
| **Automation account (Basic)** | Always created. Runs the two collection runbooks, holds the collector's certificate, and its own identity reads Power Platform. Without it the Purview, Exchange, Teams, SharePoint and Power Platform readings have nowhere to run, and the controls behind them stay manual — which is most of what makes the assessment worth running. |

Two Azure role assignments, and nothing wider: the web app's identity gets **Automation Job Operator** and **Reader** on the Automation account. If a deployer is named, they get **Contributor** on the resource group.

**No permission to your tenant is granted here, or in 1.2.** Everything the console ever reads is granted later, from inside the console, by a Global Administrator who can see what each permission is for (Stage 3.2). Until then the app registration is an empty shell — which is why the deployment can be reviewed before it is trusted.

</details>

<details>
<summary><strong>Create the resources by hand instead</strong> (expand)</summary>

1. **Resource group:** **Azure portal → Resource groups → Create.**
2. **User-assigned managed identity:** **Create a resource → User Assigned Managed Identity →** your resource group, name for example `cbx-uami` **→ Create.**
3. **Web app:** **Create a resource → Web App.** Publish **Code**, Runtime stack **.NET 8 (LTS)**, Operating system **Linux**, your region. Pricing plan: a new Linux plan, **Basic B1**.
4. **Web app identity:** open the web app → **Identity → System assigned → On → Save**, then **User assigned → Add →** the identity from 2.
5. **General settings:** Stack **.NET 8**, Startup command **empty**, **Always on: On**, HTTP version **2.0**, **FTP state: Disabled**, **HTTPS Only: On**, **Minimum inbound TLS version: 1.2**. **Monitoring → Health check → Enable**, path `/api/health`.
6. **Automation account:** **Create a resource → Automation →** your resource group, name for example `cbx-aa` **→** leave the system-assigned identity **on → Create.** This is not optional; see the table above.
7. **Role assignments** (you need Owner or User Access Administrator): Automation account → **Access control (IAM) → Add role assignment → Automation Job Operator →** Managed identity → App Service → the web app. Repeat for **Reader**. *(Or grant both later from the console, under Settings → Roles & permissions → Managed identity.)*
8. Make the deployer **Contributor** on the resource group.
9. Set the app settings listed in the table at the end of 1.2 — step 1.2 writes the rest.

</details>

### 1.2 Create the Entra objects and finish the configuration

One block. It creates the access group, both app registrations, the redirect URI, the federated credential and the collector certificate, imports what the template left out, and then writes every app setting that depends on them.

Everything it does is listed under the block, with the portal equivalent, so nothing here is a black box.

```powershell
& {
    # --- Parameters. Empty TenantId / SubscriptionId: the ones Cloud Shell is signed in to.
    $TenantId         = ''
    $SubscriptionId   = ''
    $ResourceGroup    = 'rg-copilot-blueprint'   # the one you deployed into in 1.1
    $GroupName        = 'Copilot Blueprint Explorer users'
    $MemberUpns       = @()      # the console's users, e.g. 'sam@contoso.com'; you are added automatically
    $AppName          = 'Copilot Blueprint Explorer'
    $CollectorName    = 'CBX Purview Collector'
    $DeployerUpn      = ''       # optional: also made an owner of the collector app registration
    $RenewCertificate = $false   # $true: replace an existing CbxPurviewCert (yearly renewal)
    $CertificateDays  = 365
    $RunbookBaseUrl   = 'https://raw.githubusercontent.com/MSCopilotAdoption/CopilotBlueprintExplorer/main/runbooks/'

    # --- Commands
    $ErrorActionPreference = 'Stop'; $PSNativeCommandUseErrorActionPreference = $true
    if (-not $TenantId) { $TenantId = az account show --query tenantId -o tsv }
    if ($TenantId -ne (az account show --query tenantId -o tsv)) { az login --tenant $TenantId --use-device-code -o none }
    if (-not $SubscriptionId) { $SubscriptionId = az account show --query id -o tsv }
    az account set --subscription $SubscriptionId
    function Invoke-Rest([string]$Method, [string]$Url, $Body) {
        $file = Join-Path ([IO.Path]::GetTempPath()) "cbx-$([guid]::NewGuid()).json"
        $Body | ConvertTo-Json -Depth 10 | Set-Content -Path $file -Encoding utf8NoBOM
        try { az rest --method $Method --url $Url --headers 'Content-Type=application/json' --body "@$file" -o none } finally { Remove-Item $file }
    }

    # --- 0. What 1.1 created. Everything below is built against these, not against guesses.
    $webAppName = az webapp list --resource-group $ResourceGroup --query "[0].name" -o tsv
    $identityName = az identity list --resource-group $ResourceGroup --query "[0].name" -o tsv
    $aaType = 'Microsoft.Automation/automationAccounts'
    $automationAccount = az resource list --resource-group $ResourceGroup --resource-type $aaType --query "[0].name" -o tsv
    if (-not $webAppName -or -not $identityName -or -not $automationAccount) {
        throw "Could not find the web app, the user-assigned identity and the Automation account in '$ResourceGroup'. Complete 1.1 first."
    }
    $webAppUrl = 'https://' + (az webapp show --resource-group $ResourceGroup --name $webAppName --query defaultHostName -o tsv)
    $uamiPrincipal = az identity show --resource-group $ResourceGroup --name $identityName --query principalId -o tsv
    # Security & Compliance PowerShell accepts only the initial onmicrosoft.com domain. Graph's
    # /domains does not support filtering, so the pick is made here rather than in the query.
    $organization = az rest --method GET --url 'https://graph.microsoft.com/v1.0/organization' --query "value[0].verifiedDomains[?isInitial].name | [0]" -o tsv
    if (-not $organization) { $organization = az rest --method GET --url 'https://graph.microsoft.com/v1.0/domains' --query "value[?isInitial].id | [0]" -o tsv }
    if (-not $organization) { throw 'Could not read the tenant''s initial onmicrosoft.com domain. Set Cbx__PurviewOrganization by hand in the web app''s settings.' }

    # --- 1. Access group. Only its members may use the console (assignment is required, below).
    $groupId = az ad group list --filter "displayName eq '$GroupName'" --query "[0].id" -o tsv
    if (-not $groupId) {
        $groupId = az ad group create --display-name $GroupName --mail-nickname ($GroupName -replace '[^A-Za-z0-9]', '') --query id -o tsv
    }
    foreach ($id in @(az ad signed-in-user show --query id -o tsv) + @($MemberUpns | Where-Object { $_ } | ForEach-Object { az ad user show --id $_ --query id -o tsv })) {
        if ((az ad group member check --group $groupId --member-id $id --query value -o tsv) -ne 'true') { az ad group member add --group $groupId --member-id $id }
    }

    # --- 2. The console's app registration: sign-in for the browser, and the API it calls.
    $app = az ad app list --filter "displayName eq '$AppName'" --query "[0].[appId,id]" -o tsv
    if (-not $app) { $app = az ad app create --display-name $AppName --sign-in-audience AzureADMyOrg --query "[appId,id]" -o tsv }
    $appId, $appObjectId = @($app) -split "`t"

    # api://<client-id>/access_as_user, v2 access tokens, the wids claim (without it the console
    # cannot see who is a Global Administrator), and the browser redirect URI for the real web app.
    $scopeId = az ad app list --filter "appId eq '$appId'" --query "[0].api.oauth2PermissionScopes[?value=='access_as_user'].id" -o tsv
    if (-not $scopeId) { $scopeId = [guid]::NewGuid().Guid }
    $redirects = @(@(az ad app show --id $appId --query spa.redirectUris -o json | ConvertFrom-Json) + $webAppUrl | Where-Object { $_ } | Select-Object -Unique)
    Invoke-Rest PATCH "https://graph.microsoft.com/v1.0/applications/$appObjectId" @{
        identifierUris = @("api://$appId")
        spa            = @{ redirectUris = $redirects }
        api            = @{
            requestedAccessTokenVersion = 2
            oauth2PermissionScopes      = @(@{
                id = $scopeId; value = 'access_as_user'; type = 'User'; isEnabled = $true
                adminConsentDisplayName = 'Access Copilot Blueprint Explorer'
                adminConsentDescription = 'Allows the app to call the Copilot Blueprint Explorer API as the signed-in user.'
                userConsentDisplayName  = 'Access Copilot Blueprint Explorer'
                userConsentDescription  = 'Allows the app to call the API on your behalf.'
            })
        }
        optionalClaims = @{ accessToken = @(@{ name = 'wids'; essential = $false }); idToken = @(); saml2Token = @() }
    }

    # Delegated permissions: User.Read plus this app's own access_as_user, and deliberately nothing
    # else. Everything the console uses is granted later, from inside it, in Stage 3.2.
    $graphAppId  = '00000003-0000-0000-c000-000000000000'
    $delegated   = , 'User.Read'
    $graphScopes = az ad sp show --id $graphAppId --query "oauth2PermissionScopes[].{value:value,id:id}" -o json | ConvertFrom-Json
    $wanted      = @{ $graphAppId = @($delegated | ForEach-Object { $v = $_; ($graphScopes | Where-Object value -eq $v).id }); $appId = @($scopeId) }
    $rra         = @(az ad app list --filter "appId eq '$appId'" --query "[0].requiredResourceAccess" -o json | ConvertFrom-Json | Where-Object { $_ })
    foreach ($resource in $wanted.Keys) {
        $entry = $rra | Where-Object resourceAppId -eq $resource
        if (-not $entry) { $entry = [pscustomobject]@{ resourceAppId = $resource; resourceAccess = @() }; $rra += $entry }
        foreach ($id in $wanted[$resource]) {
            if (@($entry.resourceAccess.id) -notcontains $id) { $entry.resourceAccess += [pscustomobject]@{ id = $id; type = 'Scope' } }
        }
    }
    Invoke-Rest PATCH "https://graph.microsoft.com/v1.0/applications/$appObjectId" @{ requiredResourceAccess = $rra }

    # Federated credential: the user-assigned identity stands in for a client secret, so the
    # deployment holds none. This is why 1.1 runs first - the principal below must be the real one.
    $ficFile = Join-Path ([IO.Path]::GetTempPath()) 'cbx-fic.json'
    @{ name = 'cbx-uami-fic'; issuer = "https://login.microsoftonline.com/$TenantId/v2.0"; subject = $uamiPrincipal; audiences = @('api://AzureADTokenExchange') } |
        ConvertTo-Json | Set-Content -Path $ficFile -Encoding utf8NoBOM
    $ficId = az ad app federated-credential list --id $appId --query "[?name=='cbx-uami-fic'].id" -o tsv
    try {
        if ($ficId) { az ad app federated-credential update --id $appId --federated-credential-id $ficId --parameters "@$ficFile" -o none }
        else { az ad app federated-credential create --id $appId --parameters "@$ficFile" -o none }
    } finally { Remove-Item $ficFile }

    # Enterprise application: assignment required, and the access group assigned. Needs a role that
    # can administer applications, so a refusal is reported and left for the portal rather than
    # stopping the block with everything else already correct.
    $spId = az ad sp list --filter "appId eq '$appId'" --query "[0].id" -o tsv
    if (-not $spId) { $spId = az ad sp create --id $appId --query id -o tsv }
    $assignmentNote = 'assignment required, access group assigned'
    try {
        Invoke-Rest PATCH "https://graph.microsoft.com/v1.0/servicePrincipals/$spId" @{ appRoleAssignmentRequired = $true }
        $assigned = az rest --method GET --url "https://graph.microsoft.com/v1.0/servicePrincipals/$spId/appRoleAssignedTo" --query "value[?principalId=='$groupId'].id" -o tsv
        if (-not $assigned) {
            Invoke-Rest POST "https://graph.microsoft.com/v1.0/servicePrincipals/$spId/appRoleAssignedTo" @{ principalId = $groupId; resourceId = $spId; appRoleId = '00000000-0000-0000-0000-000000000000' }
        }
    } catch {
        $assignmentNote = 'NOT set - do it in the portal: Enterprise applications > ' + $AppName +
            ' > Properties > Assignment required = Yes, then Users and groups > Add user/group > ' + $GroupName
    }

    # Optional: tenant-wide consent for the two user-consentable permissions, which only saves each
    # person a one-off prompt. Many tenants reserve this, so a refusal is expected and not fatal.
    $consentNote = 'granted for everyone, so nobody sees a prompt'
    try {
        $graphSpId = az ad sp show --id $graphAppId --query id -o tsv
        $grants    = @((az rest --method GET --url "https://graph.microsoft.com/v1.0/oauth2PermissionGrants?%24filter=clientId%20eq%20'$spId'" -o json | ConvertFrom-Json).value)
        foreach ($need in @{ resourceId = $graphSpId; scope = $delegated }, @{ resourceId = $spId; scope = @('access_as_user') }) {
            $grant = $grants | Where-Object { $_.resourceId -eq $need.resourceId -and $_.consentType -eq 'AllPrincipals' } | Select-Object -First 1
            if ($grant) {
                $scope = (@($grant.scope -split ' ') + $need.scope | Where-Object { $_ } | Select-Object -Unique) -join ' '
                Invoke-Rest PATCH "https://graph.microsoft.com/v1.0/oauth2PermissionGrants/$($grant.id)" @{ scope = $scope }
            } else {
                Invoke-Rest POST 'https://graph.microsoft.com/v1.0/oauth2PermissionGrants' @{ clientId = $spId; consentType = 'AllPrincipals'; resourceId = $need.resourceId; scope = $need.scope -join ' ' }
            }
        }
    } catch {
        $consentNote = 'not granted, and that is fine - both are user-consentable, so each person approves them once at first sign-in'
    }

    # --- 3. Collector app registration. Security & Compliance PowerShell accepts only
    # certificate-based app-only sign-in, so the collector needs its own identity.
    $collectorAppId = az ad app list --filter "displayName eq '$CollectorName'" --query "[0].appId" -o tsv
    if (-not $collectorAppId) { $collectorAppId = az ad app create --display-name $CollectorName --sign-in-audience AzureADMyOrg --query appId -o tsv }
    $collectorSpId = az ad sp list --filter "appId eq '$collectorAppId'" --query "[0].id" -o tsv
    if (-not $collectorSpId) { $collectorSpId = az ad sp create --id $collectorAppId --query id -o tsv }
    if ($DeployerUpn) {
        $deployerId = az ad user show --id $DeployerUpn --query id -o tsv
        if (-not (az ad app owner list --id $collectorAppId --query "[?id=='$deployerId'].id" -o tsv)) { az ad app owner add --id $collectorAppId --owner-object-id $deployerId }
    }

    # --- 4. The Automation account: the module the template leaves out, the runbooks if they are
    # missing, and the collector certificate.
    $aaId, $aaLocation = @(az resource show --resource-group $ResourceGroup --name $automationAccount --resource-type $aaType --query "[id,location]" -o tsv) -split "`t"
    $aa = "https://management.azure.com$aaId"; $api = '?api-version=2023-11-01'

    # MicrosoftTeams is 22 MB and can take 5-20 minutes. ARM waits for every module it imports, and a
    # slow one held up whole deployments, so the template omits it and it is started here instead -
    # without waiting. Until it finishes the Teams checks stay manual, with the reason shown.
    $teams = try { az rest --method GET --url "$aa/modules/MicrosoftTeams$api" --query "[properties.version,properties.provisioningState]" -o tsv 2>$null } catch { '' }
    $teamsVersion, $teamsState = @($teams) -split "`t"
    if (-not ($teamsVersion -eq '8.0.0' -and $teamsState -eq 'Succeeded') -and $teamsState -notin 'Creating', 'ContentValidated', 'ContentDownloaded', 'ContentStored') {
        Invoke-Rest PUT "$aa/modules/MicrosoftTeams$api" @{ properties = @{ contentLink = @{ uri = 'https://www.powershellgallery.com/api/v2/package/MicrosoftTeams/8.0.0' } } }
    }

    foreach ($name in 'Get-CbxDlpPolicies', 'Get-CbxPowerPlatform') {
        $state = try { az rest --method GET --url "$aa/runbooks/$name$api" --query properties.state -o tsv 2>$null } catch { '' }
        if ($state -eq 'Published') { continue }
        $path = Join-Path ([IO.Path]::GetTempPath()) "$name.ps1"
        Invoke-WebRequest -Uri "$RunbookBaseUrl$name.ps1" -OutFile $path
        try {
            Invoke-Rest PUT "$aa/runbooks/$name$api" @{ location = $aaLocation; properties = @{ runbookType = 'PowerShell'; logProgress = $false; logVerbose = $false } }
            az rest --method PUT --url "$aa/runbooks/$name/draft/content$api" --headers 'Content-Type=text/powershell' --body "@$path" -o none
            az rest --method POST --url "$aa/runbooks/$name/publish$api" -o none
        } finally { Remove-Item $path }
    }

    # Certificate: public key to the collector app registration, private key to the Automation
    # account and nowhere else. Created in a temporary folder that is deleted either way.
    $certNote = 'left as it is - set $RenewCertificate = $true to renew it'
    $existingCert = try { az rest --method GET --url "$aa/certificates/CbxPurviewCert$api" --query name -o tsv 2>$null } catch { '' }
    if (-not $existingCert -or $RenewCertificate) {
        $dir = Join-Path ([IO.Path]::GetTempPath()) "cbx-cert-$([guid]::NewGuid())"
        New-Item -ItemType Directory -Path $dir | Out-Null
        try {
            openssl req -x509 -newkey rsa:2048 -sha256 -days $CertificateDays -nodes -subj '/CN=CbxPurviewCert' -keyout "$dir/cbx.key" -out "$dir/CbxPurviewCert.cer" 2>$null
            # Password-less, with the legacy encryption the Windows-based Automation sandbox can read.
            openssl pkcs12 -export -inkey "$dir/cbx.key" -in "$dir/CbxPurviewCert.cer" -out "$dir/CbxPurviewCert.pfx" -passout pass: -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1
            az ad app credential reset --id $collectorAppId --cert "@$dir/CbxPurviewCert.cer" --append -o none
            $thumbprint = (openssl x509 -in "$dir/CbxPurviewCert.cer" -noout -fingerprint -sha1) -replace '^.*=' -replace ':'
            Invoke-Rest PUT "$aa/certificates/CbxPurviewCert$api" @{ name = 'CbxPurviewCert'; properties = @{
                base64Value = [Convert]::ToBase64String([IO.File]::ReadAllBytes("$dir/CbxPurviewCert.pfx"))
                thumbprint  = $thumbprint; isExportable = $false; description = 'Purview collector sign-in' } }
            $certNote = "created, valid $CertificateDays days"
        } finally { Remove-Item -Path $dir -Recurse -Force }
    }

    # --- 5. The settings that name everything above. Left empty by 1.1 on purpose.
    az webapp config appsettings set --resource-group $ResourceGroup --name $webAppName --settings `
        "Cbx__ApiClientId=$appId" "Cbx__SpaClientId=$appId" "Cbx__SecurityGroupObjectId=$groupId" `
        "Cbx__PurviewCollectorAppId=$collectorAppId" "Cbx__PurviewOrganization=$organization" -o none

    # --- Handover sheet
    ''
    'Copy these into the handover sheet (1.3). None of them is a secret.'
    "  Tenant ID:                          $TenantId"
    "  Subscription ID:                    $SubscriptionId"
    "  Resource group:                     $ResourceGroup"
    "  Web app:                            $webAppName  ($webAppUrl)"
    "  Application (client) ID:            $appId"
    "  Access group Object ID:             $groupId"
    "  User-assigned identity:             $identityName (principal $uamiPrincipal)"
    "  Automation account:                 $automationAccount"
    "  Collector Application (client) ID:  $collectorAppId"
    "  Collector enterprise app Object ID: $collectorSpId"
    "  Tenant organisation:                $organization"
    ''
    "  Enterprise application:  $assignmentNote"
    "  Admin consent:           $consentNote"
    "  Collector certificate:   $certNote"
    "  MicrosoftTeams module:   $(az rest --method GET --url "$aa/modules/MicrosoftTeams$api" --query properties.provisioningState -o tsv) (Succeeded means ready; run the block again later to re-check)"
    foreach ($name in 'Get-CbxDlpPolicies', 'Get-CbxPowerPlatform') {
        "  Runbook {0,-22} {1}" -f $name, (az rest --method GET --url "$aa/runbooks/$name$api" --query properties.state -o tsv)
    }
}
```

<details>
<summary><strong>What the block does, and the portal equivalent of each part</strong></summary>

| The block | In the portal |
|---|---|
| Access group, with you and any named members | **Entra → Groups → New group**, Security, Assigned |
| App registration `Copilot Blueprint Explorer`, single tenant | **App registrations → New registration** |
| `api://<client-id>` and the `access_as_user` scope | **Expose an API → Add → Add a scope** |
| `requestedAccessTokenVersion: 2` and the `wids` optional claim | **Manifest**, or **Token configuration → Add groups claim → Directory roles** |
| `User.Read` and `access_as_user`, and nothing else | **API permissions → Add a permission → My APIs** |
| Redirect URI `https://<web-app>.azurewebsites.net` | **Authentication → Add a platform → Single-page application** |
| Federated credential `cbx-uami-fic` | **Certificates & secrets → Federated credentials → Add → Managed identity** |
| Assignment required, access group assigned | **Enterprise applications → Properties / Users and groups** |
| App registration `CBX Purview Collector` | **App registrations → New registration** |
| MicrosoftTeams 8.0.0, and the runbooks if missing | Automation account → **Modules** / **Runbooks** |
| Certificate `CbxPurviewCert`, public key to the collector app | Automation account → **Certificates**, and the app's **Certificates & secrets** |
| The five app settings | Web app → **Environment variables → App settings** |

The `wids` claim matters more than it looks: it tells the console who is a Global Administrator. Without it nobody can complete first-run setup or recovery.

</details>

<details>
<summary><strong>App settings the deployment ends with</strong></summary>

| Name | Value |
|---|---|
| `SCM_DO_BUILD_DURING_DEPLOYMENT` | `false` (the release zip is already built) |
| `Cbx__TenantId` | Tenant ID |
| `Cbx__ApiClientId` | App registration client ID |
| `Cbx__SpaClientId` | **The same** app registration client ID |
| `Cbx__UserAssignedClientId` | The user-assigned identity's **Client ID** (not its principal ID) |
| `Cbx__SecurityGroupObjectId` | Access group Object ID |
| `Cbx__DeployerUpn` | The deployer's sign-in name. Seeds the first named person on first start. Optional. |
| `Cbx__SubscriptionId` | Subscription ID |
| `Cbx__DeploymentOption` | `AskCbx` (every deployment carries the assistant; it stays switched off until Settings turns it on). `Minimal` additionally hides how-to-fix guidance. |
| `Cbx__AutomationResourceGroup` | Resource group of the Automation account |
| `Cbx__AutomationAccountName` | Automation account name |
| `Cbx__PurviewCollectorAppId` | Collector client ID |
| `Cbx__PurviewOrganization` | `contoso.onmicrosoft.com` |

> **Do not add `AZURE_CLIENT_ID`.** The console deliberately does every app-only read with the web app's **system-assigned** identity. `AZURE_CLIENT_ID` would silently switch it to the user-assigned identity, which holds no permissions.

</details>

### 1.3 Handover sheet

The block prints this. Send it to the deployer; it contains no secrets.

| Item | Value |
|---|---|
| Tenant ID | |
| Subscription ID | |
| Resource group | |
| Web app name / URL | `https://….azurewebsites.net` |
| Application (client) ID | |
| Access group Object ID | |
| User-assigned identity: name / principal | |
| Automation account name | |
| Purview collector: Application (client) ID | |
| Purview collector: enterprise app Object ID | |
| Tenant organisation (`….onmicrosoft.com`) | |

The deployer also needs **read access to the release**, which does not come from this sheet. Your Microsoft contact sends them the release folder's address and a read-only token directly (see 2.1).

---

## Stage 2: Deployer, in the portal

One block. It fetches the release straight from the repository, checks it against its own checksum, and deploys it. Nothing is downloaded to your computer, and nothing is uploaded by hand.

### 2.1 Deploy the application

You need two things, and **both come from your Microsoft contact, not from this page**: the **release folder's address** and a **fine-grained personal access token** that can read it. Neither is published here — the release is private, and the address is given only to the person doing the deployment.

The block prompts for both, so neither ends up in your shell history or in a file.

**If you are creating the token yourself** (on GitHub, under **Settings → Developer settings → Personal access tokens → Fine-grained tokens → Generate new token**):

| Field | Value |
|---|---|
| Resource owner | The account or organisation that owns the release repository |
| Repository access | **Only select repositories** → the one you were told |
| Repository permissions | **Contents: Read-only**. Nothing else. |
| Expiration | The shortest that covers the deployment |

The token is read-only, scoped to one repository, and only ever sent to `api.github.com`. Delete it once the deployment is done; a new one takes a minute to make.

Open **Cloud Shell** (`>_` in the portal's top bar), choose **PowerShell**, and paste:

```powershell
& {
    # --- Parameters
    $ReleaseUrl    = ''        # leave empty to be prompted. Your Microsoft contact gives you this address
    $GitHubToken   = ''        # leave empty to be prompted, so the token stays out of your shell history
    $ResourceGroup = 'rg-copilot-blueprint'
    $WebAppName    = ''        # empty: the only web app in the resource group

    # --- Commands
    $ErrorActionPreference = 'Stop'; $PSNativeCommandUseErrorActionPreference = $true
    if (-not $ReleaseUrl)  { $ReleaseUrl  = Read-Host -Prompt 'Release folder address' }
    if (-not $GitHubToken) { $GitHubToken = Read-Host -Prompt 'GitHub fine-grained token' -MaskInput }

    # Accepts the folder address as shown in the browser, or just owner/repo
    if ($ReleaseUrl -match '^(?:https://github\.com/)?(?<owner>[^/]+)/(?<repo>[^/]+?)(?:\.git)?(?:/tree/(?<ref>[^/]+)(?:/(?<path>.+?))?)?/?$') {
        $owner = $Matches.owner; $repo = $Matches.repo
        $ref   = if ($Matches.ref)  { $Matches.ref }  else { 'main' }
        $path  = if ($Matches.path) { $Matches.path } else { 'release' }
    } else { throw "Could not read '$ReleaseUrl'. Expected something like https://github.com/owner/repo/tree/main/release" }

    $headers = @{ Authorization = "Bearer $GitHubToken"; 'X-GitHub-Api-Version' = '2022-11-28'; 'User-Agent' = 'cbx-deploy'; Accept = 'application/vnd.github.raw' }
    $base    = "https://api.github.com/repos/$owner/$repo/contents/$path"
    $dir     = Join-Path ([IO.Path]::GetTempPath()) "cbx-release-$([guid]::NewGuid())"
    New-Item -ItemType Directory -Path $dir | Out-Null
    try {
        $zip = Join-Path $dir 'cbx-app.zip'
        try {
            # The contents API serves files up to 100 MB through the raw media type
            Invoke-WebRequest -Uri "$base/cbx-app.zip?ref=$ref" -Headers $headers -OutFile $zip
            $expected = ([string](Invoke-RestMethod -Uri "$base/cbx-app.zip.sha256?ref=$ref" -Headers $headers)).Trim().Split(' ')[0]
        } catch {
            throw "Could not read $owner/$repo at '$path' ($ref). Check the address, and that the token is a fine-grained token for this repository with Contents: Read-only, and has not expired. GitHub says: $($_.Exception.Message)"
        }

        # Checked here so nobody has to check it by hand, and refused rather than deployed if it differs
        $actual = (Get-FileHash $zip -Algorithm SHA256).Hash
        if ($actual -ne $expected) { throw "cbx-app.zip does not match its checksum. Do not deploy it. Expected $expected, got $actual." }
        "Release verified:  $([math]::Round((Get-Item $zip).Length / 1MB, 1)) MB, SHA-256 $actual"

        if (-not $WebAppName) { $WebAppName = az webapp list --resource-group $ResourceGroup --query "[0].name" -o tsv }
        if (-not $WebAppName) { throw "No web app in '$ResourceGroup'. Has Stage 1 been done?" }
        # The zip is already built: make sure App Service does not try to build it
        az webapp config appsettings set --resource-group $ResourceGroup --name $WebAppName --settings SCM_DO_BUILD_DURING_DEPLOYMENT=false -o none
        az webapp deploy --resource-group $ResourceGroup --name $WebAppName --src-path $zip --type zip --clean true -o none
    } finally { Remove-Item -Path $dir -Recurse -Force }

    $url = 'https://' + (az webapp show --resource-group $ResourceGroup --name $WebAppName --query defaultHostName -o tsv)
    foreach ($try in 1..12) {
        try { $health = Invoke-RestMethod "$url/api/health" -TimeoutSec 20; break } catch { Start-Sleep -Seconds 10 }
    }
    "Deployed to:       $url"
    "Health:            $(if ($health) { $health.status } else { 'not answering yet: check Monitoring -> Log stream' })"
}
```

It takes about two minutes and ends by printing the app's address and `Health: healthy`.

> **Why not Deployment Center?** *Publish files (new)* runs a build step (Oryx) on the upload, and this zip is already built, so it fails with *"Couldn't detect a version for the platform 'dotnet' in the repo"*. Kudu's *Zip Push Deploy* page does not work for Linux apps either. The block above uses the App Service publish API, which deploys a zip exactly as it is.

<details>
<summary><strong>If you cannot reach GitHub from Cloud Shell</strong></summary>

Ask for `cbx-app.zip` and `cbx-app.zip.sha256` directly, upload both with **Manage files → Upload** in the Cloud Shell toolbar, and replace the download part of the block with:

```powershell
$dir = $HOME
$zip = Join-Path $dir 'cbx-app.zip'
$expected = (Get-Content (Join-Path $dir 'cbx-app.zip.sha256')).Split(' ')[0]
```

then keep the checksum check and everything after it. **Upload the zip exactly as it was given to you** — do not unzip and re-zip it, because some Windows zip tools write backslash paths that Linux App Service cannot extract, and the upload then fails with an unhelpful *400*.

</details>

### 2.2 Check it runs

Open both addresses in a browser:

- `https://<web-app-name>.azurewebsites.net/api/health` should return `{"status":"healthy",…}`
- `https://<web-app-name>.azurewebsites.net/api/config` should show your tenant ID and `api://<api-client-id>/access_as_user`

If `/api/config` shows an empty client ID, step 1.2 has not been run, or was run before this deployment — run it again.

Opening the console itself works once the Global Administrator has signed in first (Stage 3).

Stage 2 is complete. Tell the Global Administrator.

---

## Stage 3: Global Administrator, in the console

### 3.1 First sign-in, and the read-only walkthrough

Open `https://<web-app-name>.azurewebsites.net` and sign in.

**Two kinds of caller can always sign in, whatever state the access group is in:** anyone holding **Global Administrator**, and anyone on the **Named people** list under Settings → Users. The deployment seeds that list with the **deployer**, from the *Deployer Upn* parameter in step 1.1 — so whoever deployed can sign in immediately, before any access group exists.

That seeded entry is an ordinary one. Once the access group is working, open **Settings → Users → Named people**, and change its role or remove it like any other. It is written once, on the first start, and never written again, so removing it is permanent.

At this point the console cannot yet read group membership, so it cannot check the access group, and anyone else sees a message saying so. That is expected until 3.2.

**Nothing has been granted yet, and the console is already worth walking through.** The app registration asked for nothing beyond sign-in, so this is a fair thing to show a security team before they approve anything:

| Where | What you can see with no permissions granted |
|---|---|
| **Overview** | What the console is, and what it will and will not do. |
| **Assessment → Architecture** | The five layers of securing Copilot, and which control sits in which layer. |
| **Work items** | Every check the console can make, with its Microsoft Learn reference — the full scope of the assessment, before a single tenant read. All show as *not measured*. |
| **Settings → Roles & permissions** | Every permission the console will ever ask for, what each is used for, and which are optional. Nothing is granted; the page is the request list. |
| **Help** | The full document, the FAQ, and what the console reads and why. |

Turn on **No scan** in the top bar first if you want a guarantee in the product itself rather than a promise: while it is on, the console reads nothing from your tenant at all. See 3.4.

> **Until 3.3 is done, the access group is not being enforced, and the console says so.** It cannot read group membership yet, so it cannot check the group at all. Rather than refuse everyone — which would leave nobody able to reach the page that fixes it — it admits whoever signs in and shows a banner saying the gate is open. Two things bound that window: Microsoft Entra is still enforcing **Assignment required**, set in step 1.2, so only people assigned to the enterprise application can obtain a token at all; and the application holds no permission on your tenant at this point, so there is nothing for anyone to read. The window closes the moment 3.3 is finished.

### 3.2 Let the console manage permissions (one approval)

This is the only approval that happens outside the console, and it is what makes every later step possible.

Every Grant and Revoke button in this console is carried out by the application **acting as the administrator who presses it** — it can never do more than that person could do in the portal. Three delegated permissions make that work:

| Permission | What it is for |
|---|---|
| `Application.Read.All` | Read what this deployment currently holds, so the page can show it. |
| `AppRoleAssignment.ReadWrite.All` | Grant and revoke application permissions. |
| `DelegatedPermissionGrant.ReadWrite.All` | The same, for delegated permissions. |

They cannot be granted from inside the console, because granting is exactly what they permit — an application with no right to grant cannot grant itself the right to grant. Microsoft Entra's **admin consent endpoint** is the way out: it takes the permissions from the request rather than from the app registration, which is why the registration could be left empty in Stage 1.

1. Sign in as a **Global Administrator**.
2. **Settings → Roles & permissions.** Because nothing is consented yet, the page shows *One approval is needed before anything can be granted*, naming the three permissions above.
3. Select **Grant admin consent in Microsoft Entra**. Microsoft's own consent page opens, listing those three. Select **Accept**.
4. You are returned to the console. If it still says consent is missing, wait a few seconds and select **Check again** — Entra takes a moment to apply it.

> Prefer to do it in the portal? **App registrations → Copilot Blueprint Explorer → API permissions → Add a permission → Microsoft Graph → Delegated**, add those three, then **Grant admin consent**. The result is identical. The button exists so that nobody has to be talked through the portal.

### 3.3 Grant the access-group check

These two application permissions let the console check who is in the access group. Until they are granted, the group is not enforced.

1. **Settings → Roles & permissions →** the **Managed identity** section.
2. Find **`GroupMember.Read.All`** and **`User.ReadBasic.All`**, and select **Grant** on each. Grant nothing else yet.
3. **Restart the web app** (Azure portal → the web app → **Overview → Restart**), or ask the deployer to. Microsoft Entra writes application permissions into the identity's token, and a token issued before the grant does not have them. The restart gets a new token.
4. Reload the console. Then go to **Settings → Users** and confirm you are listed as **SuperAdmin**.

From this point the access group is the gate, alongside named people and Global Administrators.

> **Be the first person to sign in after the restart.** The first member of the access group to reach the console claims the first **SuperAdmin** role. Make sure that is you, then appoint others under **Settings → Users**.

### 3.4 Test without scanning anything (**No scan**)

This proves sign-in, the access group and roles work before the console is given any right to read your tenant.

1. Switch **No scan** on in the top bar. While it is on, the console reads nothing from your tenant. Every check becomes a question an administrator can answer by hand, and nothing is scanned.
2. Ask a member of the access group who is not an administrator to sign in. They should arrive as **Reader**.
3. On **Work items**, open a few checks and use **Record the answer**. The **Executive summary** counts answered checks separately from measured ones.
4. Open **Help** (top bar) **→ Help and permissions → Frequently Asked Questions** to see what the console reads, and why.

If the customer is not ready to allow a scan, the console can stay in this mode. It remains a complete, manually answered assessment.

### 3.5 Grant everything else for the full scan

Work through **Settings → Roles & permissions** from top to bottom. Every row says what it is used for. **Grant all** in each section grants only what is **required**. Optional and write-capable extras stay a separate, deliberate choice, and everything can be revoked from the same page.

1. **App registration → Grant all.** These are delegated permissions, so they only ever act as the signed-in administrator. Then **sign out and back in**, so that your session picks them up.
2. **Managed identity → Grant all.** These are the app-only reads. If you used Option B and skipped the role assignments, **Automation Job Operator** and **Reader** appear here too.
3. **Purview collector app** (if created):
   - Under **Settings → Configuration → Purview DLP collector**, check the collector client ID and tenant organisation (already filled if they were set at deployment). **Save.**
   - **Roles & permissions → Purview collector app → Grant all.** This grants Exchange.ManageAsApp, Organization.Read.All and the Entra **Global Reader** role.
   - Register the collector in Security & Compliance and add it to two **read-only** Purview role groups. Run this once in Cloud Shell (PowerShell), or in any PowerShell with the ExchangeOnlineManagement module and the Azure CLI:
     ```powershell
     & {
         $AdminUpn       = 'admin@contoso.com'       # you
         $CollectorName  = 'CBX Purview Collector'   # as created in 1.3
         $CollectorAppId = ''                        # empty: looked up by name

         Connect-IPPSSession -UserPrincipalName $AdminUpn   # in Cloud Shell, add -Device if no sign-in window opens
         if (-not $CollectorAppId) { $CollectorAppId = az ad app list --filter "displayName eq '$CollectorName'" --query "[0].appId" -o tsv }
         $collectorSpId = az ad sp list --filter "appId eq '$CollectorAppId'" --query "[0].id" -o tsv
         if (-not (Get-ServicePrincipal | Where-Object AppId -eq $CollectorAppId)) {
             New-ServicePrincipal -AppId $CollectorAppId -ServiceId $collectorSpId -DisplayName $CollectorName
         }
         foreach ($roleGroup in 'SecurityReader', 'GlobalReader') {
             try { Add-RoleGroupMember -Identity $roleGroup -Member $CollectorName -ErrorAction Stop; "Added to $roleGroup" }
             catch { "${roleGroup}: $($_.Exception.Message)" }   # "already a member" is fine
         }
     }
     ```
   - Optional, and shown as optional on the page:
     - **Sites.FullControl.All** (SharePoint), for SharePoint and OneDrive tenant settings.
     - **Compliance Administrator**, for Insider Risk, Communication Compliance and audit retention.

     Both can write, although the runbook only reads. Without them, those checks stay manual answers, with the reason shown.
4. **Automation account** (Power Platform):
   - **Power Platform management app → Grant.** This needs Power Platform Administrator. If the row says so, first grant *PowerApps Service* under **App registration**.
   - On the **Agent estate** page, select **Collect from Power Platform**. This discovers your Dataverse environments.
   - Back on **Roles & permissions → Automation account**, select **Grant** on **CBX agent inventory reader** for each environment. This needs System Administrator in that environment. It reads only agents and AI Builder models, deliberately not transcripts.
5. **AskCBX**: optional, and configured here rather than at deployment. See 3.5a below.

### 3.5a AskCBX, and governing it in Foundry

**Entirely optional, and nothing here is created by the deployment.** The template creates one App Service and one Automation account, and no more. The Foundry project, the model deployment and — if you want conversation recording — the Application Insights resource are all **yours to provide**, existing or new, in whatever subscription and resource group your standards say. The console only points at what you give it. Skip this section and the rest of the console works exactly the same.

1. **Point it at your project.** **Settings → Configuration → AskCBX**: switch it on, then enter the **project endpoint** (`https://<resource>.services.ai.azure.com/api/projects/<project>`) and the **model deployment name**. Save.
2. **Grant the app identity.** Under **Roles & permissions**, give the web app's managed identity **Foundry User** on that project. Ask a question to confirm it answers.

That is enough for a working assistant. The rest turns it into an agent you can govern, and each step is optional on its own.

3. **Answer through an agent.** Create a **prompt agent** in the Foundry portal (any name; `cbx-agent` is the convention). Put that name in **Answer through a Foundry agent** and save. Every question now runs through the agent, which is what makes the project's **Traces**, **Monitor**, **Evaluation**, guardrails and red teaming apply to this traffic. The same agent can be published to Teams and Microsoft 365 Copilot from the portal.
4. **Publish the definition.** Select **Publish the definition to this agent**. This writes the console's guardrail instructions, the model and its tools onto the agent as a new version. Until you do, the agent is empty and the instructions live only inside the application, where nobody can review them. Needs write access on the project — **Azure AI Project Manager**, or Foundry User plus agent write.
5. **Ground answers in Microsoft Learn** (optional). Lets the assistant cite Microsoft's current documentation instead of answering from memory. Only the search terms the model chooses leave the project; nothing measured about your tenant is sent. With an agent named, this is applied when you publish rather than per request, because an agent owns its own tools.
6. **Record conversations** (optional). Switch on **Record conversations in Foundry** and give the **name** of an Application Insights resource **you already have**. Foundry then records each question, tool call and answer server-side; without it the Traces and Monitor tabs stay empty. Nothing is created for you — if you have no suitable resource and do not want one, leave this off.

   Whichever you nominate must be one you can actually read. An Application Insights behind **Private Link**, or in a subscription you lack access to, makes the portal's Traces tab fail with *"insufficient access"* even though recording is on. The Foundry project's own managed identity needs **Monitoring Metrics Publisher** on it.

   The connection is made as you, not by the app. Turning it on replaces any Application Insights connection already on the project; turning it off removes only the one this console made, and leaves the resource itself untouched.


### 3.6 Run the full scan

1. Switch **No scan** off.
2. **Executive summary → Re-scan tenant.**
3. **Governance → Collect from Purview**, and **Agent estate → Collect from Power Platform.** Both run in your Automation account and take a few minutes.
4. Return to **Settings → Roles & permissions**. The badges should show nothing **required but missing**.

Any manual answers from 3.4 stay in place. A measured reading always takes precedence over an answer, and the report says when that happened.

---

## Named people: access without reading the directory

A **named person** may sign in whether or not the access group lists them, and whether or not that group can be checked at all. Two uses:

- **Before the group exists.** The deployment seeds this list with the deployer (3.1), which is how the console is reachable on its first start.
- **Instead of the group.** If the organisation will not grant `GroupMember.Read.All` and `User.ReadBasic.All`, the console cannot read the directory at all. Naming people needs no directory permission whatsoever.

To use it:

1. Sign in as a Global Administrator, or as the seeded deployer.
2. **Settings → Users → Named people:** add each person's UPN and choose their role (Reader by default).
3. The console assigns them to the enterprise application at the same time, because **Assignment required = Yes** means Entra refuses a token to anyone who is not assigned — before the console is reached at all. The row shows the result, and anyone added before this was automatic can be repaired with **Assign**.

> **`AADSTS50105` — "The signed in user is blocked because they are not a direct member of a group with access, nor had access directly assigned"**
>
> That is Entra's own refusal, not this console's, and naming the person here does not by itself clear it: with **Assignment required = Yes** the token is refused first. Adding a person now assigns them as well, provided you hold a role that can assign users to an application (Cloud Application Administrator or Global Administrator) and the delegated `AppRoleAssignment.ReadWrite.All` permission has been granted. If not, the row says **blocked by Entra** and you can do it in the portal: **Enterprise applications → Copilot Blueprint Explorer → Users and groups → Add user/group**.
>
> Use the name the person actually signs in with. A guest invited from another tenant signs in with their **home** address (`alex@contoso.com`), which is not the same as the `#EXT#` name Entra stores, and can also differ from their `mail` attribute. The console matches either form; Entra's assignment is by account, so it is unaffected.

The console records each named person's account the first time they sign in, and refuses a different account that later takes over the same UPN. So the complete answer to *who can sign in* is: **anyone in the access group, anyone on this list, or any Global Administrator.**

---

## Updating to a new release

Repeat **2.1**. It always fetches the current contents of the release folder, so there is nothing to compare or choose — and it refuses anything that does not match its own checksum. Settings, roles, manual answers, scan history and work-item tracking live in the web app's persistent storage (`/home/data`) and survive updates and restarts. The runbooks change rarely; when they do, run the Stage 1.2 block again, which re-imports any runbook that is not already published.

---

## Removing the deployment

Some grants live outside the resource group and are **not** removed when it is deleted, so revoke them first:

1. In the console, **Settings → Roles & permissions:**
   - **Revoke all** in each section, in particular **Automation account**. This removes the Power Platform management app registration and the Dataverse role.
   - Revoke **Purview collector app** as well.
2. In Security & Compliance PowerShell: `Remove-RoleGroupMember` for both role groups, then `Remove-ServicePrincipal -Identity "CBX Purview Collector"`.
3. Delete the **resource group**. This removes the web app, its identities and their Azure role assignments, the Automation account and its certificate.
4. In Entra, delete the **Copilot Blueprint Explorer** and **CBX Purview Collector** app registrations, and the access group if it is no longer needed.

---

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| **AADSTS50105** at sign-in | The person is not assigned to the enterprise application. Add them to the access group (group assignment needs Entra ID P1), or assign them directly. |
| **Settings is missing, and you are a Global Administrator** | The console recognises a Global Administrator only through the `wids` directory-role claim in the access token. That claim does not arrive in every tenant &mdash; it is absent even where the optional claim is configured on the app registration &mdash; so do not rely on it. Use the role book instead: the **first person to sign in to a new deployment becomes Super Admin**, and after that an administrator adds others under **Settings → Users**. If nobody can reach Settings at all, see the next row. The banner on the page says which of the two cases you are in. |
| **Nobody can reach Settings** (the deployment has no usable administrator) | Whoever owns the Azure subscription can set the role directly. Web app → **Development Tools → Advanced Tools → Go** (Kudu) → **Debug console → CMD**, open `/home/data/cbx-roles.json` and add or edit an entry: `{"Upn":"you@contoso.com","Role":"SuperAdmin"}` inside `Members`. Save, then **Restart** the web app and sign in again. This happens most often when *Deployer Upn* in step 1.1 was a different sign-in name from the one actually used &mdash; the seeded entry then fills the role book without matching anyone, which stops the first-sign-in claim from firing. |
| **Re-scan tenant is enabled although nothing has been granted** | The button asks `/api/admin/permissions/consent` whether a scan would read anything. Fixed in this release: that call used to be refused to a Reader, and an unanswered question left the button enabled. If it persists, you are on an older build. |
| **AADSTS50011** redirect URI mismatch | The SPA redirect URI is missing or different. It must be exactly `https://<web-app-name>.azurewebsites.net` under **Single-page application** (not *Web*). Re-running the 1.2 block sets it from the real web app. |
| **AADSTS65001** or "Need admin approval" | Tenant-wide consent was refused in 1.2, and `access_as_user` or `User.Read` was not consented by the person either. Ask a Global Administrator to select **Grant admin consent** on the app registration. |
| "This application has not been configured yet" (`setup_in_progress`) | No access group is set, and the person is not a Global Administrator. Set the group ID at deployment, or under **Settings → Users**. |
| "Access cannot be checked" (`access_gate_unavailable`) | Microsoft Graph could not be reached, or the call timed out. This is transient — retry before changing anything. A *missing* permission no longer produces this: it opens the setup window described in 3.1 instead. |
| The deployer cannot sign in | If they are a guest, `Cbx__DeployerUpn` must be set. Either their own address or the `#EXT#` form works. Check **Settings → Users → Named people** once you are in. |
| "You are not a member of the group" (`not_in_access_group`) | Add the person to the access group. Membership is re-checked every 15 minutes. |
| A colleague sees `AADSTS50105` from Microsoft, not from the console | Entra refused the token because **Assignment required = Yes** and they are not assigned. Add them under **Settings → Users → Named people**, which assigns them as well; or, if the row says **blocked by Entra**, use **Enterprise applications → Users and groups → Add user/group**. Naming them alone is not enough. |
| Global Administrator refused at first sign-in or in recovery | The `wids` claim is missing. Without it, the console cannot see the Global Administrator role. Re-run the 1.2 block, which sets it. |
| Pages fail with a federated-identity or token-exchange error | The federated credential `cbx-uami-fic` must name the user-assigned identity **attached to the web app**, and `Cbx__UserAssignedClientId` must be that identity's **Client ID**. Re-running the 1.2 block repairs both. |
| Deployment log says *"Couldn't detect a version for the platform 'dotnet' in the repo"* | The zip went through a build step. That happens with Deployment Center → Publish files (new). Deploy with the 2.1 Cloud Shell block instead. |
| `/api/config` shows an empty client ID | Step 1.2 has not been run, or was run against a different deployment. Run it again; it is safe to repeat. |
| 2.1 fails with **404** from GitHub | The token cannot see the repository. A fine-grained token needs **Contents: Read-only** on that specific repository, and the resource owner must be the account or organisation that owns it. An expired token gives **401**. |
| The app shows "Application Error" | Check that `SCM_DO_BUILD_DURING_DEPLOYMENT` is `false`, the stack is .NET 8 and the startup command is empty. **Monitoring → Log stream** shows the start-up error. |
| **Collect from Purview** fails | Automation account → **Jobs →** the latest job → **Output / Errors**. Common causes: modules not yet *Available* (MicrosoftTeams takes the longest); the role groups in 3.5.3 are missing; or the certificate is missing at one of its two ends. Re-running the 1.2 block re-imports anything missing and reports the state of each; add `$RenewCertificate = $true` to replace the certificate itself. |
| **Collect from Power Platform** reports the identity is not registered | Grant **Power Platform management app** (3.5.4). Changes can take a few minutes to reach Power Platform. |

---

## For maintainers

1. The repository root is **this folder**: `azuredeploy.json`, `main.bicep`, `runbooks/`, `README.md`. The public repository never contains `release/` (the zip and its checksum): `.gitignore` excludes it, and both files are handed to each customer directly.
2. `scripts/Build-Package.ps1` in the source repository produces the zip, its checksum, the runbooks and `azuredeploy.json` together. It verifies the zip before writing the checksum, including that it contains no backslash paths. Push the template and runbooks from the same build as the zip you hand over.
3. If the template changes, rebuild it before pushing:
   ```bash
   az bicep build --file main.bicep --outfile azuredeploy.json
   ```
4. **Moving the kit to another repository** (it must be public for the button to work): push these files there, then change the two repository-specific lines in this README — the **Deploy to Azure** link in 1.1 and the `$RunbookBaseUrl` default in the 1.2 block. The link is the raw address of `azuredeploy.json`, URL-encoded:
   `https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2F<owner>%2F<repo>%2Fmain%2Fazuredeploy.json`
   The release folder that 2.1 fetches lives in a **separate, private** repository. Its address is deliberately not written down here: it is prompted for at run time and sent to the deployer directly, along with a read-only token. The template itself finds the runbooks next to wherever it was fetched from, so it needs no editing.
