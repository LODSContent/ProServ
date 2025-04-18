# gpt-rag.ps1 (Updated: Pre-provision OpenAI, handle soft-deleted conflicts, confirm readiness, purge & retry failed resources)

$logFile = "C:\labfiles\progress.log"
$bicepErrorLog = "C:\labfiles\bicep_errors.log"

function Write-Log($msg) {
    $stamp = (Get-Date).ToString("yyyy-MM-dd HHmmss")
    Add-Content $logFile "[INFO] $stamp $msg"
}

Write-Log "Script started in GitHub version."

# 1) Pull environment variables
$AdminUserName  = $env:LAB_ADMIN_USERNAME
$AdminPassword  = $env:LAB_ADMIN_PASSWORD
$tenantId       = $env:LAB_TENANT_ID
$subscriptionId = $env:LAB_SUBSCRIPTION_ID
$clientId       = $env:LAB_CLIENT_ID
$clientSecret   = $env:LAB_CLIENT_SECRET
$labInstanceId  = $env:LAB_INSTANCE_ID
$location       = $env:LAB_LOCATION
if (-not $location) { $location = "eastus2" }

# 2) Validate required variables
if (-not $AdminUserName -or -not $AdminPassword) { Write-Log "Missing LAB_ADMIN_USERNAME or LAB_ADMIN_PASSWORD."; return }
if (-not $tenantId -or -not $subscriptionId) { Write-Log "Missing LAB_TENANT_ID or LAB_SUBSCRIPTION_ID."; return }
if (-not $clientId -or -not $clientSecret) { Write-Log "Missing LAB_CLIENT_ID or LAB_CLIENT_SECRET."; return }
if (-not $labInstanceId) { Write-Log "Missing LAB_INSTANCE_ID."; return }
Write-Log "Environment variables validated."

# 3) Connect with lab credentials
try {
    $labCred = New-Object System.Management.Automation.PSCredential($AdminUserName, (ConvertTo-SecureString $AdminPassword -AsPlainText -Force))
    Connect-AzAccount -Credential $labCred | Out-Null
    Write-Log "Connected to Az using lab credentials."
} catch {
    Write-Log "Login with lab credentials failed: $($_.Exception.Message)"
    return
}

# 4) Login with service principal
$env:AZURE_CLIENT_ID     = $clientId
$env:AZURE_CLIENT_SECRET = $clientSecret
$env:AZURE_TENANT_ID     = $tenantId
$env:AZD_NON_INTERACTIVE = "true"
$env:LAB_INSTANCE_ID     = $labInstanceId

azd auth login --client-id $clientId --client-secret $clientSecret --tenant-id $tenantId | Out-Null
az login --service-principal --username $clientId --password $clientSecret --tenant $tenantId | Out-Null
# 5) Clone repo
$deployPath = "$HOME\gpt-rag-deploy"
Remove-Item -Recurse -Force $deployPath -ErrorAction SilentlyContinue | Out-Null
git clone -b agentic https://github.com/Azure/gpt-rag.git $deployPath | Tee-Object -FilePath $logFile -Append
Set-Location $deployPath

# 6) Clean YAML
$yamlPath = Join-Path $deployPath "azure.yaml"
$cleanYaml = @"
# yaml-language-server: $schema=https://raw.githubusercontent.com/Azure/azure-dev/main/schemas/v1.0/azure.yaml.json
name: azure-gpt-rag
metadata:
  template: azure-gpt-rag
services:
  dataIngest:
    project: ./.azure/gpt-rag-ingestion
    language: python
    host: function
  orchestrator:
    project: ./.azure/gpt-rag-orchestrator
    language: python
    host: function
  frontend:
    project: ./.azure/gpt-rag-frontend
    language: python
    host: appservice
"@
Set-Content -Path $yamlPath -Value $cleanYaml -Encoding UTF8

# 6.1) Init environment
$env:AZD_SKIP_UPDATE_CHECK = "true"
$env:AZD_DEFAULT_YES = "true"
azd init --environment dev-lab --no-prompt | Tee-Object -FilePath $logFile -Append

# 6.2) Remove pre-* scripts
$infraScriptPath = Join-Path $deployPath "infra\scripts"
Remove-Item -Force -ErrorAction SilentlyContinue "$infraScriptPath\preprovision.ps1"
Remove-Item -Force -ErrorAction SilentlyContinue "$infraScriptPath\preDeploy.ps1"

# 6.3) Add AZURE_NETWORK_ISOLATION to .env
$envFile = Join-Path $deployPath ".azure\dev-lab\.env"
if (Test-Path $envFile) {
    $envContent = Get-Content $envFile
    if ($envContent -notmatch "^AZURE_NETWORK_ISOLATION=") {
        Add-Content $envFile "`nAZURE_NETWORK_ISOLATION=true"
        Write-Log "AZURE_NETWORK_ISOLATION set to true in .env"
    }
}
# 7) Replace Key Vault name
$newKvName = "kv-$labInstanceId"
$kvFiles = Get-ChildItem -Recurse -Include *.bicep,*.json -ErrorAction SilentlyContinue
foreach ($file in $kvFiles) {
    (Get-Content $file.FullName) -replace 'kv0-[a-z0-9]+', $newKvName | Set-Content $file.FullName
}

# 7.1) Comment out OpenAI in main Bicep
$openaiBicep = Join-Path $deployPath "infra\core\ai\openai.bicep"
if (Test-Path $openaiBicep) {
    $lines = Get-Content $openaiBicep
    $commented = $lines | ForEach-Object { if ($_ -notmatch "^//") { "// $_" } else { $_ } }
    Set-Content -Path $openaiBicep -Value $commented
    Write-Log "Commented out OpenAI deployment in openai.bicep to skip during azd provision"
}

# 8) Configure azd environment values
azd env set AZURE_KEY_VAULT_NAME $newKvName | Tee-Object -FilePath $logFile -Append
azd env set AZURE_SUBSCRIPTION_ID $subscriptionId | Tee-Object -FilePath $logFile -Append
azd env set AZURE_LOCATION $location | Tee-Object -FilePath $logFile -Append
az account set --subscription $subscriptionId | Tee-Object -FilePath $logFile -Append
# === NEW: Pre-provision Azure OpenAI (ensure no soft-delete conflicts) ===
$openAiName = "oai0-$labInstanceId"
Write-Log "Checking for soft-deleted OpenAI instance $openAiName before provisioning..."
try {
    $deleted = az cognitiveservices account list-deleted `
        --location $location `
        --query "[?name=='$openAiName']" -o json | ConvertFrom-Json

    if ($deleted) {
        Write-Log "Found soft-deleted OpenAI resource $openAiName. Purging..."
        az cognitiveservices account purge `
            --location $location `
            --name $openAiName | Out-Null
        Write-Log "Purged soft-deleted Azure OpenAI resource: $openAiName"
    } else {
        Write-Log "No soft-deleted Azure OpenAI resource found."
    }
} catch {
    Write-Log "[WARNING] Failed to check or purge soft-deleted Azure OpenAI resource: $_"
}

# === NEW: Purge soft-deleted Key Vault: bastionkv-* ===
$bastionKvName = "bastionkv-$($labInstanceId.ToLower())"
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
        Write-Log "No soft-deleted Key Vault $bastionKvName found."
    }
} catch {
    Write-Log "[WARNING] Failed to purge soft-deleted Key Vault $bastionKvName: $_"
}

# Download and run fallback script to provision OpenAI
try {
    $fallbackScriptPath = "$env:TEMP\provision-openai.ps1"
    Invoke-WebRequest `
        -Uri "https://raw.githubusercontent.com/LODSContent/ProServ/refs/heads/main/41-442%20MS%20RAG%20GPT/provision-openai.ps1" `
        -OutFile $fallbackScriptPath -UseBasicParsing

    Write-Log "Downloaded fallback OpenAI provision script to $fallbackScriptPath"

    & $fallbackScriptPath `
        -subscriptionId $subscriptionId `
        -resourceGroup "rg-dev-lab" `
        -location $location `
        -labInstanceId $labInstanceId `
        -clientId $clientId `
        -clientSecret $clientSecret `
        -tenantId $tenantId `
        -logFile $logFile
} catch {
    Write-Log "[ERROR] Failed to run fallback OpenAI provisioning script. $_"
}
# 9) Provision main resources
$env:BICEP_REGISTRY_MODULE_INSTALLATION_ENABLED = "true"
Write-Log "Starting azd provision..."
azd provision --environment dev-lab 2>&1 | Tee-Object -FilePath $logFile -Append
Write-Log "azd provision complete."

# 10) Discover Resource Group
$resourceGroup = $null
$attempts = 0
while (-not $resourceGroup -and $attempts -lt 5) {
    $resourceGroup = az group list --query "[?contains(name, 'rg-dev-lab')].name" -o tsv
    Start-Sleep -Seconds 5
    $attempts++
}
azd env set AZURE_RESOURCE_GROUP $resourceGroup | Tee-Object -FilePath $logFile -Append
Write-Log "Set AZURE_RESOURCE_GROUP to $resourceGroup"

# 10.1) Retry fallback OpenAI provisioning if not in Succeeded state
$openAiAccountName = az resource list --resource-group $resourceGroup `
    --resource-type "Microsoft.CognitiveServices/accounts" `
    --query "[?contains(name, 'oai0')].name" -o tsv

$provisioningState = ""
if ($openAiAccountName) {
    $provisioningState = az cognitiveservices account show `
        --name $openAiAccountName `
        --resource-group $resourceGroup `
        --query "provisioningState" -o tsv
}

if (-not $openAiAccountName -or $provisioningState -ne "Succeeded") {
    try {
        $fallbackScriptPath = "$env:TEMP\provision-openai.ps1"
        Invoke-WebRequest `
            -Uri "https://raw.githubusercontent.com/LODSContent/ProServ/refs/heads/main/41-442%20MS%20RAG%20GPT/provision-openai.ps1" `
            -OutFile $fallbackScriptPath -UseBasicParsing

        Write-Log "Downloaded fallback OpenAI provision script to $fallbackScriptPath"

        & $fallbackScriptPath `
            -subscriptionId $subscriptionId `
            -resourceGroup $resourceGroup `
            -location $location `
            -labInstanceId $labInstanceId `
            -clientId $clientId `
            -clientSecret $clientSecret `
            -tenantId $tenantId `
            -logFile $logFile

        Write-Log "Retry fallback OpenAI provision script executed."
    } catch {
        Write-Log "[ERROR] Retry fallback OpenAI provisioning script failed. $_"
    }
} else {
    Write-Log "Azure OpenAI resource confirmed provisioned after main deployment."
}
# 11) Assign Storage Blob Data Contributor role
Write-Log "Assigning Storage Blob Data Contributor role to SP..."

$storageAccount = az resource list --resource-group $resourceGroup `
    --resource-type "Microsoft.Storage/storageAccounts" `
    --query "sort_by([?type=='Microsoft.Storage/storageAccounts'], &length(name))[0].name" -o tsv

$objectId = az ad sp show --id $clientId --query id -o tsv

az role assignment create `
    --assignee-object-id $objectId `
    --assignee-principal-type ServicePrincipal `
    --role "Storage Blob Data Contributor" `
    --scope "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Storage/storageAccounts/$storageAccount" | Out-Null

Write-Log "Role assignment complete for Storage Blob Data Contributor."

# 12) Update Function App settings and restart
Write-Log "Updating Function App settings..."

$ingestionFunc = az resource list --resource-group $resourceGroup `
    --resource-type "Microsoft.Web/sites" `
    --query "[?contains(name, 'inges')].name" -o tsv

$orchestratorFunc = az resource list --resource-group $resourceGroup `
    --resource-type "Microsoft.Web/sites" `
    --query "[?contains(name, 'orch')].name" -o tsv

if ($ingestionFunc) {
    az functionapp config appsettings set `
        --name $ingestionFunc `
        --resource-group $resourceGroup `
        --settings MULTIMODAL=true | Out-Null

    az functionapp restart `
        --name $ingestionFunc `
        --resource-group $resourceGroup | Out-Null

    Write-Log "Ingestion function app updated and restarted."
} else {
    Write-Log "[WARNING] Ingestion Function App not found."
}

if ($orchestratorFunc) {
    az functionapp config appsettings set `
        --name $orchestratorFunc `
        --resource-group $resourceGroup `
        --settings AUTOGEN_ORCHESTRATION_STRATEGY=multimodal_rag | Out-Null

    az functionapp restart `
        --name $orchestratorFunc `
        --resource-group $resourceGroup | Out-Null

    Write-Log "Orchestrator function app updated and restarted."
} else {
    Write-Log "[WARNING] Orchestrator Function App not found."
}

# 13) Output Web App URL
Write-Log "Retrieving deployed Web App URL..."

$webAppName = az resource list --resource-group $resourceGroup `
    --resource-type "Microsoft.Web/sites" `
    --query "[?contains(name, 'webgpt')].name" -o tsv

if ($webAppName) {
    $webAppUrl = az webapp show `
        --name $webAppName `
        --resource-group $resourceGroup `
        --query "defaultHostName" -o tsv

    Write-Host "Your GPT solution is live at: https://$webAppUrl"
    Write-Log "Deployment complete. URL: https://$webAppUrl"
} else {
    Write-Log "[WARNING] Web App not found. Cannot determine deployment URL."
    Write-Host "Deployment completed, but Web App URL could not be retrieved."
}

$endTime = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
Write-Host "Done."
Write-Log "Script completed at $endTime"
