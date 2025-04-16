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

azd auth login --client-id $clientId --client-secret $clientSecret --tenant-id $tenantId | Tee-Object -FilePath $logFile -Append
az login --service-principal --username $clientId --password $clientSecret --tenant $tenantId | Tee-Object -FilePath $logFile -Append

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

# 6.1) Init env
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

# 7.1) Skip OpenAI in main deployment by commenting it out
$openaiBicep = Join-Path $deployPath "infra\core\ai\openai.bicep"
if (Test-Path $openaiBicep) {
    $lines = Get-Content $openaiBicep
    $commented = $lines | ForEach-Object { if ($_ -notmatch "^//") { "// $_" } else { $_ } }
    Set-Content -Path $openaiBicep -Value $commented
    Write-Log "Commented out OpenAI deployment in openai.bicep to skip during azd provision"
}

# 7.2) Validate 30 Biceps
$coreFolder = Join-Path $deployPath "infra\core"
$retry = 0
do {
    $coreBicepFiles = Get-ChildItem -Path $coreFolder -Filter *.bicep -Recurse
    if ($coreBicepFiles.Count -ge 30) { break }
    Start-Sleep -Seconds 10
    $retry++
} while ($retry -lt 5)

if ($coreBicepFiles.Count -lt 30) {
    Write-Log "[ERROR] Only $($coreBicepFiles.Count)/30 Bicep files found. Aborting."
    exit 1
}

# 7.3) Build all Biceps
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

# 9) Provision main resources
$env:BICEP_REGISTRY_MODULE_INSTALLATION_ENABLED = "true"
Write-Log "Starting azd provision..."
azd provision --environment dev-lab 2>&1 | Tee-Object -FilePath $logFile -Append
Write-Log "azd provision complete."


# 9.9) Attempt manual OpenAI provisioning fallback if failure is detected
$openAiDeploymentSucceeded = $true
$openAiAccountName = az resource list --resource-group $resourceGroup --resource-type "Microsoft.CognitiveServices/accounts" --query "[?contains(name, 'oai0')].name" -o tsv

if (-not $openAiAccountName) {
    Write-Log "[WARNING] Azure OpenAI resource was not provisioned during 'azd provision'. Attempting manual fallback..."
    $openAiDeploymentSucceeded = $false
} else {
    # Check provisioning state
    $provisioningState = az cognitiveservices account show --name $openAiAccountName --resource-group $resourceGroup --query "provisioningState" -o tsv
    if ($provisioningState -ne "Succeeded") {
        Write-Log "[WARNING] Azure OpenAI resource in non-terminal state: $provisioningState. Attempting manual fallback..."
        $openAiDeploymentSucceeded = $false
    }
}

if (-not $openAiDeploymentSucceeded) {
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

        Write-Log "Fallback OpenAI provision script executed successfully."
    } catch {
        Write-Log "[ERROR] Failed to run fallback OpenAI provisioning script. $_"
    }
}


# 10) Discover RG
$resourceGroup = $null
$attempts = 0
while (-not $resourceGroup -and $attempts -lt 5) {
    $resourceGroup = az group list --query "[?contains(name, 'rg-dev-lab')].name" -o tsv
    Start-Sleep -Seconds 5
    $attempts++
}
azd env set AZURE_RESOURCE_GROUP $resourceGroup | Tee-Object -FilePath $logFile -Append
Write-Log "Set AZURE_RESOURCE_GROUP to $resourceGroup"


# 10.1) Attempt fallback OpenAI provisioning if not succeeded
$openAiAccountName = az resource list --resource-group $resourceGroup --resource-type "Microsoft.CognitiveServices/accounts" `
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

        Write-Log "Fallback OpenAI provision script executed successfully."
    } catch {
        Write-Log "[ERROR] Failed to run fallback OpenAI provisioning script. $_"
    }
} else {
    Write-Log "Azure OpenAI resource provisioned successfully in main script."
}




# 10.2) Provision OpenAI separately
Write-Log "Calling fallback script to provision Azure OpenAI..."
$openAiScript = "$HOME\gpt-rag-deploy\scripts\provision-openai.ps1"
if (Test-Path $openAiScript) {
    & $openAiScript -resourceGroup $resourceGroup -location $location -labInstanceId $labInstanceId -subscriptionId $subscriptionId
} else {
    Write-Log "[ERROR] provision-openai.ps1 not found at $openAiScript"
}




# 10.5) Call separate OpenAI script
$openAiScript = Join-Path $deployPath "scripts\provision-openai.ps1"
if (Test-Path $openAiScript) {
    Write-Log "Invoking external OpenAI provisioning script."
    & $openAiScript -ResourceGroup $resourceGroup -Location $location -LabInstanceId $labInstanceId -SubscriptionId $subscriptionId | Tee-Object -FilePath $logFile -Append
} else {
    Write-Log "[WARNING] OpenAI provisioning script not found at $openAiScript"
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
