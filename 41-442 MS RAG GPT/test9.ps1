#
# gpt-rag.ps1 (Latest version with dynamic Key Vault, location support, and detailed NI logging)
#

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

Write-Host "User: $AdminUserName"
Write-Host "Tenant: $tenantId"
Write-Host "Subscription: $subscriptionId"
Write-Host "Lab ID: $labInstanceId"
Write-Host "Location: $location"
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

Write-Log "Logging in with service principal."
azd auth login --client-id $clientId --client-secret $clientSecret --tenant-id $tenantId | Tee-Object -FilePath $logFile -Append
az login --service-principal --username $clientId --password $clientSecret --tenant $tenantId | Tee-Object -FilePath $logFile -Append

# 5) Clean deployment path
$deployPath = "$HOME\gpt-rag-deploy"
Write-Log "Cleaning deployment folder $deployPath"
Remove-Item -Recurse -Force $deployPath -ErrorAction SilentlyContinue | Out-Null
New-Item -ItemType Directory -Path $deployPath -Force | Out-Null
Set-Location $deployPath

# 6) Init GPT-RAG template
$env:AZD_SKIP_UPDATE_CHECK = "true"
$env:AZD_NON_INTERACTIVE = "true"
$env:AZD_DEFAULT_YES = "true"
Write-Host "Initializing GPT-RAG template..."
azd init -t azure/gpt-rag -b workshop -e dev-lab --no-prompt | Tee-Object -FilePath $logFile -Append
Write-Log "azd init complete."

# 6.1) Set AZURE_NETWORK_ISOLATION = true
Write-Log "Setting AZURE_NETWORK_ISOLATION to true..."
$niResult = azd env set "AZURE_NETWORK_ISOLATION" "true" --no-prompt 2>&1 | Tee-Object -FilePath $logFile -Append

if ($niResult -match 'Usage\s+azd env') {
    Write-Log "[ERROR] azd env set failed – command returned help text. Possible quoting issue or azd version mismatch."
} elseif ($niResult -match '\[Y/n\]') {
    Write-Log "[ERROR] azd env set unexpectedly prompted for confirmation. Ensure --no-prompt is working correctly."
} else {
    Write-Log "azd env set AZURE_NETWORK_ISOLATION completed successfully."
}

$niConfirm = azd env get-value "AZURE_NETWORK_ISOLATION" --no-prompt 2>&1
Write-Log "Confirmed AZURE_NETWORK_ISOLATION value: $niConfirm"



# 7) Replace Key Vault name dynamically
$newKvName = "kv-$labInstanceId"
$kvFiles = Get-ChildItem -Recurse -Include *.bicep,*.json -ErrorAction SilentlyContinue
foreach ($file in $kvFiles) {
    (Get-Content $file.FullName) -replace 'kv0-[a-z0-9]+' , $newKvName | Set-Content $file.FullName
    Write-Log "Updated Key Vault name in: $($file.FullName)"
}
azd env set AZURE_KEY_VAULT_NAME $newKvName | Tee-Object -FilePath $logFile -Append
Write-Log "Set AZURE_KEY_VAULT_NAME to $newKvName"

# 8) Configure environment
Write-Log "Setting azd environment variables..."
azd env set AZURE_SUBSCRIPTION_ID $subscriptionId | Tee-Object -FilePath $logFile -Append
azd env set AZURE_LOCATION $location | Tee-Object -FilePath $logFile -Append
#azd env set AZURE_NETWORK_ISOLATION true | Tee-Object -FilePath $logFile -Append
az account set --subscription $subscriptionId | Tee-Object -FilePath $logFile -Append
Write-Log "Environment configured."

# 9) Provision resources
Write-Log "Provisioning environment..."
Write-Host "Starting provisioning... this may take several minutes."
azd provision --environment dev-lab 2>&1 | Tee-Object -FilePath $logFile -Append
Write-Log "azd provision complete."

# Discover RG
Write-Log "Discovering resource group for AZURE_RESOURCE_GROUP..."
$resourceGroup = az group list --query "[?contains(name, 'rg-dev-lab')].name" -o tsv
if (-not $resourceGroup) {
    Write-Host "Failed to discover resource group. Exiting."
    Write-Log "Failed to detect resource group. Cannot continue deployment."
    return
}
azd env set AZURE_RESOURCE_GROUP $resourceGroup | Tee-Object -FilePath $logFile -Append
Write-Log "Set AZURE_RESOURCE_GROUP to $resourceGroup"

# 10) Deploy
Write-Log "Deploying environment..."
azd deploy --environment dev-lab 2>&1 | Tee-Object -FilePath $logFile -Append

# 11) Post-Deployment Resource Discovery
Write-Log "Discovering deployed resources..."
$storageAccount = az resource list --resource-group $resourceGroup --resource-type "Microsoft.Storage/storageAccounts" --query "sort_by([?type=='Microsoft.Storage/storageAccounts'], &length(name))[0].name" -o tsv
$ingestionFunc  = az resource list --resource-group $resourceGroup --resource-type "Microsoft.Web/sites" --query "[?contains(name, 'inges')].name" -o tsv
$orchestratorFunc = az resource list --resource-group $resourceGroup --resource-type "Microsoft.Web/sites" --query "[?contains(name, 'orch')].name" -o tsv

# 12) Assign Storage Blob Data Contributor
Write-Log "Assigning role: Storage Blob Data Contributor..."
$objectId = az ad sp show --id $clientId --query id -o tsv
az role assignment create --assignee-object-id $objectId --assignee-principal-type ServicePrincipal --role "Storage Blob Data Contributor" --scope "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Storage/storageAccounts/$storageAccount" | Out-Null

# 13) Update Function Apps
Write-Log "Updating function app settings..."
az functionapp config appsettings set --name $ingestionFunc --resource-group $resourceGroup --settings MULTIMODAL=true | Out-Null
az functionapp restart --name $ingestionFunc --resource-group $resourceGroup | Out-Null
az functionapp config appsettings set --name $orchestratorFunc --resource-group $resourceGroup --settings AUTOGEN_ORCHESTRATION_STRATEGY=multimodal_rag | Out-Null
az functionapp restart --name $orchestratorFunc --resource-group $resourceGroup | Out-Null

# 14) Ingest PDF
Write-Log "Ingesting PDF to documents container..."
$pdfUrl  = "https://raw.githubusercontent.com/Azure/GPT-RAG/insiders/datasources/surface-pro-4-user-guide-EN.pdf"
$pdfPath = "$env:TEMP\surface-pro-4-user-guide-EN.pdf"
try {
    Invoke-WebRequest -Uri $pdfUrl -OutFile $pdfPath
    az storage blob upload --account-name $storageAccount --container-name documents --name surface-pro-4-user-guide-EN.pdf --file $pdfPath --auth-mode login --overwrite | Out-Null
    Write-Log "PDF uploaded successfully."
} catch {
    Write-Log "PDF ingestion failed: $($_.Exception.Message)"
}

# 15) Output web app URL
Write-Log "Getting web app URL..."
$webAppName = az resource list --resource-group $resourceGroup --resource-type "Microsoft.Web/sites" --query "[?contains(name, 'webgpt')].name" -o tsv
$webAppUrl  = az webapp show --name $webAppName --resource-group $resourceGroup --query "defaultHostName" -o tsv

Write-Host "Your GPT solution is live at: https://$webAppUrl"
Write-Log  "Deployment complete. URL: https://$webAppUrl"

Write-Host "Done."
Write-Log "Script completed."
