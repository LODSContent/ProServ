#
# gpt-rag.ps1 (Updated with Option 2: variable assignment + logging + Key Vault fallback renaming)
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

if (-not $AdminUserName -or -not $AdminPassword) {
    Write-Host "Lab user credentials not found in environment variables. Exiting."
    Write-Log "Missing LAB_ADMIN_USERNAME or LAB_ADMIN_PASSWORD."
    return
}
if (-not $tenantId -or -not $subscriptionId) {
    Write-Host "Subscription or Tenant ID missing. Exiting."
    Write-Log "Missing LAB_TENANT_ID or LAB_SUBSCRIPTION_ID."
    return
}
if (-not $clientId -or -not $clientSecret) {
    Write-Host "Service principal clientId/clientSecret missing. Exiting."
    Write-Log "Missing LAB_CLIENT_ID or LAB_CLIENT_SECRET."
    return
}

Write-Host "Lab user: $AdminUserName"
Write-Host "Tenant:  $tenantId"
Write-Host "Sub:     $subscriptionId"
Write-Log  "Environment variables loaded."

try {
    $labCred = New-Object System.Management.Automation.PSCredential(
        $AdminUserName,
        (ConvertTo-SecureString $AdminPassword -AsPlainText -Force)
    )
    $azLoginResult = Connect-AzAccount -Credential $labCred
    Write-Log "Connected to Az using lab credentials."
}
catch {
    Write-Host "Login with lab credentials failed: $($_.Exception.Message)"
    Write-Log  "Lab credentials login failed."
    return
}

$env:AZURE_CLIENT_ID     = $clientId
$env:AZURE_CLIENT_SECRET = $clientSecret
$env:AZURE_TENANT_ID     = $tenantId
$env:AZD_NON_INTERACTIVE = "true"

Write-Log "Logging in with service principal for azd + az."
$azdLoginResult = azd auth login --client-id $clientId --client-secret $clientSecret --tenant-id $tenantId
Write-Log "azd login result: $azdLoginResult"
$azSpLoginResult = az login --service-principal --username $clientId --password $clientSecret --tenant $tenantId
Write-Log "az login result: $($azSpLoginResult | ConvertTo-Json -Depth 3)"

$deployPath = "$HOME\gpt-rag-deploy"
Write-Log "Cleaning deployment folder $deployPath"
Remove-Item -Recurse -Force $deployPath -ErrorAction SilentlyContinue | Out-String | Write-Log
New-Item -ItemType Directory -Path $deployPath -Force | Out-String | Write-Log
Set-Location $deployPath

$env:AZD_SKIP_UPDATE_CHECK = "true"
Write-Host "Initializing GPT-RAG template..."
$azdInitResult = azd init -t azure/gpt-rag -b workshop -e dev-lab
Write-Log "azd init result: $azdInitResult"

Write-Log "Files after azd init:"
Get-ChildItem | ForEach-Object { Write-Log $_.FullName }

Write-Log "Setting subscription to $subscriptionId location eastus2."
azd env set AZURE_SUBSCRIPTION_ID $subscriptionId | Out-String | Write-Log
azd env set AZURE_LOCATION eastus2 | Out-String | Write-Log
azd env set AZURE_NETWORK_ISOLATION false | Out-String | Write-Log
az account set --subscription $subscriptionId | Out-String | Write-Log

Write-Log "Provisioning environment..."
Write-Host "Starting provisioning... this may take several minutes."
$provisionResult = azd provision --environment dev-lab 2>&1 | Tee-Object -FilePath $logFile -Append
Write-Log "azd provision result captured."

if ($provisionResult -match "Key Vault.*already exists in deleted state") {
    Write-Host "Soft-deleted Key Vault exists. Attempting to recover or generate a new name..."
    Write-Log "Detected Key Vault soft-delete issue."

    $kvName = ($provisionResult | Select-String -Pattern "Key Vault: (kv[\w-]+)").Matches.Groups[1].Value
    if ($kvName) {
        try {
            Write-Log "Trying to purge $kvName"
            az keyvault purge --name $kvName --location eastus2 | Out-String | Write-Log
            Start-Sleep -Seconds 15
            Write-Log "Retrying provisioning after purge."
            $retryProvision = azd provision --environment dev-lab 2>&1 | Tee-Object -FilePath $logFile -Append
        }
        catch {
            Write-Host "Purge failed or not permitted. Generating unique Key Vault name..."
            Write-Log "Purge failed for $kvName. Generating a new name."
            $uniqueSuffix = Get-Random -Minimum 1000 -Maximum 9999
            $newKvName = "$kvName$uniqueSuffix"
            Write-Log "Generated new Key Vault name: $newKvName"

            $yamlPath = "$deployPath\azure.yaml"
            (Get-Content $yamlPath) -replace $kvName, $newKvName | Set-Content $yamlPath
            Write-Log "Updated azure.yaml with new Key Vault name."

            Write-Host "Retrying provisioning with updated Key Vault name..."
            $retryProvision = azd provision --environment dev-lab 2>&1 | Tee-Object -FilePath $logFile -Append
        }
        Write-Log "Retry provision result: $retryProvision"
    } else {
        Write-Log "Could not extract Key Vault name from error message."
    }
}

Write-Log "Getting web app URL..."
$resourceGroup  = az group list --query "[?contains(name, 'rg-dev-lab')].name" -o tsv
$webAppName = az resource list --resource-group $resourceGroup --resource-type "Microsoft.Web/sites" --query "[?contains(name, 'webgpt')].name" -o tsv
$webAppUrl  = az webapp show --name $webAppName --resource-group $resourceGroup --query "defaultHostName" -o tsv

Write-Host "Your GPT solution is live at: https://$webAppUrl"
Write-Log  "Deployment complete. URL: https://$webAppUrl"

Write-Host "Done."
Write-Log "Script completed."
