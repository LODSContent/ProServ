param (
    [string]$subscriptionId,
    [string]$resourceGroup,
    [string]$location,
    [string]$labInstanceId,
    [string]$clientId,
    [string]$clientSecret,
    [string]$tenantId,
    [string]$logFile = "C:\labfiles\progress.log"
)

function Write-Log {
    param ([string]$msg)
    $stamp = (Get-Date).ToString("yyyy-MM-dd HHmmss")
    Add-Content $logFile "[INFO] $stamp $msg"
}

Write-Log "=== Starting fallback OpenAI provisioning script ==="

$openAiName = "oai0-$labInstanceId"
$aiName     = "ai0-$labInstanceId"

# 1) Purge soft-deleted names if present
$purgeList = @($openAiName, $aiName)
foreach ($name in $purgeList) {
    try {
        $deletedResources = az cognitiveservices account list-deleted `
            --location $location `
            --query "[?name=='$name']" -o json | ConvertFrom-Json
        foreach ($res in $deletedResources) {
            Write-Log "Purging soft-deleted resource: $($res.name)"
            az cognitiveservices account purge `
                --location $res.properties.location `
                --name $res.name `
                --resource-group $res.properties.resourceGroup | Out-Null
        }
    } catch {
        Write-Log "[WARNING] No soft-deleted resource found for $name or failed to purge."
    }
}

# 2) Create OpenAI resource
try {
    Write-Log "Creating Azure OpenAI resource: $openAiName"

    az cognitiveservices account create `
        --name $openAiName `
        --resource-group $resourceGroup `
        --kind OpenAI `
        --sku S0 `
        --location $location `
        --yes `
        --assign-identity `
        --custom-domain "" `
        --api-properties "{}" `
        --tags "lab=$labInstanceId" `
        --properties "{}" `
        --public-network-access Enabled `
        --only-show-errors | Out-Null

    Write-Log "Azure OpenAI resource created: $openAiName"
} catch {
    Write-Log "[ERROR] Failed to create Azure OpenAI resource: $_"
    return
}

# 3) Wait for provisioning state = Succeeded
$maxAttempts = 15
$attempt = 0
$state = ""
do {
    $state = az cognitiveservices account show `
        --name $openAiName `
        --resource-group $resourceGroup `
        --query "provisioningState" -o tsv
    Write-Log "Provisioning state of ${openAiName}: $state (Attempt $($attempt + 1))"
    Start-Sleep -Seconds 10
    $attempt++
} while ($state -ne "Succeeded" -and $attempt -lt $maxAttempts)

if ($state -ne "Succeeded") {
    Write-Log "[ERROR] Azure OpenAI resource $openAiName failed to reach 'Succeeded' state. Current state: $state"
    return
}

# 4) Deploy models if not already present
Write-Log "Checking model deployments for $openAiName..."
$existingDeployments = az cognitiveservices account deployment list `
    --name $openAiName `
    --resource-group $resourceGroup `
    --query "[].name" -o tsv

if ($existingDeployments -notmatch "chat") {
    Write-Log "Deploying GPT-35 Turbo model..."
    az cognitiveservices account deployment create `
        --name $openAiName `
        --resource-group $resourceGroup `
        --deployment-name "chat" `
        --model-format OpenAI `
        --model-name "gpt-35-turbo" `
        --model-version "0613" `
        --sku-name "standard" `
        --scale-type "Standard" | Out-Null
} else {
    Write-Log "Chat model already deployed."
}

if ($existingDeployments -notmatch "text-embedding") {
    Write-Log "Deploying Ada Embedding model..."
    az cognitiveservices account deployment create `
        --name $openAiName `
        --resource-group $resourceGroup `
        --deployment-name "text-embedding" `
        --model-format OpenAI `
        --model-name "text-embedding-ada-002" `
        --model-version "2" `
        --sku-name "standard" `
        --scale-type "Standard" | Out-Null
} else {
    Write-Log "Embedding model already deployed."
}

Write-Log "=== Fallback OpenAI provisioning script complete ==="
