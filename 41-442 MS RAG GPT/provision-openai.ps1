param (
    [string]$resourceGroup,
    [string]$location,
    [string]$labInstanceId,
    [string]$subscriptionId
)

$logFile = "C:\labfiles\progress.log"
function Write-Log($msg) {
    $stamp = (Get-Date).ToString("yyyy-MM-dd HHmmss")
    Add-Content $logFile "[OPENAI] $stamp $msg"
}

Write-Log "Started OpenAI provisioning."

# Name format
$openAiName = "oai0-$labInstanceId"

# Check if it already exists
$existing = az cognitiveservices account show `
    --name $openAiName `
    --resource-group $resourceGroup `
    --query "name" -o tsv 2>$null

if (-not $existing) {
    Write-Log "Creating Azure OpenAI resource: $openAiName"

    az cognitiveservices account create `
        --name $openAiName `
        --resource-group $resourceGroup `
        --location $location `
        --kind OpenAI `
        --sku S0 `
        --yes `
        --custom-domain $openAiName `
        --properties "{'DisableLocalAuth':'false'}" `
        --capabilities EnableAzureOpenAI `
        --query "id" -o tsv | Out-Null

    Write-Log "Creation requested. Waiting for provisioning to complete..."
} else {
    Write-Log "Azure OpenAI resource already exists: $openAiName"
}

# Wait for provisioning state
$attempts = 0
do {
    $state = az cognitiveservices account show `
        --name $openAiName `
        --resource-group $resourceGroup `
        --query "provisioningState" -o tsv
    Write-Log "Provisioning state: $state"
    Start-Sleep -Seconds 10
    $attempts++
} while ($state -ne "Succeeded" -and $attempts -lt 15)

if ($state -ne "Succeeded") {
    Write-Log "[ERROR] OpenAI resource did not reach 'Succeeded'. Aborting model deployment."
    exit 1
}

# Deploy models if needed
$deployments = az cognitiveservices account deployment list `
    --name $openAiName `
    --resource-group $resourceGroup `
    --query "[].name" -o tsv

if ($deployments -notmatch "chat") {
    Write-Log "Deploying chat model..."
    az cognitiveservices account deployment create `
        --name $openAiName `
        --resource-group $resourceGroup `
        --deployment-name "chat" `
        --model-format OpenAI `
        --model-name "gpt-35-turbo" `
        --model-version "0613" `
        --sku-name "standard" `
        --scale-type "Standard" | Out-Null
}

if ($deployments -notmatch "text-embedding") {
    Write-Log "Deploying text-embedding model..."
    az cognitiveservices account deployment create `
        --name $openAiName `
        --resource-group $resourceGroup `
        --deployment-name "text-embedding" `
        --model-format OpenAI `
        --model-name "text-embedding-ada-002" `
        --model-version "2" `
        --sku-name "standard" `
        --scale-type "Standard" | Out-Null
}

# Update .env
$envFile = "$HOME\gpt-rag-deploy\.azure\dev-lab\.env"
$endpoint = az cognitiveservices account show `
    --name $openAiName `
    --resource-group $resourceGroup `
    --query "properties.endpoint" -o tsv

Write-Log "Updating .env with Azure OpenAI info."

function Set-Or-Update-Key($lines, $key, $value) {
    if ($lines -match "^$key=") {
        return $lines -replace "^$key=.*", "$key=$value"
    } else {
        return $lines + "`n$key=$value"
    }
}

if (Test-Path $envFile) {
    $lines = Get-Content $envFile
    $lines = Set-Or-Update-Key $lines "AZURE_OPENAI_NAME" $openAiName
    $lines = Set-Or-Update-Key $lines "AZURE_OPENAI_ENDPOINT" $endpoint
    $lines | Set-Content $envFile
    Write-Log ".env updated with AZURE_OPENAI_NAME and AZURE_OPENAI_ENDPOINT"
} else {
    Write-Log "[WARNING] .env file not found. Skipping update."
}

Write-Log "Azure OpenAI provisioning complete."
