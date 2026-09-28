# Copilot Blueprint Explorer: deployment kit

Copilot Blueprint Explorer (CBX) is a web console that assesses a Microsoft 365 tenant's readiness and security posture for Microsoft 365 Copilot and agents. It runs in your own Azure subscription, reads your tenant with identities you control, and stores its results in the web app's own storage. It holds no secret, and your data goes to no third party.

Deployment takes **three stages**, all in the Azure and Entra portals. Azure Cloud Shell is offered as an alternative wherever it saves clicks.

| Stage | Who | What | Where |
|---|---|---|---|
| **1** | Global Administrator, or an administrator with the minimum roles below | Creates the access group and the app registration, the resource group, and the Azure resources (one click, or by hand) | Entra admin centre and Azure portal, or Cloud Shell (a ready-made block per step) |
| **2** | Deployer (Contributor on the resource group) | Uploads the application zip and configures the resources | Azure portal and its Cloud Shell |
| **3** | Global Administrator | Signs in, grants the two basic permissions, tests with **No scan**, then grants the rest for a full scan | The console itself |

---

## What is in this folder

| Path | Purpose |
|---|---|
| `azuredeploy.json` | The one-click ARM template (compiled from `main.bicep`). Used by the **Deploy to Azure** button. |
| `main.bicep` | The template's readable source. |
| `runbooks/Get-CbxDlpPolicies.ps1` | Automation runbook: reads Purview, Exchange Online, Teams and (optionally) SharePoint settings that no Graph API exposes. |
| `runbooks/Get-CbxPowerPlatform.ps1` | Automation runbook: reads Power Platform environments, connector DLP policies and Copilot Studio agents. |
| **Handed over separately** `cbx-app.zip` | The application, ready to upload. Not in this repository: your Microsoft contact gives it to you directly. |
| **Handed over separately** `cbx-app.zip.sha256` | Its SHA-256 checksum, so you can prove the zip is exactly the one you were given. |

### What gets created in Azure

| Resource | Purpose |
|---|---|
| App Service plan (Linux, B1) | Hosts the web app. |
| Web app (.NET 8, Linux) | The console and its API. HTTPS only, TLS 1.2, FTP disabled, Always On, health check on `/api/health`. |
| Web app **system-assigned** managed identity | Every app-only read of Microsoft Graph and Azure. Starts and reads the collection runbooks. |
| **User-assigned** managed identity | Nothing but the federated credential that lets the API act for the signed-in person without a client secret. |
| Automation account (Basic) | Runs the two collection runbooks. Holds the Purview collector's certificate. Its own identity reads Power Platform. The template imports two PowerShell modules into it; the third (MicrosoftTeams) is imported in Stage 2. |

Two Azure role assignments are made, and nothing wider: the web app's identity gets **Automation Job Operator** and **Reader** on the Automation account. If a deployer is named, they get **Contributor** on the resource group.

---

## Before you start

### Minimum roles

| Stage | Microsoft Entra | Azure |
|---|---|---|
| 1 | **Cloud Application Administrator** (app registrations, admin consent to delegated permissions, enterprise app assignment, federated credential) **and Groups Administrator** (the security group). Or Global Administrator. | **Owner** of the subscription, or **Contributor + Role Based Access Control Administrator**. You create a resource group and role assignments. |
| 2 | None. Only if the deployer uploads the collector certificate: **Owner of the collector app registration**. | **Contributor** on the resource group. |
| 3 | **Global Administrator**. Or split: Privileged Role Administrator (Graph application permissions and Entra roles), Purview **Organization Management** (role groups), **Power Platform Administrator**, and **System Administrator** in each Dataverse environment. | Only if Stage 1 created the resources by hand: Owner or User Access Administrator on the Automation account. |

### Licensing note

Assigning a **group** to an enterprise application requires Microsoft Entra ID P1, which is included in Microsoft 365 E3 and E5. Without it, assign users individually in step 1.2.

### Values you will collect

Keep the **handover sheet** (step 1.7) open as you go. Stage 2 and Stage 3 need every value on it.

---

## Stage 1: Administrator, in the portals

Every step except 1.5 also has a **Cloud Shell alternative**: one block of commands that does the whole step. To use it:
1. Open Cloud Shell from the `>_` icon in the Azure portal's top bar, and choose **PowerShell**.
2. Edit the parameters at the top of the block. Leave `TenantId` and `SubscriptionId` empty to use the ones Cloud Shell is signed in to.
3. Paste the whole block and press Enter.

Each block reuses whatever already exists, so it is safe to run again. It stops at the first error, and prints the values for the handover sheet when it finishes.

### 1.1 Create the access group

1. **Entra admin centre → Groups → All groups → New group.**
2. Group type **Security**, name for example `Copilot Blueprint Explorer users`, membership type **Assigned**.
3. Add as members: **yourself (the Global Administrator)**, the deployer, and the people who will use the console.
4. **Create.** Open the group and copy its **Object ID** onto the handover sheet.

> Only members of this group can use the console, because **Assignment required** is switched on in step 1.2.5 — Microsoft Entra will not even issue a token to anyone else. The Global Administrator **must** be a member, or they cannot sign in to do step 3.2.

<details>
<summary><strong>Cloud Shell alternative (PowerShell)</strong></summary>

```powershell
& {
    # --- Parameters. Empty TenantId / SubscriptionId: the ones Cloud Shell is signed in to.
    $TenantId       = ''
    $SubscriptionId = ''
    $GroupName      = 'Copilot Blueprint Explorer users'
    $MemberUpns     = @('deployer@contoso.com', 'user1@contoso.com')   # the deployer and the console's users; you are added automatically

    # --- Commands
    $ErrorActionPreference = 'Stop'; $PSNativeCommandUseErrorActionPreference = $true
    if (-not $TenantId) { $TenantId = az account show --query tenantId -o tsv }
    if ($TenantId -ne (az account show --query tenantId -o tsv)) { az login --tenant $TenantId --use-device-code -o none }
    if (-not $SubscriptionId) { $SubscriptionId = az account show --query id -o tsv }
    az account set --subscription $SubscriptionId

    $groupId = az ad group list --filter "displayName eq '$GroupName'" --query "[0].id" -o tsv
    if (-not $groupId) {
        $groupId = az ad group create --display-name $GroupName --mail-nickname ($GroupName -replace '[^A-Za-z0-9]', '') --query id -o tsv
    }
    $memberIds = @(az ad signed-in-user show --query id -o tsv) + @($MemberUpns | Where-Object { $_ } | ForEach-Object { az ad user show --id $_ --query id -o tsv })
    foreach ($id in $memberIds) {
        if ((az ad group member check --group $groupId --member-id $id --query value -o tsv) -ne 'true') {
            az ad group member add --group $groupId --member-id $id
        }
    }

    "Tenant ID:              $TenantId"
    "Access group Object ID: $groupId"
}
```

</details>

### 1.2 Create the app registration (the console's sign-in)

One app registration serves both the browser sign-in and the API.

1. **Entra admin centre → App registrations → New registration.**
   - Name: `Copilot Blueprint Explorer`
   - Supported account types: **Accounts in this organizational directory only (single tenant)**
   - Redirect URI: leave empty for now (added in step 1.6).
   - **Register.** Copy the **Application (client) ID** and the **Directory (tenant) ID** onto the handover sheet.
2. **Expose an API.**
   - Next to *Application ID URI*, select **Add** and accept the default `api://<client-id>`. **Save.**
   - **Add a scope**:
     - Scope name `access_as_user`
     - Who can consent **Admins and users**
     - Admin consent display name `Access Copilot Blueprint Explorer`
     - Admin consent description `Allows the app to call the Copilot Blueprint Explorer API as the signed-in user.`
     - State **Enabled**
   - **Add scope.**
3. **Manifest.** Make two edits, then **Save**:
   - Under `"api"`, set `"requestedAccessTokenVersion": 2`
   - Set `"optionalClaims"` to include the `wids` claim in the access token:
     ```json
     "optionalClaims": {
         "accessToken": [ { "name": "wids", "essential": false } ],
         "idToken": [],
         "saml2Token": []
     },
     ```
   > **Why `wids` matters:** the `wids` claim tells the console who is a Global Administrator. Without it, nobody can complete first-run setup or recovery, and the console cannot repair its own access. An equivalent route is **Token configuration → Add groups claim → Directory roles** only.
4. **API permissions → Add a permission → My APIs → Copilot Blueprint Explorer →** tick `access_as_user` → **Add permissions**.

   That is the only permission you add. The list should read:

   | Permission | Type | Why |
   |---|---|---|
   | `User.Read` | Delegated | Sign-in. Added by Microsoft Entra when the app is registered. |
   | `access_as_user` | Delegated | Lets the browser call this application's own API. |

   Neither requires admin consent, so there is nothing here with a **Not granted** warning. Selecting **Grant admin consent** is optional and only saves each user a one-off sign-in prompt.

   > **Nothing else is added here, and nothing else is consented here.** Every permission this console ever uses — including the three it needs to grant permissions at all — is granted later, from inside the console, by a Global Administrator who can see what each one is for (Stage 3.2). Until that happens the application holds no access to your tenant whatsoever.
   >
   > This is why the deployment can be reviewed before it is trusted: at the end of Stage 2 the app registration is still an empty shell.
5. **Enterprise applications →** open **Copilot Blueprint Explorer**:
   - **Properties → Assignment required? = Yes → Save.**
   - **Users and groups → Add user/group →** select the group from 1.1 **→ Assign.**

<details>
<summary><strong>Cloud Shell alternative (PowerShell)</strong>: all of 1.2, including admin consent</summary>

```powershell
& {
    # --- Parameters. Empty TenantId / SubscriptionId: the ones Cloud Shell is signed in to.
    $TenantId       = ''
    $SubscriptionId = ''
    $AppName        = 'Copilot Blueprint Explorer'
    $GroupName      = 'Copilot Blueprint Explorer users'   # the group from 1.1
    $GroupObjectId  = ''                                   # empty: look the group up by name

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

    if (-not $GroupObjectId) { $GroupObjectId = az ad group list --filter "displayName eq '$GroupName'" --query "[0].id" -o tsv }
    if (-not $GroupObjectId) { throw "Group '$GroupName' not found. Run 1.1 first." }

    # App registration, single tenant
    $app = az ad app list --filter "displayName eq '$AppName'" --query "[0].[appId,id]" -o tsv
    if (-not $app) { $app = az ad app create --display-name $AppName --sign-in-audience AzureADMyOrg --query "[appId,id]" -o tsv }
    $appId, $appObjectId = @($app) -split "`t"

    # Expose api://<client-id>/access_as_user, request v2 tokens, and emit the wids claim
    $scopeId = az ad app list --filter "appId eq '$appId'" --query "[0].api.oauth2PermissionScopes[?value=='access_as_user'].id" -o tsv
    if (-not $scopeId) { $scopeId = [guid]::NewGuid().Guid }
    Invoke-Rest PATCH "https://graph.microsoft.com/v1.0/applications/$appObjectId" @{
        identifierUris = @("api://$appId")
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

    # Delegated permissions: User.Read plus this app's own access_as_user, and deliberately nothing else.
    # Neither needs admin consent. Everything the console uses is granted later, from inside it, in 3.2.
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

    # Enterprise application: assignment required, and the group assigned
    $spId = az ad sp list --filter "appId eq '$appId'" --query "[0].id" -o tsv
    if (-not $spId) { $spId = az ad sp create --id $appId --query id -o tsv }
    Invoke-Rest PATCH "https://graph.microsoft.com/v1.0/servicePrincipals/$spId" @{ appRoleAssignmentRequired = $true }
    $assigned = az rest --method GET --url "https://graph.microsoft.com/v1.0/servicePrincipals/$spId/appRoleAssignedTo" --query "value[?principalId=='$GroupObjectId'].id" -o tsv
    if (-not $assigned) {
        Invoke-Rest POST "https://graph.microsoft.com/v1.0/servicePrincipals/$spId/appRoleAssignedTo" @{ principalId = $GroupObjectId; resourceId = $spId; appRoleId = '00000000-0000-0000-0000-000000000000' }
    }

    # Consent for the two that need none anyway, so nobody sees a sign-in prompt. Adds, never removes.
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

    "Tenant ID:                         $TenantId"
    "Application (client) ID:           $appId"
    "Access group Object ID:            $GroupObjectId"
}
```

</details>

### 1.3 Create the Purview collector app registration

The collector reads what Microsoft Graph does not expose: DLP policies, retention, labels, Exchange Online and Teams settings, and the SharePoint Advanced Management readings behind the Oversharing controls. Security & Compliance PowerShell accepts only certificate-based app-only sign-in, so it needs its own app registration and certificate. **Create it now** &mdash; the deployment in 1.5 asks for its Application (client) ID.

1. **App registrations → New registration.** Name `CBX Purview Collector`, **single tenant**, no redirect URI. **Register.**
2. Copy its **Application (client) ID** onto the handover sheet. Also open **Enterprise applications → CBX Purview Collector** and copy its **Object ID**. This is the service principal's ID, which Stage 3 needs; it is **not** the app registration's object ID.
3. If the **deployer** will upload the certificate in Stage 2: **Owners → Add owners →** the deployer.

Add no permissions here. The console grants them in Stage 3 and shows why each one is needed.

<details>
<summary><strong>Cloud Shell alternative (PowerShell)</strong></summary>

```powershell
& {
    # --- Parameters. Empty TenantId / SubscriptionId: the ones Cloud Shell is signed in to.
    $TenantId       = ''
    $SubscriptionId = ''
    $CollectorName  = 'CBX Purview Collector'
    $DeployerUpn    = ''   # optional: makes the deployer an owner, so they can upload the certificate in 2.4

    # --- Commands
    $ErrorActionPreference = 'Stop'; $PSNativeCommandUseErrorActionPreference = $true
    if (-not $TenantId) { $TenantId = az account show --query tenantId -o tsv }
    if ($TenantId -ne (az account show --query tenantId -o tsv)) { az login --tenant $TenantId --use-device-code -o none }
    if (-not $SubscriptionId) { $SubscriptionId = az account show --query id -o tsv }
    az account set --subscription $SubscriptionId

    $collectorAppId = az ad app list --filter "displayName eq '$CollectorName'" --query "[0].appId" -o tsv
    if (-not $collectorAppId) { $collectorAppId = az ad app create --display-name $CollectorName --sign-in-audience AzureADMyOrg --query appId -o tsv }
    # The portal creates the enterprise application automatically; the CLI does not
    $collectorSpId = az ad sp list --filter "appId eq '$collectorAppId'" --query "[0].id" -o tsv
    if (-not $collectorSpId) { $collectorSpId = az ad sp create --id $collectorAppId --query id -o tsv }
    if ($DeployerUpn) {
        $deployerId = az ad user show --id $DeployerUpn --query id -o tsv
        if (-not (az ad app owner list --id $collectorAppId --query "[?id=='$deployerId'].id" -o tsv)) {
            az ad app owner add --id $collectorAppId --owner-object-id $deployerId
        }
    }

    "Tenant ID:                           $TenantId"
    "Collector Application (client) ID:   $collectorAppId"
    "Collector enterprise app Object ID:  $collectorSpId"
}
```

</details>

### 1.4 Create the resource group

1. **Azure portal → Resource groups → Create.** Choose the subscription, a name (for example `rg-copilot-blueprint`) and a region. **Review + create.**
2. If someone else will run Stage 2 and you will **not** use the one-click template: open the resource group, then **Access control (IAM) → Add role assignment → Contributor →** select the deployer **→ Review + assign.** (The template can do this for you.)

<details>
<summary><strong>Cloud Shell alternative (PowerShell)</strong></summary>

```powershell
& {
    # --- Parameters. Empty TenantId / SubscriptionId: the ones Cloud Shell is signed in to.
    $TenantId       = ''
    $SubscriptionId = ''
    $ResourceGroup  = 'rg-copilot-blueprint'
    $Location       = 'westeurope'   # any Azure region
    $DeployerUpn    = ''             # the Stage 2 deployer, e.g. deployer@contoso.com. Leave empty if you run Stage 2 yourself,
                                     # or if you will enter the deployer in the 1.5 template instead (doing both makes 1.5 fail).

    # --- Commands
    $ErrorActionPreference = 'Stop'; $PSNativeCommandUseErrorActionPreference = $true
    if (-not $TenantId) { $TenantId = az account show --query tenantId -o tsv }
    if ($TenantId -ne (az account show --query tenantId -o tsv)) { az login --tenant $TenantId --use-device-code -o none }
    if (-not $SubscriptionId) { $SubscriptionId = az account show --query id -o tsv }
    az account set --subscription $SubscriptionId

    # An existing group is reused as it is: re-creating it would drop its tags
    $rgId = if ((az group exists --name $ResourceGroup) -eq 'true') { az group show --name $ResourceGroup --query id -o tsv } else { az group create --name $ResourceGroup --location $Location --query id -o tsv }
    if ($DeployerUpn) {
        $deployerId = az ad user show --id $DeployerUpn --query id -o tsv
        if (-not (az role assignment list --assignee $deployerId --role Contributor --scope $rgId --query "[0].id" -o tsv)) {
            az role assignment create --assignee-object-id $deployerId --assignee-principal-type User --role Contributor --scope $rgId -o none
        }
    }

    "Tenant ID:       $TenantId"
    "Subscription ID: $SubscriptionId"
    "Resource group:  $ResourceGroup ($Location)"
}
```

</details>

### 1.5 Create the Azure resources

Choose **one** of the two options.

#### Option A: one click (recommended)

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FMSCopilotAdoption%2FCopilotBlueprintExplorer%2Fmain%2Fazuredeploy.json)

> The button needs this repository to be **publicly readable**, because the Azure portal fetches the template anonymously. If the button reports that it cannot download the template, use the file instead. Download `azuredeploy.json` from this repository, then in the portal search **Deploy a custom template → Build your own template in the editor → Load file**, select it and **Save**. The form that follows is the same, but the runbooks are then not imported automatically (2.4 covers them).

Select the resource group from 1.4, then fill in:

| Parameter | Value |
|---|---|
| **Api Client Id** | Application (client) ID from 1.2. Required. |
| **Security Group Object Id** | Object ID from 1.1. (If left empty, only Global Administrators can sign in until a group is set under Settings → Users.) |
| **Deployer Object Id** | The deployer's Object ID (**Entra → Users →** the person **→ Object ID**). They get Contributor on this resource group only. Leave empty if you run Stage 2 yourself. |
| **Deployer Upn** | The deployer's sign-in name, for example `alex@contoso.com`. Recorded once as the first **named person**, so they can sign in before the access group exists (see 3.1). Remove or re-role them later under Settings → Users. Leave empty to skip. |
| Name Prefix | `cbx` (default). Lowercase letters and digits, 2–6 characters. |
| Web App Name | Leave empty to generate a unique one, or choose a globally unique name. It becomes `https://<name>.azurewebsites.net`. |
| Web App Sku | `B1` is enough. |
| Runbook Base Url | **Leave empty.** Through the button, the two runbooks are imported automatically from the `runbooks` folder next to the template. Set it only to use a different copy. |
| **Purview Collector App Id** | Application (client) ID from step 1.3. Required. |
| **Purview Organization** | Your primary `onmicrosoft.com` domain, for example `contoso.onmicrosoft.com`. Required. |

**Review + create → Create.** It takes about five to ten minutes, most of it importing two PowerShell modules into the Automation account. The third module, MicrosoftTeams, is left to Stage 2 (2.4), so a slow import cannot hold up the deployment.

When it finishes, open **Outputs** and copy every value onto the handover sheet. `runbooksImportedFrom` shows whether the runbooks were imported, or need importing in 2.4.

<details>
<summary><strong>Option B: create the resources by hand</strong> (expand)</summary>

Stage 2 finishes the configuration. Here you only create the resources.

1. **User-assigned managed identity:** **Create a resource → User Assigned Managed Identity →** your resource group, name for example `cbx-uami` **→ Create.** Copy its **Client ID** and **Object (principal) ID**.
2. **Web app:** **Create a resource → Web App.**
   - Publish **Code**, Runtime stack **.NET 8 (LTS)**, Operating system **Linux**, your region.
   - Pricing plan: create a new Linux plan, **Basic B1**.
   - **Review + create → Create.** Copy the web app name and URL.
3. **Web app identity:** open the web app → **Identity → System assigned → On → Save.**
4. **Automation account:** **Create a resource → Automation →** your resource group, name for example `cbx-aa` **→** leave the system-assigned identity **on → Create.** Everything this console reads outside Microsoft Graph is collected here, so a deployment without it leaves the Purview, Exchange, Teams, SharePoint and Power Platform checks as manual answers.
5. **Role assignments** (you need Owner or User Access Administrator): open the Automation account → **Access control (IAM) → Add role assignment:**
   - **Automation Job Operator** → Assign access to **Managed identity** → **App Service** → the web app → **Review + assign.**
   - Repeat for **Reader**.

   *(Alternatively, grant both later from the console, under Settings → Roles & permissions → Managed identity, in Stage 3.)*
6. Make the deployer **Contributor** on the resource group (step 1.4.2).

</details>

### 1.6 Finish the app registration

Both of these need the web app and the user-assigned identity, which now exist.

1. **Browser redirect URI:** **App registrations → Copilot Blueprint Explorer → Authentication → Add a platform → Single-page application.**
   - Redirect URI: `https://<web-app-name>.azurewebsites.net` exactly: `https`, no trailing slash, no path.
   - Leave both implicit-grant boxes **unticked**. **Configure.**
2. **Federated credential** (lets the API act for the signed-in person without a secret): **Certificates & secrets → Federated credentials → Add credential.**
   - Federated credential scenario: **Managed identity**.
   - Select managed identity: your subscription, type **User-assigned managed identity**, and the one created in 1.5 (`cbx-uami-…`).
   - Name: `cbx-uami-fic`. Leave the audience as `api://AzureADTokenExchange`. **Add.**

   *If your portal does not offer the Managed identity scenario, choose **Other issuer** and enter:*
   - *Issuer: `https://login.microsoftonline.com/<tenant-id>/v2.0`*
   - *Subject identifier: the user-assigned identity's **Object (principal) ID***
   - *Audience: `api://AzureADTokenExchange`*

<details>
<summary><strong>Cloud Shell alternative (PowerShell)</strong>: redirect URI and federated credential</summary>

```powershell
& {
    # --- Parameters. Empty TenantId / SubscriptionId: the ones Cloud Shell is signed in to.
    $TenantId       = ''
    $SubscriptionId = ''
    $ResourceGroup  = 'rg-copilot-blueprint'
    $AppName        = 'Copilot Blueprint Explorer'
    $WebAppName     = ''   # empty: the only web app in the resource group
    $IdentityName   = ''   # empty: the only user-assigned identity in the resource group

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

    if (-not $WebAppName)   { $WebAppName   = az webapp list --resource-group $ResourceGroup --query "[0].name" -o tsv }
    if (-not $IdentityName) { $IdentityName = az identity list --resource-group $ResourceGroup --query "[0].name" -o tsv }
    if (-not $WebAppName -or -not $IdentityName) { throw "No web app or user-assigned identity in '$ResourceGroup'. Complete 1.5 first." }
    $url       = 'https://' + (az webapp show --resource-group $ResourceGroup --name $WebAppName --query defaultHostName -o tsv)
    $principal = az identity show --resource-group $ResourceGroup --name $IdentityName --query principalId -o tsv
    $app = az ad app list --filter "displayName eq '$AppName'" --query "[0].[appId,id]" -o tsv
    if (-not $app) { throw "App registration '$AppName' not found. Run 1.2 first." }
    $appId, $appObjectId = @($app) -split "`t"

    # Browser redirect URI (single-page application), added to any already registered
    $redirects = @(@(az ad app show --id $appId --query spa.redirectUris -o json | ConvertFrom-Json) + $url | Where-Object { $_ } | Select-Object -Unique)
    Invoke-Rest PATCH "https://graph.microsoft.com/v1.0/applications/$appObjectId" @{ spa = @{ redirectUris = $redirects } }

    # Federated credential: the user-assigned identity stands in for a client secret
    $file = Join-Path ([IO.Path]::GetTempPath()) 'cbx-fic.json'
    @{ name = 'cbx-uami-fic'; issuer = "https://login.microsoftonline.com/$TenantId/v2.0"; subject = $principal; audiences = @('api://AzureADTokenExchange') } |
        ConvertTo-Json | Set-Content -Path $file -Encoding utf8NoBOM
    $ficId = az ad app federated-credential list --id $appId --query "[?name=='cbx-uami-fic'].id" -o tsv
    try {
        if ($ficId) { az ad app federated-credential update --id $appId --federated-credential-id $ficId --parameters "@$file" -o none } else { az ad app federated-credential create --id $appId --parameters "@$file" -o none }
    } finally { Remove-Item $file }

    "Redirect URI:          $url"
    "Federated credential:  cbx-uami-fic -> $IdentityName (principal $principal)"
}
```

</details>

### 1.7 Handover sheet

Send this to the deployer. It contains no secrets.

| Item | Value |
|---|---|
| Tenant ID | |
| Subscription ID | |
| Resource group | |
| Web app name / URL | `https://….azurewebsites.net` |
| Deployer: Object ID / sign-in name | |
| App registration: Application (client) ID | |
| Access group Object ID | |
| User-assigned identity: name / Client ID / Object (principal) ID | |
| Automation account name | |
| Purview collector: Application (client) ID | |
| Purview collector: enterprise app Object ID | |
| Tenant organisation (`….onmicrosoft.com`) | |
| Option used in 1.5 (A or B), and the `runbooksImportedFrom` output | |

---

## Stage 2: Deployer, in the portal

### 2.1 Download and verify the application

1. Your Microsoft contact hands over **`cbx-app.zip`** and **`cbx-app.zip.sha256`**. Keep both files together in one folder.
2. Verify the checksum. It proves the zip is exactly the one you were given.
   - **Windows PowerShell** (in that folder); it must print `True`:
     ```powershell
     (Get-FileHash .\cbx-app.zip -Algorithm SHA256).Hash -eq (Get-Content .\cbx-app.zip.sha256).Split(' ')[0]
     ```
   - The Cloud Shell block in 2.2 checks it again before it deploys anything.
   - For extra assurance, ask your Microsoft contact to read out the checksum through a different channel from the one the files arrived by, and compare it with the file.

> **Upload the zip exactly as downloaded.** Do not unzip and re-zip it. Some Windows zip tools write backslash paths, which Linux App Service cannot extract, and the upload then fails with an unhelpful "400".

### 2.2 Upload the application

Upload with Cloud Shell, from the Azure portal's top bar. It uses the App Service publish API, which deploys a zip exactly as it is, with no build step.

> **Do not use Deployment Center → Publish files (new).** It runs a build step (Oryx) on the upload, and this zip is already built, so the deployment fails with *"Couldn't detect a version for the platform 'dotnet' in the repo"*. Kudu's own *Zip Push Deploy* page does not work for Linux apps either.

1. Open **Cloud Shell** (`>_` in the portal's top bar) and choose **PowerShell**.
2. **Manage files → Upload** both `cbx-app.zip` and `cbx-app.zip.sha256`. They land in your home folder.
3. Paste this block, with your resource group:

```powershell
& {
    $ResourceGroup = 'rg-copilot-blueprint'
    $WebAppName    = ''        # empty: the only web app in the resource group
    $ZipFolder     = $HOME     # where Manage files -> Upload put the two files

    $ErrorActionPreference = 'Stop'; $PSNativeCommandUseErrorActionPreference = $true
    $zip = Join-Path $ZipFolder 'cbx-app.zip'
    $expected = (Get-Content (Join-Path $ZipFolder 'cbx-app.zip.sha256')).Split(' ')[0]
    if ((Get-FileHash $zip -Algorithm SHA256).Hash -ne $expected) { throw 'cbx-app.zip does not match cbx-app.zip.sha256. Do not deploy it; ask for the files again.' }
    if (-not $WebAppName) { $WebAppName = az webapp list --resource-group $ResourceGroup --query "[0].name" -o tsv }
    # The zip is already built: make sure App Service does not try to build it
    az webapp config appsettings set --resource-group $ResourceGroup --name $WebAppName --settings SCM_DO_BUILD_DURING_DEPLOYMENT=false -o none
    az webapp deploy --resource-group $ResourceGroup --name $WebAppName --src-path $zip --type zip --clean true -o none
    $url = 'https://' + (az webapp show --resource-group $ResourceGroup --name $WebAppName --query defaultHostName -o tsv)
    foreach ($try in 1..12) {
        try { $health = Invoke-RestMethod "$url/api/health" -TimeoutSec 20; break } catch { Start-Sleep -Seconds 10 }
    }
    "Deployed to:  $url"
    "Health:       $(if ($health) { $health.status } else { 'not answering yet: check Monitoring -> Log stream' })"
}
```

It checks the zip against its checksum first, and refuses to deploy a file that doesn't match. It takes about two minutes, and ends by printing the app's address and `Health: healthy`.

### 2.3 Configure the web app

If you used **Option A**, everything below is already set. **Check it and move on.** If you used **Option B**, set it now.

1. **Settings → Environment variables → App settings.** These must exist:

   | Name | Value |
   |---|---|
   | `SCM_DO_BUILD_DURING_DEPLOYMENT` | `false` (the zip is already built) |
   | `Cbx__TenantId` | Tenant ID |
   | `Cbx__ApiClientId` | App registration client ID |
   | `Cbx__SpaClientId` | **The same** app registration client ID |
   | `Cbx__UserAssignedClientId` | The user-assigned identity's **Client ID** (not its principal ID) |
   | `Cbx__SecurityGroupObjectId` | Access group Object ID |
   | `Cbx__DeployerUpn` | The deployer's sign-in name. Seeds the first named person on first start, so they can sign in before the access group exists. Optional. |
   | `Cbx__SubscriptionId` | Subscription ID |
   | `Cbx__DeploymentOption` | `AskCbx` (every deployment carries the assistant; it stays switched off until Settings turns it on). `Minimal` additionally hides how-to-fix guidance. |
   | `Cbx__AutomationResourceGroup` | Resource group of the Automation account |
   | `Cbx__AutomationAccountName` | Automation account name |
   | `Cbx__PurviewCollectorAppId` | Collector client ID, from 1.3 |
   | `Cbx__PurviewOrganization` | `contoso.onmicrosoft.com` |

   > **Do not add `AZURE_CLIENT_ID`.** The console deliberately does every app-only read with the web app's **system-assigned** identity. `AZURE_CLIENT_ID` would silently switch it to the user-assigned identity, which holds no permissions.
2. **Option B only:**
   - **Identity → User assigned → Add →** the identity from 1.5 **→ Add.**
   - **Configuration → General settings:** Stack **.NET 8**, Startup command **empty**, **Always on: On**, HTTP version **2.0**, **FTP state: Disabled**, **HTTPS Only: On**, **Minimum inbound TLS version: 1.2**. **Save.**
   - **Monitoring → Health check → Enable**, path `/api/health`. **Save.**
3. **Check that it runs.** Open both addresses in a browser:
   - `https://<web-app-name>.azurewebsites.net/api/health` should return `{"status":"healthy",…}`
   - `https://<web-app-name>.azurewebsites.net/api/config` should show your tenant ID and `api://<api-client-id>/access_as_user`

   Opening the console itself works once the Global Administrator has signed in first (Stage 3).

### 2.4 Configure the Automation account

Skip this if no Automation account was created.

1. **Modules:** Automation account **→ Shared resources → Modules.**

   | Module | Tested version | Imported by | Needed for |
   |---|---|---|---|
   | ExchangeOnlineManagement | 3.5.1 | The template (Option A) | Everything the Purview runbook collects. Required. |
   | Microsoft.Online.SharePoint.PowerShell | 16.0.27612.12000 | The template (Option A) | SharePoint and OneDrive tenant settings. Optional. |
   | MicrosoftTeams | 8.0.0 | **You, here** | Teams app permission and setup policies. Optional. |

   **Import MicrosoftTeams yourself.** It is 22 MB and can take 5 to 20 minutes to import, which is why the template leaves it out. Without it the runbook still runs, and the Teams checks remain manual answers with the reason shown. The Cloud Shell block below does this in one step. By hand: **Add a module → Browse for file**, and upload version 8.0.0. On its PowerShell Gallery page (`https://www.powershellgallery.com/packages/MicrosoftTeams/8.0.0`), open **Manual Download**, download the `.nupkg` and rename it to `.zip`. Set Runtime version **5.1**.

   Wait until every module shows **Available** before the first **Collect from Purview**. If an import is still *Importing* after 30 minutes, it is stuck: delete that module and import it again.

   *Option B:* import all three the same way. *Browse from gallery* also works, but installs the newest version, which has not been tested with these runbooks.
2. **Runbooks:** **Process automation → Runbooks.** You need `Get-CbxDlpPolicies` and `Get-CbxPowerPlatform`, both **Published**.

   If they are missing (the template was loaded from a file, or Option B):
   - **Import a runbook → Browse for file →** `runbooks/Get-CbxDlpPolicies.ps1`.
   - Runbook type **PowerShell**, Runtime version **5.1**. The name must stay exactly `Get-CbxDlpPolicies`. **Import.**
   - Open it **→ Publish → Yes.**
   - Repeat for `Get-CbxPowerPlatform.ps1`.
3. **Collector certificate** — for the app registration created in 1.3. Create it in **Cloud Shell (Bash)**:
   ```bash
   openssl req -x509 -newkey rsa:2048 -sha256 -days 365 -nodes -keyout cbx.key -out CbxPurviewCert.cer -subj "/CN=CbxPurviewCert"
   openssl pkcs12 -export -inkey cbx.key -in CbxPurviewCert.cer -out CbxPurviewCert.pfx -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1
   ```
   The second command asks for an export password; choose a strong one. The `PBE-SHA1-3DES` options produce a `.pfx` that the Windows-based Automation sandbox can import.

   Use **Manage files → Download** in the Cloud Shell toolbar to download `CbxPurviewCert.cer` and `CbxPurviewCert.pfx`. Then:
   - **Public key → collector app registration:** **App registrations → CBX Purview Collector → Certificates & secrets → Certificates → Upload certificate →** `CbxPurviewCert.cer` **→ Add.** (If you are not an owner of the app registration, hand the `.cer` to the administrator for this step. It is not secret.)
   - **Private key → Automation account:** **Shared resources → Certificates → Add a certificate.**
     - Name **`CbxPurviewCert`** (exactly; the runbook looks for this name).
     - Upload `CbxPurviewCert.pfx` and enter the password.
     - Exportable **No**. **Create.**
   - **Clean up:** in Cloud Shell run `rm cbx.key CbxPurviewCert.pfx`, and delete the downloaded `.pfx` from your computer. The only copy of the private key is now the Automation account's.

   The certificate is valid for one year. Renew it by repeating this step before it expires.

<details>
<summary><strong>Cloud Shell alternative (PowerShell)</strong>: modules, runbooks and certificate in one go</summary>

First upload `Get-CbxDlpPolicies.ps1` and `Get-CbxPowerPlatform.ps1` (from this repository's `runbooks` folder) with **Manage files → Upload** in the Cloud Shell toolbar. They land in your home folder, which is where the block looks for them.

The private key is created in Cloud Shell's temporary folder and deleted when the block finishes. The only copy left is the non-exportable one in the Automation account.

```powershell
& {
    # --- Parameters. Empty TenantId / SubscriptionId: the ones Cloud Shell is signed in to.
    $TenantId          = ''
    $SubscriptionId    = ''
    $ResourceGroup     = 'rg-copilot-blueprint'
    $AutomationAccount = ''       # empty: the only Automation account in the resource group
    $RunbookFolder     = $HOME    # holds the two runbook files (Manage files -> Upload puts them here)
    $RunbookBaseUrl    = ''       # or download them instead: https://raw.githubusercontent.com/MSCopilotAdoption/CopilotBlueprintExplorer/main/runbooks/
    $CollectorAppId    = ''       # collector client ID from 1.3. Empty: skip the certificate
    $RenewCertificate  = $false   # $true: replace an existing CbxPurviewCert (renewal)
    $CertificateDays   = 365

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

    $type = 'Microsoft.Automation/automationAccounts'
    if (-not $AutomationAccount) { $AutomationAccount = az resource list --resource-group $ResourceGroup --resource-type $type --query "[0].name" -o tsv }
    if (-not $AutomationAccount) { throw "No Automation account in '$ResourceGroup'." }
    $aaId, $aaLocation = @(az resource show --resource-group $ResourceGroup --name $AutomationAccount --resource-type $type --query "[id,location]" -o tsv) -split "`t"
    $aa  = "https://management.azure.com$aaId"
    $api = '?api-version=2023-11-01'

    # 1. Modules, pinned to the tested versions and imported one at a time (parallel imports are prone to stalling).
    #    The two small ones are awaited; MicrosoftTeams (22 MB) is started last and left to finish in the background.
    $modules = [ordered]@{ 'ExchangeOnlineManagement' = '3.5.1'; 'Microsoft.Online.SharePoint.PowerShell' = '16.0.27612.12000'; 'MicrosoftTeams' = '8.0.0' }
    foreach ($name in $modules.Keys) {
        $current = try { az rest --method GET --url "$aa/modules/$name$api" --query "[properties.version,properties.provisioningState]" -o tsv 2>$null } catch { '' }
        $version, $state = @($current) -split "`t"
        if ($state -and $state -notin 'Succeeded', 'Failed') { Write-Host "$name is still importing ($state); left alone."; continue }
        if ($version -eq $modules[$name] -and $state -eq 'Succeeded') { continue }
        Invoke-Rest PUT "$aa/modules/$name$api" @{ properties = @{ contentLink = @{ uri = "https://www.powershellgallery.com/api/v2/package/$name/$($modules[$name])" } } }
        if ($name -ne 'MicrosoftTeams') {
            $deadline = (Get-Date).AddMinutes(10)
            do { Start-Sleep -Seconds 15; $state = az rest --method GET --url "$aa/modules/$name$api" --query properties.provisioningState -o tsv }
            while ($state -notin 'Succeeded', 'Failed' -and (Get-Date) -lt $deadline)
            Write-Host "$name import: $state"
        }
    }

    # 2. Runbooks, imported and published as Windows PowerShell 5.1
    foreach ($name in 'Get-CbxDlpPolicies', 'Get-CbxPowerPlatform') {
        $path = Join-Path $RunbookFolder "$name.ps1"
        if ($RunbookBaseUrl) { Invoke-WebRequest -Uri "$RunbookBaseUrl$name.ps1" -OutFile $path }
        if (-not (Test-Path $path)) { throw "Missing $path. Upload it with Manage files -> Upload, or set RunbookBaseUrl." }
        Invoke-Rest PUT "$aa/runbooks/$name$api" @{ location = $aaLocation; properties = @{ runbookType = 'PowerShell'; logProgress = $false; logVerbose = $false } }
        az rest --method PUT --url "$aa/runbooks/$name/draft/content$api" --headers 'Content-Type=text/powershell' --body "@$path" -o none
        az rest --method POST --url "$aa/runbooks/$name/publish$api" -o none
    }

    # 3. Collector certificate: public key to the collector app registration, private key to the Automation account only
    if ($CollectorAppId) {
        $existing = try { az rest --method GET --url "$aa/certificates/CbxPurviewCert$api" --query name -o tsv 2>$null } catch { '' }
        if ($existing -and -not $RenewCertificate) {
            Write-Host 'CbxPurviewCert already exists and was left as it is. Set $RenewCertificate = $true to renew it.'
        } else {
            $dir = Join-Path ([IO.Path]::GetTempPath()) "cbx-cert-$([guid]::NewGuid())"
            New-Item -ItemType Directory -Path $dir | Out-Null
            try {
                openssl req -x509 -newkey rsa:2048 -sha256 -days $CertificateDays -nodes -subj '/CN=CbxPurviewCert' -keyout "$dir/cbx.key" -out "$dir/CbxPurviewCert.cer" 2>$null
                # Password-less, with legacy encryption the Windows-based Automation sandbox can read. The API takes no password.
                openssl pkcs12 -export -inkey "$dir/cbx.key" -in "$dir/CbxPurviewCert.cer" -out "$dir/CbxPurviewCert.pfx" -passout pass: -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1
                az ad app credential reset --id $CollectorAppId --cert "@$dir/CbxPurviewCert.cer" --append -o none
                $thumbprint = (openssl x509 -in "$dir/CbxPurviewCert.cer" -noout -fingerprint -sha1) -replace '^.*=' -replace ':'
                Invoke-Rest PUT "$aa/certificates/CbxPurviewCert$api" @{ name = 'CbxPurviewCert'; properties = @{
                    base64Value = [Convert]::ToBase64String([IO.File]::ReadAllBytes("$dir/CbxPurviewCert.pfx"))
                    thumbprint  = $thumbprint; isExportable = $false; description = 'Purview collector sign-in' } }
            } finally { Remove-Item -Path $dir -Recurse -Force }
        }
    }

    # Status
    foreach ($name in $modules.Keys) { 'Module       {0,-40} {1}' -f $name, (az rest --method GET --url "$aa/modules/$name$api" --query properties.provisioningState -o tsv) }
    foreach ($name in 'Get-CbxDlpPolicies', 'Get-CbxPowerPlatform') { 'Runbook      {0,-40} {1}' -f $name, (az rest --method GET --url "$aa/runbooks/$name$api" --query properties.state -o tsv) }
    if ($CollectorAppId) { 'Certificate  {0,-40} expires {1}' -f 'CbxPurviewCert', (az rest --method GET --url "$aa/certificates/CbxPurviewCert$api" --query properties.expiryTime -o tsv) }
}
```

The block waits for the two small modules (up to 10 minutes each), then starts MicrosoftTeams and moves on without waiting for it. Modules show `Succeeded` once imported; until then they show `Creating` or `ContentValidated`. Run the block again later to see the status. It skips what is done, leaves any import still in progress alone, and leaves the certificate alone unless `$RenewCertificate` is `$true`. After a renewal, remove the old certificate from the collector app registration's **Certificates** list.

</details>

Stage 2 is complete. Tell the Global Administrator.

---

## Stage 3: Global Administrator, in the console

### 3.1 First sign-in, and the read-only walkthrough

Open `https://<web-app-name>.azurewebsites.net` and sign in.

**Two kinds of caller can always sign in, whatever state the access group is in:** anyone holding **Global Administrator**, and anyone on the **Named people** list under Settings → Users. The deployment seeds that list with the **deployer**, from the *Deployer Upn* parameter in step 1.5 — so whoever deployed can sign in immediately, before any access group exists.

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

> **Until 3.2 is done, the access group is not yet being enforced.** The console cannot read group membership, so it cannot check the group, and it admits only Global Administrators and named people. Everyone else is refused with a message saying the check is unavailable. Microsoft Entra is still enforcing **Assignment required** from step 1.2.5, so only people assigned to the enterprise application can obtain a token in the first place.

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
3. Make sure each named person can sign in at all. With **Assignment required = Yes**, they must be assigned to the enterprise application, directly or through the group (step 1.2.5).

The console records each named person's account the first time they sign in, and refuses a different account that later takes over the same UPN. So the complete answer to *who can sign in* is: **anyone in the access group, anyone on this list, or any Global Administrator.**

---

## Updating to a new release

Repeat **2.1** and **2.2** with the new zip your Microsoft contact hands over. Settings, roles, manual answers, scan history and work-item tracking live in the web app's persistent storage (`/home/data`) and survive updates and restarts. The runbooks change rarely; the handover note says when to re-import them from this repository.

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
| **AADSTS50011** redirect URI mismatch | The SPA redirect URI in step 1.6 is missing or different. It must be exactly `https://<web-app-name>.azurewebsites.net` under **Single-page application** (not *Web*). |
| **AADSTS65001** or "Need admin approval" | Admin consent from step 1.2.4 is missing, or `access_as_user` was not added under **My APIs**. |
| "This application has not been configured yet" (`setup_in_progress`) | No access group is set, and the person is not a Global Administrator. Set the group ID at deployment, or under **Settings → Users**. |
| "Access cannot be checked" (`access_gate_unavailable`) | The access-group permissions are missing, or were granted but the web app has not been restarted since (3.3). Or use named people. |
| "You are not a member of the group" (`not_in_access_group`) | Add the person to the access group. Membership is re-checked every 15 minutes. |
| Global Administrator refused at first sign-in or in recovery | The `wids` claim is missing (step 1.2.3). Without it, the console cannot see the Global Administrator role. |
| Pages fail with a federated-identity or token-exchange error | The federated credential (1.6) must name the user-assigned identity **attached to the web app**, and `Cbx__UserAssignedClientId` must be that identity's **Client ID**. |
| Deployment log says *"Couldn't detect a version for the platform 'dotnet' in the repo"* | The zip went through a build step. That happens with Deployment Center → Publish files (new). Deploy with the 2.2 Cloud Shell block instead. |
| Upload fails with **400**, or the app shows "Application Error" | Upload the handed-over zip unchanged (2.1). Check that `SCM_DO_BUILD_DURING_DEPLOYMENT` is `false`, the stack is .NET 8 and the startup command is empty. **Monitoring → Log stream** shows the start-up error. |
| **Collect from Purview** fails | Automation account → **Jobs →** the latest job → **Output / Errors**. Common causes: modules not yet *Available*; certificate not named `CbxPurviewCert`; the role groups in 3.5.3 are missing; or the `.cer` was not uploaded to the collector app registration. |
| **Collect from Power Platform** reports the identity is not registered | Grant **Power Platform management app** (3.5.4). Changes can take a few minutes to reach Power Platform. |

---

## For maintainers

1. The repository root is **this folder**: `azuredeploy.json`, `main.bicep`, `runbooks/`, `README.md`. The public repository never contains `release/` (the zip and its checksum): `.gitignore` excludes it, and both files are handed to each customer directly.
2. `scripts/Build-Package.ps1` in the source repository produces the zip, its checksum, the runbooks and `azuredeploy.json` together. It verifies the zip before writing the checksum, including that it contains no backslash paths. Push the template and runbooks from the same build as the zip you hand over.
3. If the template changes, rebuild it before pushing:
   ```bash
   az bicep build --file main.bicep --outfile azuredeploy.json
   ```
4. **Moving the kit to another repository** (it must be public for the button to work): push these files there, then change the one repository-specific line in this README, the **Deploy to Azure** link in 1.5. The link is the raw address of `azuredeploy.json`, URL-encoded:
   `https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2F<owner>%2F<repo>%2Fmain%2Fazuredeploy.json`

   Nothing else names the repository. The template finds the runbooks next to itself, wherever it is fetched from.
