#Requires -Version 5.1
<#
.SYNOPSIS
    GCP-side setup for Workload Identity Federation with Azure.
    Creates the WIF pool, OIDC provider, service account, and IAM bindings
    needed for an Azure App Service to access Google Cloud Storage.

.PARAMETER GcpProjectId
    GCP project ID. Default: foca-452520

.PARAMETER AzureTenantId
    Azure AD tenant ID. Default: aa2c39aa-5846-4182-aa05-453393e1d777

.PARAMETER AzureMiObjectId
    Object ID of the Azure Managed Identity. Default: 0305fdcd-7423-42c1-97a9-8ece691709b9

.PARAMETER AzureAppClientId
    Client ID (appId) of the Azure App Registration.
    Used as the allowed audience (api://<CLIENT_ID>) in the WIF provider.
    Default: f49b830e-13f2-4860-9c95-c41d18cecb9b

.PARAMETER PoolId
    Workload Identity Pool ID. Default: azure-wif-pool

.PARAMETER ProviderId
    WIF Provider ID. Default: azure-wif-provider

.PARAMETER ServiceAccountName
    GCP service account name. Default: wif-azure-reader

.PARAMETER BucketName
    GCS bucket to grant read access to. Default: foca-assets

.EXAMPLE
    .\setup-gcp-wif.ps1

.EXAMPLE
    .\setup-gcp-wif.ps1 -GcpProjectId "other-project" -AzureTenantId "xxxx" -AzureMiObjectId "yyyy" -AzureAppClientId "zzzz"
#>
param(
    [string]$GcpProjectId     = "[GCP_PROJECT_ID]",
    [string]$AzureTenantId    = "[AZURE_TENANT_ID]",
    [string]$AzureMiObjectId  = "[AZURE_MI_OBJECT_ID]",
    [string]$AzureAppClientId = "[AZURE_APP_CLIENT_ID]",

    [string]$PoolId             = "[POOL_ID]",
    [string]$ProviderId         = "[PROVIDER_ID]",
    [string]$ServiceAccountName = "[SERVICE_ACCOUNT_NAME]",
    [string]$BucketName         = "[BUCKET_NAME]"
)

$ErrorActionPreference = "Stop"

# -- Transcript (log file) -----------------------------------------------------
$LogDir  = Join-Path $PSScriptRoot "..\logs"
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }
$LogFile = Join-Path $LogDir ("setup-gcp-wif_{0}.log" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
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

function Assert-GcloudSuccess([string]$context) {
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "gcloud command failed at: $context (exit code $LASTEXITCODE)"
        Stop-Transcript
        exit $LASTEXITCODE
    }
}

# -- Pre-flight: verify gcloud is logged in ------------------------------------
Write-Step "Pre-flight checks"

$gcloudAccount = gcloud auth list --filter="status:ACTIVE" --format="value(account)" 2>$null
if (-not $gcloudAccount) {
    Write-Fail "Not logged in to gcloud. Run 'gcloud auth login' first."
    Stop-Transcript
    exit 1
}
Write-Ok "Logged in as: $gcloudAccount"

$GCP_PROJECT_NUMBER = gcloud projects describe $GcpProjectId --format="value(projectNumber)" 2>$null
Assert-GcloudSuccess "projects describe"
Write-Ok "Project: $GcpProjectId (number: $GCP_PROJECT_NUMBER)"

$SA_EMAIL = "$ServiceAccountName@$GcpProjectId.iam.gserviceaccount.com"
$AZURE_TOKEN_AUDIENCE = "api://$AzureAppClientId"
$WIF_PRINCIPAL = "principal://iam.googleapis.com/projects/$GCP_PROJECT_NUMBER/locations/global/workloadIdentityPools/$PoolId/subject/$AzureMiObjectId"

Write-Info "Azure token audience (allowed_audiences): $AZURE_TOKEN_AUDIENCE"

# -- Step 1: Workload Identity Pool -------------------------------------------
Write-Step "Step 1 - Creating Workload Identity Pool '$PoolId'"

$ErrorActionPreference = "Continue"
$existingPool = gcloud iam workload-identity-pools describe $PoolId --location="global" --project=$GcpProjectId 2>&1
$ErrorActionPreference = "Stop"
if ($LASTEXITCODE -eq 0) {
    Write-Info "Pool '$PoolId' already exists - skipping."
} else {
    gcloud iam workload-identity-pools create $PoolId `
        --location="global" `
        --display-name="Azure WIF Pool" `
        --project=$GcpProjectId
    Assert-GcloudSuccess "workload-identity-pools create"
    Write-Ok "Pool created."
}

# -- Step 2: OIDC Provider ----------------------------------------------------
Write-Step "Step 2 - Creating OIDC Provider '$ProviderId'"

$ErrorActionPreference = "Continue"
$existingProvider = gcloud iam workload-identity-pools providers describe $ProviderId `
    --location="global" `
    --workload-identity-pool=$PoolId `
    --project=$GcpProjectId 2>&1
$ErrorActionPreference = "Stop"
if ($LASTEXITCODE -eq 0) {
    Write-Info "Provider '$ProviderId' already exists - skipping."
} else {
    gcloud iam workload-identity-pools providers create-oidc $ProviderId `
        --location="global" `
        --workload-identity-pool=$PoolId `
        --issuer-uri="https://sts.windows.net/$AzureTenantId/" `
        --allowed-audiences=$AZURE_TOKEN_AUDIENCE `
        --attribute-mapping="google.subject=assertion.sub" `
        --attribute-condition="assertion.sub == '$AzureMiObjectId'" `
        --project=$GcpProjectId
    Assert-GcloudSuccess "workload-identity-pools providers create-oidc"
    Write-Ok "Provider created."
}

# -- Step 3: Service Account --------------------------------------------------
Write-Step "Step 3 - Creating Service Account '$ServiceAccountName'"

$ErrorActionPreference = "Continue"
$existingSA = gcloud iam service-accounts describe $SA_EMAIL --project=$GcpProjectId 2>&1
$ErrorActionPreference = "Stop"
if ($LASTEXITCODE -eq 0) {
    Write-Info "Service account '$SA_EMAIL' already exists - skipping."
} else {
    gcloud iam service-accounts create $ServiceAccountName `
        --display-name="WIF Azure Reader" `
        --project=$GcpProjectId
    Assert-GcloudSuccess "iam service-accounts create"
    Write-Ok "Service account created."
}

# -- Step 4: Grant workloadIdentityUser on the SA -----------------------------
Write-Step "Step 4 - Granting workloadIdentityUser to Azure MI on the SA"

Write-Info "Member: $WIF_PRINCIPAL"
gcloud iam service-accounts add-iam-policy-binding $SA_EMAIL `
    --role="roles/iam.workloadIdentityUser" `
    --member=$WIF_PRINCIPAL `
    --project=$GcpProjectId `
    --condition=None
Assert-GcloudSuccess "service-accounts add-iam-policy-binding (workloadIdentityUser)"
Write-Ok "workloadIdentityUser binding added."

# -- Step 5: Grant storage.objectViewer on the bucket -------------------------
Write-Step "Step 5 - Granting storage.objectViewer on bucket '$BucketName'"

gcloud storage buckets add-iam-policy-binding "gs://$BucketName" `
    --role="roles/storage.objectViewer" `
    --member="serviceAccount:$SA_EMAIL"
Assert-GcloudSuccess "storage buckets add-iam-policy-binding"
Write-Ok "storage.objectViewer binding added."

# -- Summary -------------------------------------------------------------------
Write-Step "Done! Add these environment variables to your Azure App Service"
Write-Host ""
Write-Host "  az webapp config appsettings set --name <APP_NAME> --resource-group <RG> --settings \" -ForegroundColor Yellow
Write-Host "    GCP_PROJECT_NUMBER=$GCP_PROJECT_NUMBER \" -ForegroundColor Yellow
Write-Host "    GCP_PROJECT_ID=$GcpProjectId \" -ForegroundColor Yellow
Write-Host "    GCP_WIF_POOL_ID=$PoolId \" -ForegroundColor Yellow
Write-Host "    GCP_WIF_PROVIDER_ID=$ProviderId \" -ForegroundColor Yellow
Write-Host "    GCP_SERVICE_ACCOUNT_EMAIL=$SA_EMAIL \" -ForegroundColor Yellow
Write-Host "    GCS_BUCKET_NAME=$BucketName \" -ForegroundColor Yellow
Write-Host "    AZURE_WIF_APP_ID_URI=$AZURE_TOKEN_AUDIENCE" -ForegroundColor Yellow
Write-Host ""

Stop-Transcript
Write-Host "Full log saved to: $LogFile" -ForegroundColor Gray
