# gpt-rag.ps1 (Streamlined Logging Version - Part 1)

$logFile = "C:\labfiles\progress.log"

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

# 3) Connect with lab credentials
try {
    $labCred = New-Object System.Management.Automation.PSCredential($AdminUserName, (ConvertTo-SecureString $AdminPassword -AsPlainText -Force))
    Connect-AzAccount -Credential $labCred | Out-Null
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
git clone -b agentic https://github.com/Azure/gpt-rag.git $deployPath | Out-Null
Set-Location $deployPath
# 6) Clean up azure.yaml so we skip any hook blocks
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
Write-Log "Cleaned azure.yaml"

# 6.1) Initialize with azd
$env:AZD_SKIP_UPDATE_CHECK = "true"
$env:AZD_DEFAULT_YES       = "true"
azd init --environment dev-lab --no-prompt | Out-Null
Write-Log "Initialized azd environment"

# 6.2) Remove any interactive pre-scripts
$infraScriptPath = Join-Path $deployPath "infra\scripts"
Remove-Item -Force -ErrorAction SilentlyContinue "$infraScriptPath\preprovision.ps1","$infraScriptPath\preDeploy.ps1"
Write-Log "Removed pre-provision/deploy scripts"

# 6.3) Force network isolation in .env
$envFile = Join-Path $deployPath ".azure\dev-lab\.env"
if (Test-Path $envFile) {
    $content = Get-Content $envFile
    if ($content -notmatch "^AZURE_NETWORK_ISOLATION=") {
        Add-Content $envFile "`nAZURE_NETWORK_ISOLATION=true"
        Write-Log "Enabled AZURE_NETWORK_ISOLATION"
    }
}

# 7) Skip main OpenAI Bicep
$openaiBicep = Join-Path $deployPath "infra\core\ai\openai.bicep"
if (Test-Path $openaiBicep) {
    (Get-Content $openaiBicep) |
      ForEach-Object { "// $_" } |
      Set-Content $openaiBicep
    Write-Log "Commented out openai.bicep"
}

# 8) Configure azd environment variables
azd env set AZURE_KEY_VAULT_NAME $("kv-" + $labInstanceId) | Out-Null
azd env set AZURE_SUBSCRIPTION_ID  $subscriptionId     | Out-Null
azd env set AZURE_LOCATION         $location           | Out-Null
az account set --subscription      $subscriptionId     | Out-Null
Write-Log "Configured azd env variables"
# 9) Pre-provision OpenAI to purge any soft-deleted
$openAiName = "oai0-$labInstanceId"
Write-Log "Checking soft-deleted OpenAI: $openAiName"
$deleted = az cognitiveservices account list-deleted `
    --location $location `
    --query "[?name=='$openAiName']" -o json | ConvertFrom-Json
if ($deleted) {
    az cognitiveservices account purge --location $location --name $openAiName | Out-Null
    Write-Log "Purged soft-deleted OpenAI: $openAiName"
} else {
    Write-Log "No soft-deleted OpenAI found"
}

# Download & run fallback provision script
$fallback = "$env:TEMP\provision-openai.ps1"
Invoke-WebRequest `
  -Uri "https://raw.githubusercontent.com/LODSContent/ProServ/refs/heads/main/41-442%20MS%20RAG%20GPT/provision-openai.ps1" `
  -OutFile $fallback -UseBasicParsing
Write-Log "Downloaded fallback-openai.ps1"
& $fallback `
  -subscriptionId $subscriptionId `
  -resourceGroup  "rg-dev-lab" `
  -location       $location `
  -labInstanceId  $labInstanceId `
  -clientId       $clientId `
  -clientSecret   $clientSecret `
  -tenantId       $tenantId `
  -logFile        $logFile
Write-Log "Fallback OpenAI provisioning done"

# 10) Provision the rest
$env:BICEP_REGISTRY_MODULE_INSTALLATION_ENABLED = "true"
Write-Log "Starting azd provision"
azd provision --environment dev-lab 2>&1 | Out-Null
Write-Log "azd provision complete"

# 11) Discover RG
$rg = az group list --query "[?contains(name,'rg-dev-lab')].name" -o tsv
azd env set AZURE_RESOURCE_GROUP $rg | Out-Null
Write-Log "Set resource group: $rg"

# 12) Role assignment
$storage = az resource list --resource-group $rg `
    --resource-type "Microsoft.Storage/storageAccounts" `
    --query "sort_by(@,'length(name)')[0].name" -o tsv
$spId = az ad sp show --id $clientId --query id -o tsv
az role assignment create `
  --assignee-object-id $spId `
  --role "Storage Blob Data Contributor" `
  --scope "/subscriptions/$subscriptionId/resourceGroups/$rg/providers/Microsoft.Storage/storageAccounts/$storage" | Out-Null
Write-Log "Assigned Storage Blob Data Contributor"

# 13) Update function apps
$ing = az resource list --resource-group $rg --resource-type "Microsoft.Web/sites" --query "[?contains(name,'inges')].name" -o tsv
$orc = az resource list --resource-group $rg --resource-type "Microsoft.Web/sites" --query "[?contains(name,'orch')].name" -o tsv
if ($ing) { az functionapp config appsettings set --name $ing --resource-group $rg --settings MULTIMODAL=true; az functionapp restart --name $ing --resource-group $rg }
if ($orc) { az functionapp config appsettings set --name $orc --resource-group $rg --settings AUTOGEN_ORCHESTRATION_STRATEGY=multimodal_rag; az functionapp restart --name $orc --resource-group $rg }
Write-Log "Function apps updated"

# 14) Web App URL
$web = az resource list --resource-group $rg --resource-type "Microsoft.Web/sites" --query "[?contains(name,'webgpt')].name" -o tsv
if ($web) {
    $url = az webapp show --name $web --resource-group $rg --query defaultHostName -o tsv
    Write-Host "Solution live at: https://$url"
    Write-Log "Deployment URL: https://$url"
}
