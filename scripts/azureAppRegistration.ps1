# Replace with your own values
$APP_NAME        = "[APP_NAME]"
$SUBSCRIPTION_ID = "[SUBSCRIPTION_ID]"
$RESOURCE_GROUP  = "[RESOURCE_GROUP]"

# Create the App Registration
$APP       = az ad app create --display-name $APP_NAME | ConvertFrom-Json
$CLIENT_ID = $APP.appId
$OBJECT_ID = $APP.id

# Create a Service Principal linked to the App Registration
$SP           = az ad sp create --id $CLIENT_ID | ConvertFrom-Json
$SP_OBJECT_ID = $SP.id

$TENANT_ID = az account show --query tenantId -o tsv

Write-Host "CLIENT_ID   : $CLIENT_ID"
Write-Host "OBJECT_ID   : $OBJECT_ID"
Write-Host "SP_OBJECT_ID: $SP_OBJECT_ID"
Write-Host "TENANT_ID   : $TENANT_ID"
