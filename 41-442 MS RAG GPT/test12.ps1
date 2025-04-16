# gpt-rag.ps1 (Final: Clean YAML, dynamic KV and AI names, full Bicep validation, no what-if, with logging)
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
if (-not $AdminUserName -or -not $AdminPassword) {
    Write-Host "Lab user credentials not found. Exiting."
    Write-Log "Missing LAB_ADMIN_USERNAME or LAB_ADMIN_PASSWORD."
    return
}
if (-not $tenantId -or -not $subscriptionId) {
    Write-Host "Tenant or Subscription ID missing. Exiting."
    Write-Log "Missing LAB_TENANT_ID or LAB_SUBSCRIPTION_ID."
    return
}
if (-not $clientId -or -not $clientSecret) {
    Write-Host "Service principal details missing. Exiting."
    Write-Log "Missing LAB_CLIENT_ID or LAB_CLIENT_SECRET."
    return
}
if (-not $labInstanceId) {
    Write-Host "Lab instance ID missing. Exiting."
    Write-Log "Missing LAB_INSTANCE_ID."
    return
}

Write-Log "Environment variables validated."

# 3) Connect with lab credentials
try {
    $labCred = New-Object System.Management.Automation.PSCredential(
        $AdminUserName,
        (ConvertTo-SecureString $AdminPassword -AsPlainText -Force)
    )
    Connect-AzAccount -Credential $labCred | Out-Null
    Write-Log "Connected to Az using lab credentials."
} catch {
    Write-Host "Login failed: $($_.Exception.Message)"
    Write-Log "Login with lab credentials failed."
    return
}

# 4) Login with service principal
$env:AZURE_CLIENT_ID     = $clientId
$env:AZURE_CLIENT_SECRET = $clientSecret
$env:AZURE_TENANT_ID     = $tenantId
$env:AZD_NON_INTERACTIVE = "true"
$env:LAB_INSTANCE_ID     = $labInstanceId

azd auth login --client-id $clientId --client-secret $clientSecret --tenant-id $tenantId | Tee-Object -FilePath $logFile -Append
az login --service-principal --username $clientId --password $clientSecret --tenant $tenantId | Tee-Object -FilePath $logFile -Append

# 5) Clone repo
$deployPath = "$HOME\gpt-rag-deploy"
Remove-Item -Recurse -Force $deployPath -ErrorAction SilentlyContinue | Out-Null
git clone -b agentic https://github.com/Azure/gpt-rag.git $deployPath | Tee-Object -FilePath $logFile -Append
Set-Location $deployPath

# 6.0) Clean YAML
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

# 6) Init env
$env:AZD_SKIP_UPDATE_CHECK = "true"
$env:AZD_DEFAULT_YES = "true"
azd init --environment dev-lab --no-prompt | Tee-Object -FilePath $logFile -Append

# 6.1) Remove pre-* scripts
$infraScriptPath = Join-Path $deployPath "infra\scripts"
Remove-Item -Force -ErrorAction SilentlyContinue "$infraScriptPath\preprovision.ps1"
Remove-Item -Force -ErrorAction SilentlyContinue "$infraScriptPath\preDeploy.ps1"

# 6.2) Add AZURE_NETWORK_ISOLATION to .env
$envFile = Join-Path $deployPath ".azure\dev-lab\.env"
if (Test-Path $envFile) {
    $envContent = Get-Content $envFile
    if ($envContent -notmatch "^AZURE_NETWORK_ISOLATION=") {
        Add-Content $envFile "`nAZURE_NETWORK_ISOLATION=true"
        Write-Log "AZURE_NETWORK_ISOLATION set to true in .env"
    }
}

# 7) Key Vault renaming
$newKvName = "kv-$labInstanceId"
$kvFiles = Get-ChildItem -Recurse -Include *.bicep,*.json -ErrorAction SilentlyContinue
foreach ($file in $kvFiles) {
    (Get-Content $file.FullName) -replace 'kv0-[a-z0-9]+', $newKvName | Set-Content $file.FullName
}

# 7.1) Cognitive Services name deduplication
$uniqueSuffix = (Get-Date -Format "yyyyMMddHHmmss")
foreach ($file in $kvFiles) {
    $content = Get-Content $file.FullName -Raw
    $content = $content -replace 'oai0-[a-z0-9]+', "oai0-$labInstanceId-$uniqueSuffix"
    $content = $content -replace 'ai0-[a-z0-9]+', "ai0-$labInstanceId-$uniqueSuffix"
    Set-Content $file.FullName $content
}

# 7.2) Bicep file validation
$coreFolder = Join-Path $deployPath "infra\core"
$maxRetries = 5
do {
    $coreBicepFiles = Get-ChildItem -Path $coreFolder -Filter *.bicep -Recurse
    if ($coreBicepFiles.Count -ge 30) { break }
    Start-Sleep -Seconds 10
    $retry++
} while ($retry -lt $maxRetries)

if ($coreBicepFiles.Count -lt 30) {
    Write-Log "[ERROR] Only $($coreBicepFiles.Count)/30 Bicep files found. Aborting."
    exit 1
}

# 7.3) Bicep build all
foreach ($file in $coreBicepFiles) {
    $buildOutput = bicep build $file.FullName 2>&1 | Out-String
    Write-Log "Build output for $($file.FullName): $buildOutput"
    Add-Content -Path $bicepErrorLog -Value "`n--- Build Output for $($file.FullName) ---`n$buildOutput"
    if ($buildOutput -match "Error") {
        Write-Log "[ERROR] Building $($file.FullName) failed."
        exit 1
    }
}

# 8) Configure env
azd env set AZURE_KEY_VAULT_NAME $newKvName | Tee-Object -FilePath $logFile -Append
azd env set AZURE_SUBSCRIPTION_ID $subscriptionId | Tee-Object -FilePath $logFile -Append
azd env set AZURE_LOCATION $location | Tee-Object -FilePath $logFile -Append
az account set --subscription $subscriptionId | Tee-Object -FilePath $logFile -Append

# 9) Provision
$env:BICEP_REGISTRY_MODULE_INSTALLATION_ENABLED = "true"
azd provision --environment dev-lab 2>&1 | Tee-Object -FilePath $logFile -Append

# 10) Discover RG
$resourceGroup = $null
$attempts = 0
while (-not $resourceGroup -and $attempts -lt 5) {
    $resourceGroup = az group list --query "[?contains(name, 'rg-dev-lab')].name" -o tsv
    Start-Sleep -Seconds 5
    $attempts++
}
azd env set AZURE_RESOURCE_GROUP $resourceGroup | Tee-Object -FilePath $logFile -Append



# 9.5) Purge soft-deleted Cognitive Services before provision
Write-Log "Checking for soft-deleted Cognitive Services instances to purge..."
$purgeCandidates = @("oai0-$labInstanceId", "ai0-$labInstanceId")

foreach ($baseName in $purgeCandidates) {
    $deletedResources = az cognitiveservices account list-deleted `
        --location $location `
        --query "[?contains(name, '$baseName')]" -o json | ConvertFrom-Json

    foreach ($deleted in $deletedResources) {
        $deletedName = $deleted.name
        $deletedLocation = $deleted.properties.location
        $deletedResourceGroup = $deleted.properties.resourceGroup

        Write-Log "Purging soft-deleted Cognitive Services resource: $deletedName"
        az cognitiveservices account purge `
            --location $deletedLocation `
            --name $deletedName `
            --resource-group $deletedResourceGroup | Tee-Object -FilePath $logFile -Append
    }
}



# 10.5) Wait on OpenAI
$openAiAccountName = az resource list --resource-group $resourceGroup --resource-type "Microsoft.CognitiveServices/accounts" --query "[?contains(name, 'oai0')].name" -o tsv
$attempt = 0
do {
    $provisioningState = az cognitiveservices account show --name $openAiAccountName --resource-group $resourceGroup --query "provisioningState" -o tsv
    Start-Sleep -Seconds 10
    $attempt++
} while ($provisioningState -ne "Succeeded" -and $attempt -lt 10)

# 10.6) Deploy models if needed
$existingDeployments = az cognitiveservices account deployment list --name $openAiAccountName --resource-group $resourceGroup --query "[].name" -o tsv
if ($existingDeployments -notmatch "chat") {
    az cognitiveservices account deployment create --name $openAiAccountName --resource-group $resourceGroup --deployment-name "chat" --model-format OpenAI --model-name "gpt-35-turbo" --model-version "0613" --sku-name "standard" --scale-type "Standard"
}
if ($existingDeployments -notmatch "text-embedding") {
    az cognitiveservices account deployment create --name $openAiAccountName --resource-group $resourceGroup --deployment-name "text-embedding" --model-format OpenAI --model-name "text-embedding-ada-002" --model-version "2" --sku-name "standard" --scale-type "Standard"
}

# 11) Role assignment + config
$storageAccount = az resource list --resource-group $resourceGroup --resource-type "Microsoft.Storage/storageAccounts" --query "sort_by([?type=='Microsoft.Storage/storageAccounts'], &length(name))[0].name" -o tsv
$objectId = az ad sp show --id $clientId --query id -o tsv
az role assignment create --assignee-object-id $objectId --assignee-principal-type ServicePrincipal --role "Storage Blob Data Contributor" --scope "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Storage/storageAccounts/$storageAccount"

# 12) App settings
$ingestionFunc  = az resource list --resource-group $resourceGroup --resource-type "Microsoft.Web/sites" --query "[?contains(name, 'inges')].name" -o tsv
$orchestratorFunc = az resource list --resource-group $resourceGroup --resource-type "Microsoft.Web/sites" --query "[?contains(name, 'orch')].name" -o tsv
az functionapp config appsettings set --name $ingestionFunc --resource-group $resourceGroup --settings MULTIMODAL=true
az functionapp restart --name $ingestionFunc --resource-group $resourceGroup
az functionapp config appsettings set --name $orchestratorFunc --resource-group $resourceGroup --settings AUTOGEN_ORCHESTRATION_STRATEGY=multimodal_rag
az functionapp restart --name $orchestratorFunc --resource-group $resourceGroup

# 13) Output
$webAppName = az resource list --resource-group $resourceGroup --resource-type "Microsoft.Web/sites" --query "[?contains(name, 'webgpt')].name" -o tsv
$webAppUrl  = az webapp show --name $webAppName --resource-group $resourceGroup --query "defaultHostName" -o tsv

Write-Host "Your GPT solution is live at: https://$webAppUrl"
Write-Log "Deployment complete. URL: https://$webAppUrl"

Write-Host "Done."
$endTime = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
Write-Log "Script completed at $endTime"
