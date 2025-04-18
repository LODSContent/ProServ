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

# Login
az login --service-principal --username $clientId --password $clientSecret --tenant $tenantId | Out-Null
az account set --subscription $subscriptionId | Out-Null

# Names
$openAiName = "oai0-$labInstanceId"
$aiSvcName  = "ai0-$labInstanceId"
$bastionKv   = "bastionkv-$($labInstanceId.ToLower())"

function Purge-DeletedAccount($name, $type, $cmdListDeleted, $cmdPurge) {
    $deleted = & $cmdListDeleted | ConvertFrom-Json
    if ($deleted.Count -gt 0) {
        Write-Log "Purging soft-deleted $type: $name"
        foreach ($d in $deleted) {
            & $cmdPurge
            Write-Log "Purged $type: $($d.name)"
        }
    } else {
        Write-Log "No soft-deleted $type named $name"
    }
}

# 1) Purge soft-deleted OpenAI
Purge-DeletedAccount `
    -name $openAiName `
    -type "Azure OpenAI" `
    -cmdListDeleted "az cognitiveservices account list-deleted --location $location --query `[?name=='$openAiName']` -o json" `
    -cmdPurge        "az cognitiveservices account purge --location $location --name $openAiName"

# 2) Purge soft-deleted Azure AI Services
Purge-DeletedAccount `
    -name $aiSvcName `
    -type "Azure AI Services" `
    -cmdListDeleted "az cognitiveservices account list-deleted --location $location --query `[?name=='$aiSvcName']` -o json" `
    -cmdPurge        "az cognitiveservices account purge --location $location --name $aiSvcName"

# 3) Purge soft-deleted bastion Key Vault
Purge-DeletedAccount `
    -name $bastionKv `
    -type "Key Vault" `
    -cmdListDeleted "az keyvault list-deleted --query `[?name=='$bastionKv']` -o json" `
    -cmdPurge        "az keyvault purge --name $bastionKv"

# Attempt create & poll up to 3 times
$attemptCycle = 0
do {
    $attemptCycle++
    Write-Log "=== Fallback provisioning cycle #$attemptCycle ==="

    # 4) Create OpenAI resource
    Write-Log "Creating Azure OpenAI resource: $openAiName"
    az cognitiveservices account create `
        --name $openAiName `
        --resource-group $resourceGroup `
        --location $location `
        --kind OpenAI `
        --sku S0 `
        --yes `
        --assign-identity `
        --api-properties "enableManagedIdentity=true" `
        --tags "env=lab" `
        --output none

    Write-Log "Azure OpenAI create API returned; polling for provisioningState..."

    # 5) Poll up to 15 times for Succeeded
    $state = ""
    for ($i=1; $i -le 15; $i++) {
        Start-Sleep -Seconds 12
        $state = az cognitiveservices account show `
            --name $openAiName `
            --resource-group $resourceGroup `
            --query provisioningState -o tsv
        Write-Log "[$i/15] ProvisioningState of $openAiName => $state"
        if ($state -eq "Succeeded") { break }
    }

    if ($state -eq "Succeeded") {
        Write-Log "✅ $openAiName reached 'Succeeded'"
        break
    } else {
        Write-Log "⚠️ $openAiName did not reach 'Succeeded' (last state: $state)"
    }

} while ($attemptCycle -lt 3)

if ($state -ne "Succeeded") {
    Write-Log "[ERROR] Failed to provision $openAiName after $attemptCycle cycles."
    exit 1
}

Write-Log "Fallback OpenAI provisioning script completed successfully."
