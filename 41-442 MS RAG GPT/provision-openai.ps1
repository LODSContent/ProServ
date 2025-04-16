param (
    [string] $subscriptionId,
    [string] $resourceGroup,
    [string] $location,
    [string] $labInstanceId,
    [string] $clientId,
    [string] $clientSecret,
    [string] $tenantId,
    [string] $logFile = "C:\labfiles\progress.log"
)

function Write-Log {
    param ($msg)
    $stamp = (Get-Date).ToString("yyyy-MM-dd HHmmss")
    Add-Content $logFile "[OpenAI] $stamp $msg"
}

Write-Log "Fallback script started."

# Login with service principal if needed
$env:AZURE_CLIENT_ID     = $clientId
$env:AZURE_CLIENT_SECRET = $clientSecret
$env:AZURE_TENANT_ID     = $tenantId
$env:AZD_NON_INTERACTIVE = "true"

try {
    az login --service-principal --username $clientId --password $clientSecret --tenant $tenantId | Out-Null
    az account set --subscription $subscriptionId
    Write-Log "Logged in using service principal."
} catch {
    Write-Log "[ERROR] Failed to log in using service principal. $_"
    exit 1
}

# Set names
$uniqueSuffix = (Get-Date -Format "yyyyMMddHHmmss")
$openAiName = "oai0-$labInstanceId-$uniqueSuffix"

# Provision OpenAI
Write-Log "Creating Azure OpenAI resource: $openAiName"

$createResult = az cognitiveservices account create `
    --name $openAiName `
    --resource-group $resourceGroup `
    --location $location `
    --sku S0 `
    --kind OpenAI `
    --yes `
    --custom-domain "" `
    --api-properties "{}" `
    --properties "{}" `
    --output none 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Log "[ERROR] Failed to create Azure OpenAI resource."
    Write-Log "$createResult"
    exit 1
}

Write-Log "OpenAI resource created."

# Wait for provisioning to complete
$provisioningState = ""
$attempts = 0
do {
    $provisioningState = az cognitiveservices account show `
        --name $openAiName `
        --resource-group $resourceGroup `
        --query "provisioningState" -o tsv
    Write-Log "Provisioning state: $provisioningState (attempt $attempts)"
    Start-Sleep -Seconds 15
    $attempts++
} while ($provisioningState -ne "Succeeded" -and $attempts -lt 10)

if ($provisioningState -ne "Succeeded") {
    Write-Log "[ERROR] Azure OpenAI provisioning failed or timed out."
    exit 1
}

Write-Log "Provisioning succeeded. Starting model deployments..."

# Deploy chat model
az cognitiveservices account deployment create `
  --name $openAiName `
  --resource-group $resourceGroup `
  --deployment-name "chat" `
  --model-format OpenAI `
  --model-name "gpt-35-turbo" `
  --model-version "0613" `
  --sku-name "standard" `
  --scale-type "Standard" | Out-Null

Write-Log "Chat model deployed."

# Deploy embedding model
az cognitiveservices account deployment create `
  --name $openAiName `
  --resource-group $resourceGroup `
  --deployment-name "text-embedding" `
  --model-format OpenAI `
  --model-name "text-embedding-ada-002" `
  --model-version "2" `
  --sku-name "standard" `
  --scale-type "Standard" | Out-Null

Write-Log "Embedding model deployed."
Write-Log "Fallback script completed successfully."

