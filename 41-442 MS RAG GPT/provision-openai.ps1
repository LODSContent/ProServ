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
    param ([string]$msg)
    $stamp = (Get-Date).ToString("yyyy-MM-dd HHmmss")
    Add-Content $logFile "[INFO] $stamp $msg"
}

Write-Log "=== Starting fallback OpenAI provisioning script ==="

# Login with service principal
az login --service-principal `
    --username $clientId `
    --password $clientSecret `
    --tenant $tenantId | Out-Null

az account set --subscription $subscriptionId | Out-Null

# Step 1: Purge soft-deleted Azure OpenAI
$openAiName = "oai0-$labInstanceId"
$deletedOpenAIs = az cognitiveservices account list-deleted `
    --location $location `
    --query "[?name=='$openAiName']" -o json | ConvertFrom-Json

if ($deletedOpenAIs.Count -gt 0) {
    foreach ($deleted in $deletedOpenAIs) {
        Write-Log "Purging soft-deleted Azure OpenAI resource: $($deleted.name)"
        az cognitiveservices account purge `
            --location $deleted.location `
            --name $deleted.name | Out-Null
        Write-Log "Purged Azure OpenAI: $($deleted.name)"
    }
}

# Step 2: Purge soft-deleted Key Vault bastionkv-*
$bastionKvName = "bastionkv-$($labInstanceId.ToLower())"
$deletedKvs = az keyvault list-deleted `
    --query "[?name=='$bastionKvName']" -o json | ConvertFrom-Json

if ($deletedKvs.Count -gt 0) {
    foreach ($deleted in $deletedKvs) {
        Write-Log "Purging soft-deleted Key Vault: $($deleted.name)"
        az keyvault purge --name $deleted.name | Out-Null
        Write-Log "Purged Key Vault: $($deleted.name)"
    }
}

# Step 3: Create Azure OpenAI resource
Write-Log "Creating Azure OpenAI resource: $openAiName"

az cognitiveservices account create `
    --name $openAiName `
    --resource-group $resourceGroup `
    --location $location `
    --kind OpenAI `
    --sku S0 `
    --custom-domain $null `
    --yes `
    --assign-identity `
    --api-properties "enableManagedIdentity=true" `
    --properties '{}' `
    --tags "env=lab" `
    --output none

Write-Log "Azure OpenAI resource created: $openAiName"

# Step 4: Poll until 'Succeeded'
$maxAttempts = 15
for ($i = 1; $i -le $maxAttempts; $i++) {
    Start-Sleep -Seconds 12
    $state = az cognitiveservices account show `
        --name $openAiName `
        --resource-group $resourceGroup `
        --query "provisioningState" -o tsv

    Write-Log ("Provisioning state of $openAiName: $state (Attempt $i)")

    if ($state -eq "Succeeded") {
        Write-Log "Azure OpenAI resource reached 'Succeeded' state."
        break
    }
}

if ($state -ne "Succeeded") {
    Write-Log "[ERROR] Azure OpenAI resource $openAiName failed to reach 'Succeeded' state. Current state: $state"
}

Write-Log "Fallback OpenAI provision script executed successfully."
