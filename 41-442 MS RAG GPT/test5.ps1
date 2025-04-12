#
# gpt-rag.ps1 (Updated: Generate new Key Vault name on soft-delete conflict)
#

$logFile = "C:\labfiles\progress.log"
function Write-Log($msg) {
    $stamp = (Get-Date).ToString("yyyy-MM-dd HHmmss")
    Add-Content $logFile "[INFO] $stamp $msg"
}

Write-Log "Script started in GitHub version."

$AdminUserName = $env:LAB_ADMIN_USERNAME
$AdminPassword = $env:LAB_ADMIN_PASSWORD
$tenantId      = $env:LAB_TENANT_ID
$subscriptionId= $env:LAB_SUBSCRIPTION_ID
$clientId      = $env:LAB_CLIENT_ID
$clientSecret  = $env:LAB_CLIENT_SECRET

# === Validations ===
if (-not $AdminUserName -or -not $AdminPassword) {
    Write-Log "Missing LAB_ADMIN_USERNAME or LAB_ADMIN_PASSWORD."
    return
}
if (-not $tenantId -or -not $subscriptionId) {
    Write-Log "Missing LAB_TENANT_ID or LAB_SUBSCRIPTION_ID."
    return
}
if (-not $clientId -or -not $clientSecret) {
    Write-Log "Missing LAB_CLIENT_ID or LAB_CLIENT_SECRET."
    return
}

Write-Log "Environment variables loaded."

# === Azure Login ===
try {
    $labCred = New-Object PSCredential (
        $AdminUserName,
        (ConvertTo-SecureString $AdminPassword -AsPlainText -Force)
    )
    Connect-AzAccount -Credential $labCred | Out-String | Write-Log
}
catch {
    Write-Log "Lab credentials login failed: $($_.Exception.Message)"
    return
}

$env:AZURE_CLIENT_ID     = $clientId
$env:AZURE_CLIENT_SECRET = $clientSecret
$env:AZURE_TENANT_ID     = $tenantId
$env:AZD_NON_INTERACTIVE = "true"
$env:AZD_SKIP_UPDATE_CHECK = "true"

Write-Log "Logging in with service principal for azd + az."
azd auth login --client-id $clientId --client-secret $clientSecret --tenant-id $tenantId | Out-String | Write-Log
az login --service-principal --username $clientId --password $clientSecret --tenant $tenantId | Out-String | Write-Log

# === Init Workspace ===
$deployPath = "$HOME\gpt-rag-deploy"
Remove-Item -Recurse -Force $deployPath -ErrorAction SilentlyContinue | Out-String | Write-Log
New-Item -ItemType Directory -Path $deployPath -Force | Out-String | Write-Log
Set-Location $deployPath

Write-Log "Initializing GPT-RAG template..."
azd init -t azure/gpt-rag -b workshop -e dev-lab | Out-String | Write-Log

# === Set Environment ===
azd env set AZURE_SUBSCRIPTION_ID $subscriptionId | Out-String | Write-Log
azd env set AZURE_LOCATION eastus2 | Out-String | Write-Log
azd env set AZURE_NETWORK_ISOLATION false | Out-String | Write-Log
az account set --subscription $subscriptionId | Out-String | Write-Log

# === Provision ===
Write-Log "Provisioning environment..."
$provisionResult = azd provision --environment dev-lab 2>&1 | Tee-Object -FilePath $logFile -Append

# === Key Vault Conflict Detection ===
if ($provisionResult -match "Key Vault.*already exists in deleted state") {
    Write-Log "Soft-deleted Key Vault exists. Regenerating name..."

    $kvLine = $provisionResult | Where-Object { $_ -match "Failed: Key Vault: (kv[\w-]+)" }
    if ($kvLine -match "Key Vault: (kv[\w-]+)") {
        $oldKvName = $matches[1]
        $uniqueSuffix = Get-Random -Minimum 1000 -Maximum 9999
        $newKvName = "$oldKvName$uniqueSuffix"

        Write-Log "Old Key Vault name: $oldKvName"
        Write-Log "New Key Vault name: $newKvName"

        $yamlPath = "$deployPath\azure.yaml"
        (Get-Content $yamlPath) -replace $oldKvName, $newKvName | Set-Content $yamlPath

        Write-Log "azure.yaml updated with new Key Vault name."

        Write-Log "Retrying provisioning..."
        azd provision --environment dev-lab 2>&1 | Tee-Object -FilePath $logFile -Append
    } else {
        Write-Log "Could not extract Key Vault name from output."
    }
}

# === Post-deployment ===
$resourceGroup = az group list --query "[?contains(name, 'rg-dev-lab')].name" -o tsv
$webAppName = az resource list --resource-group $resourceGroup --resource-type "Microsoft.Web/sites" --query "[?contains(name, 'webgpt')].name" -o tsv
$webAppUrl  = az webapp show --name $webAppName --resource-group $resourceGroup --query "defaultHostName" -o tsv

Write-Log "Deployment complete. URL: https://$webAppUrl"
Write-Host "Your GPT solution is live at: https://$webAppUrl"
Write-Log "Script completed."
