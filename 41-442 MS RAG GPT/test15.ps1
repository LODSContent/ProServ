# gpt-rag.ps1 (Updated: Fallback OpenAI provisioning before azd provision, handles soft-deleted resources)

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

# 7.1) Comment out OpenAI in main Bicep
$openaiBicep = Join-Path $deployPath "infra\core\ai\openai.bicep"
if (Test-Path $openaiBicep) {
    $lines = Get-Content $openaiBicep
    $commented = $lines | ForEach-Object { if ($_ -notmatch "^//") { "// $_" } else { $_ } }
    Set-Content -Path $openaiBicep -Value $commented
    Write-Log "Commented out OpenAI deployment in openai.bicep to skip during azd provision"
}

# 8) Configure env
azd env set AZURE_KEY_VAULT_NAME $newKvName | Tee-Object -FilePath $logFile -Append
azd env set AZURE_SUBSCRIPTION_ID $subscriptionId | Tee-Object -FilePath $logFile -Append
azd env set AZURE_LOCATION $location | Tee-Object -FilePath $logFile -Append
az account set --subscription $subscriptionId | Tee-Object -FilePath $logFile -Append

# === NEW: Pre-provision OpenAI to avoid soft-deleted conflicts ===
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

# Continue with the rest (role assignments, function config, web app output...)
# You can reinsert blocks 10–13 from the previous version below this line as needed.
