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

az login --service-principal `
    --username $clientId `
    --password $clientSecret `
    --tenant $tenantId | Out-Null

az account set --subscription $subscriptionId | Out-Null

$openAiName = "oai0-$labInstanceId"
$bastionKvName = "bastionkv-$($labInstanceId.ToLower())"

# === Step 1: Purge soft-deleted OpenAI ===
try {
    $deletedOpenAIs = az cognitiveservices account list-deleted `
        --location $location `
        --query "[?name=='$openAiName']" -o json | ConvertFrom-Json

    if ($deletedOpenAIs.Count -gt 0) {
        foreach ($deleted in $deletedOpenAIs) {
            Write-Log "Purging soft-deleted Azure OpenAI: $($deleted.name)"
            az cognitiveservices account purge `
                --location $deleted.location `
                --name $deleted.name | Out-Null
            Write-Log "Purged: $($deleted.name)"
        }
    } else {
        Write-Log "No soft-deleted Azure OpenAI resources found."
    }
} catch {
    Write-Log "[WARNING] Failed to check or purge soft-deleted Azure OpenAI: $_"
}

# === Step 2: Purge soft-deleted Key Vault ===
try {
    $deletedKvs = az keyvault list-deleted `
        --query "[?name=='$bastionKvName']" -o json | ConvertFrom-Json

    if ($deletedKvs.Count -gt 0) {
        foreach ($deleted in $deletedKvs) {
            Write-Log "Purging soft-deleted Key Vault: $($deleted.name)"
            az keyvault purge --name $deleted.name | Out-Null
            Write-Log "Purged Key Vault: $($deleted.name)"
        }
    } else {
        Write-Log "No soft-deleted Key Vault resources found."
    }
} catch {
    Write-Log "[WARNING] Failed to check or purge soft-deleted Key Vault: $_"
}

# === Step 3: Create OpenAI ===
try {
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
} catch {
    Write-Log "[ERROR] Failed to create OpenAI resource: $_"
}

# === Step 4: Confirm Provisioning ===
$maxAttempts = 15
$state = ""
for ($i = 1; $i -le $maxAttempts; $i++) {
    Start-Sleep -Seconds 12
    try {
        $state = az cognitiveservices account show `
            --name $openAiName `
            --resource-group $resourceGroup `
            --query "provisioningState" -o tsv
        Write-Log "Provisioning state of $openAiName: $state (Attempt $i)"
        if ($state -eq "Succeeded") {
            Write-Log "Azure OpenAI resource is ready."
            break
        }
    } catch {
        Write-Log "[WARNING] Failed to get provisioning state: $_"
    }
}

if ($state -ne "Succeeded") {
    Write-Log "[ERROR] Azure OpenAI resource $openAiName failed to reach 'Succeeded' state. Final state: $state"
}

Write-Log "Fallback OpenAI provision script executed successfully."
