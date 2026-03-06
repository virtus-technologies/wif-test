#Requires -Version 5.1
<#
.SYNOPSIS
    Azure-side setup for Workload Identity Federation with Google Cloud.
    Enables Managed Identity on the App Service and creates an App Registration
    whose Application ID URI (api://<CLIENT_ID>) is used as the audience for
    the Azure token that GCP will validate.

.PARAMETER AppName
    Azure App Service name. Default: wif-test

.PARAMETER ResourceGroup
    Azure resource group. Default: virtus-dev

.PARAMETER AppRegDisplayName
    Display name for the new App Registration. Default: wif-test-gcp

.EXAMPLE
    .\setup-azure-wif.ps1

.EXAMPLE
    .\setup-azure-wif.ps1 -AppName "my-app" -ResourceGroup "my-rg"
#>
param(
    [string]$AppName           = "[APP_NAME]",
    [string]$ResourceGroup     = "[RESOURCE_GROUP]",
    [string]$AppRegDisplayName = "[APP_REG_DISPLAY_NAME]"
)

$ErrorActionPreference = "Stop"

# -- Transcript (log file) -----------------------------------------------------
$LogDir  = Join-Path $PSScriptRoot "..\logs"
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }
$LogFile = Join-Path $LogDir ("setup-azure-wif_{0}.log" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
Start-Transcript -Path $LogFile -Append
Write-Host "Logging to: $LogFile"

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

function Assert-AzSuccess([string]$context) {
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "Azure CLI command failed at: $context (exit code $LASTEXITCODE)"
        Stop-Transcript
        exit $LASTEXITCODE
    }
}

# -- Pre-flight: verify az cli is logged in ------------------------------------
Write-Step "Pre-flight checks"

$account = az account show 2>$null | ConvertFrom-Json
if (-not $account) {
    Write-Fail "Not logged in to Azure CLI. Run 'az login' first."
    Stop-Transcript
    exit 1
}
Write-Ok "Logged in as: $($account.user.name)"
Write-Ok "Subscription: $($account.name)"

# -- Step 1: Enable System-Assigned Managed Identity ---------------------------
Write-Step "Step 1 - Enabling System-Assigned Managed Identity on '$AppName'"

$existingIdentity = az webapp identity show --name $AppName --resource-group $ResourceGroup 2>$null | ConvertFrom-Json
if ($existingIdentity -and $existingIdentity.principalId) {
    Write-Info "Managed Identity is already enabled - reusing it."
    $MI_OBJECT_ID = $existingIdentity.principalId
} else {
    $identity = az webapp identity assign --name $AppName --resource-group $ResourceGroup | ConvertFrom-Json
    Assert-AzSuccess "webapp identity assign"
    $MI_OBJECT_ID = $identity.principalId
    Write-Ok "Managed Identity enabled."
}

Write-Ok "MI_OBJECT_ID: $MI_OBJECT_ID"

# -- Step 2: App Registration -------------------------------------------------
Write-Step "Step 2 - Creating App Registration '$AppRegDisplayName'"

$existing = az ad app list --display-name $AppRegDisplayName | ConvertFrom-Json
if ($existing.Count -gt 0) {
    Write-Info "App Registration '$AppRegDisplayName' already exists - reusing it."
    $APP = $existing[0]
} else {
    $APP = az ad app create --display-name $AppRegDisplayName | ConvertFrom-Json
    Assert-AzSuccess "ad app create"
    Write-Ok "App Registration created."
}

$CLIENT_ID = $APP.appId
$OBJECT_ID = $APP.id
Write-Ok "CLIENT_ID : $CLIENT_ID"
Write-Ok "OBJECT_ID : $OBJECT_ID"

# -- Step 3: Set the Application ID URI ---------------------------------------
Write-Step "Step 3 - Setting Application ID URI"

$APP_ID_URI = "api://$CLIENT_ID"
Write-Info "Target URI: $APP_ID_URI"

$currentUris = $APP.identifierUris
if ($currentUris -contains $APP_ID_URI) {
    Write-Info "Application ID URI is already set - skipping."
} else {
    az ad app update --id $OBJECT_ID --identifier-uris $APP_ID_URI
    Assert-AzSuccess "ad app update --identifier-uris"
    Write-Ok "Application ID URI set."
}

# Verify
$updatedApp = az ad app show --id $OBJECT_ID --query "identifierUris" -o json
Write-Ok "Current identifierUris: $updatedApp"

# -- Step 4: Print summary ----------------------------------------------------
$TENANT_ID = az account show --query tenantId -o tsv

Write-Step "Done! Values for the next steps"
Write-Host ""
Write-Host "  Use these when running setup-gcp-wif.ps1 and configuring App Service env vars:" -ForegroundColor Yellow
Write-Host ""
Write-Host "  MI_OBJECT_ID       = $MI_OBJECT_ID"
Write-Host "  APP_REG_CLIENT_ID  = $CLIENT_ID"
Write-Host "  APP_ID_URI         = $APP_ID_URI"
Write-Host "  AZURE_TENANT_ID    = $TENANT_ID"
Write-Host ""
Write-Host "  Pass -AzureAppClientId `"$CLIENT_ID`" to setup-gcp-wif.ps1" -ForegroundColor Yellow
Write-Host ""

Stop-Transcript
Write-Host "Full log saved to: $LogFile" -ForegroundColor Gray
