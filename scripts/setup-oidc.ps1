#Requires -Version 5.1
<#
.SYNOPSIS
    Full OIDC / Workload Identity Federation setup for deploying wif-test
    to Azure App Service via GitHub Actions.

.PARAMETER GitHubOrg
    Your GitHub username or organisation that owns the repository.

.EXAMPLE
    .\setup-oidc.ps1 -GitHubOrg "myusername"
#>
param(
    [Parameter(Mandatory = $true, HelpMessage = "Your GitHub username or organisation name")]
    [string]$GitHubOrg
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# -- Known values --------------------------------------------------------------
$APP_NAME        = ""
$GITHUB_REPO     = ""
$SUBSCRIPTION_ID = ""
$RESOURCE_GROUP  = ""

# -- Helpers -------------------------------------------------------------------
function Write-Step([string]$msg) {
    Write-Host ""
    Write-Host "--------------------------------------------" -ForegroundColor Cyan
    Write-Host "  $msg" -ForegroundColor Cyan
    Write-Host "--------------------------------------------" -ForegroundColor Cyan
}

function Write-Ok([string]$msg)   { Write-Host "  [OK] $msg" -ForegroundColor Green }
function Write-Info([string]$msg) { Write-Host "  [..] $msg" -ForegroundColor Gray  }
function Write-Fail([string]$msg) { Write-Host "  [!!] $msg" -ForegroundColor Red   }

# -- Pre-flight: verify az cli is logged in ------------------------------------
Write-Step "Pre-flight checks"

$account = az account show 2>$null | ConvertFrom-Json
if (-not $account) {
    Write-Fail "Not logged in to Azure CLI. Run 'az login' first."
    exit 1
}
Write-Ok "Logged in as: $($account.user.name)"
Write-Ok "Using subscription: $($account.name) ($SUBSCRIPTION_ID)"

az account set --subscription $SUBSCRIPTION_ID
Write-Ok "Subscription set."

# -- Step 1: App Registration --------------------------------------------------
Write-Step "Step 1 - Creating App Registration '$APP_NAME'"

$existing = az ad app list --display-name $APP_NAME | ConvertFrom-Json
if ($existing.Count -gt 0) {
    Write-Info "App Registration '$APP_NAME' already exists - reusing it."
    $APP = $existing[0]
} else {
    $APP = az ad app create --display-name $APP_NAME | ConvertFrom-Json
    Write-Ok "App Registration created."
}

$CLIENT_ID = $APP.appId
$OBJECT_ID = $APP.id
Write-Ok "CLIENT_ID : $CLIENT_ID"
Write-Ok "OBJECT_ID : $OBJECT_ID"

# -- Step 2: Service Principal -------------------------------------------------
Write-Step "Step 2 - Creating Service Principal"

$existingSP = az ad sp list --filter "appId eq '$CLIENT_ID'" | ConvertFrom-Json
if ($existingSP.Count -gt 0) {
    Write-Info "Service Principal already exists - reusing it."
    $SP = $existingSP[0]
} else {
    $SP = az ad sp create --id $CLIENT_ID | ConvertFrom-Json
    Write-Ok "Service Principal created."
}

$SP_OBJECT_ID = $SP.id
Write-Ok "SP_OBJECT_ID: $SP_OBJECT_ID"

# -- Step 3: Federated Credential ----------------------------------------------
Write-Step "Step 3 - Adding Federated Credential (WIF)"

$SUBJECT = "repo:${GitHubOrg}/${GITHUB_REPO}:ref:refs/heads/main"
Write-Info "Subject: $SUBJECT"

$existingCred = az ad app federated-credential list --id $OBJECT_ID | ConvertFrom-Json |
    Where-Object { $_.subject -eq $SUBJECT }

if ($existingCred) {
    Write-Info "Federated credential for this subject already exists - skipping."
} else {
    $credHash = @{
        name        = "github-actions-main"
        issuer      = "https://token.actions.githubusercontent.com"
        subject     = $SUBJECT
        description = "GitHub Actions OIDC for $GITHUB_REPO main branch"
        audiences   = @("api://AzureADTokenExchange")
    }
    $credParams = $credHash | ConvertTo-Json -Compress

    az ad app federated-credential create --id $OBJECT_ID --parameters $credParams | Out-Null
    Write-Ok "Federated credential created."
}

# -- Step 4: Role assignment ---------------------------------------------------
Write-Step "Step 4 - Assigning Contributor role on the App Service"

$SCOPE = "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Web/sites/$APP_NAME"
Write-Info "Scope: $SCOPE"

$existingRole = az role assignment list --assignee $SP_OBJECT_ID --scope $SCOPE | ConvertFrom-Json |
    Where-Object { $_.roleDefinitionName -eq "Contributor" }

if ($existingRole) {
    Write-Info "Role assignment already exists - skipping."
} else {
    az role assignment create `
        --assignee $SP_OBJECT_ID `
        --role "Contributor" `
        --scope $SCOPE | Out-Null
    Write-Ok "Role assigned."
}

# -- Step 5: Print GitHub Secrets summary --------------------------------------
$TENANT_ID = az account show --query tenantId -o tsv

Write-Step "Done! Add these 3 secrets to your GitHub repository"
Write-Host ""
Write-Host "  Go to: https://github.com/$GitHubOrg/$GITHUB_REPO/settings/secrets/actions" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Secret name              Value" -ForegroundColor White
Write-Host "  -------------------------------------------------------------" -ForegroundColor Gray
Write-Host "  AZURE_CLIENT_ID        = $CLIENT_ID"
Write-Host "  AZURE_TENANT_ID        = $TENANT_ID"
Write-Host "  AZURE_SUBSCRIPTION_ID  = $SUBSCRIPTION_ID"
Write-Host ""
