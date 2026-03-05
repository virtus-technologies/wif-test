#Requires -Version 5.1
<#
.SYNOPSIS
    Deploy wif-test directly from your local machine to Azure App Service.
    No CI/CD, no publish profile - just az login and run this script.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$APP_NAME       = "[APP_NAME]"
$RESOURCE_GROUP = "[RESOURCE_GROUP]"
$ZIP_FILE       = "deploy.zip"

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

# -- Pre-flight ----------------------------------------------------------------
Write-Step "Pre-flight checks"

$account = az account show 2>$null | ConvertFrom-Json
if (-not $account) {
    Write-Fail "Not logged in. Run 'az login' first."
    exit 1
}
Write-Ok "Logged in as: $($account.user.name)"

# -- Install production dependencies ------------------------------------------
Write-Step "Installing production dependencies"
npm ci --omit=dev
if ($LASTEXITCODE -ne 0) {
    Write-Fail "npm ci failed."
    exit 1
}
Write-Ok "Dependencies installed."

# -- Build zip package ---------------------------------------------------------
Write-Step "Creating deployment package"

$exclude = @(
    ".git", ".github", "publish_profile",
    "*.ps1", "*.sh", "*.zip",
    "README.md", ".gitignore"
)

if (Test-Path $ZIP_FILE) { Remove-Item $ZIP_FILE -Force }

$items = Get-ChildItem -Path . -Force |
    Where-Object { $_.Name -notin $exclude }

Compress-Archive -Path $items.FullName -DestinationPath $ZIP_FILE
$sizeMB = [math]::Round((Get-Item $ZIP_FILE).Length / 1MB, 2)
Write-Ok "Package created: $ZIP_FILE ($sizeMB MB)"

# -- Deploy --------------------------------------------------------------------
Write-Step "Deploying to Azure App Service '$APP_NAME'"
Write-Info "This may take a minute..."

az webapp deploy `
    --resource-group $RESOURCE_GROUP `
    --name $APP_NAME `
    --src-path $ZIP_FILE `
    --type zip `
    --async false

if ($LASTEXITCODE -ne 0) {
    Write-Fail "Deployment failed."
    Remove-Item $ZIP_FILE -Force
    exit 1
}

# -- Cleanup -------------------------------------------------------------------
Remove-Item $ZIP_FILE -Force
Write-Ok "Temporary zip removed."

# -- Done ----------------------------------------------------------------------
$url = "https://$APP_NAME.azurewebsites.net"
Write-Step "Deployment complete"
Write-Host ""
Write-Host "  App URL : $url" -ForegroundColor Yellow
Write-Host "  Health  : $url/health" -ForegroundColor Yellow
Write-Host ""
