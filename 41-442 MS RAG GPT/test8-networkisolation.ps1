#
# gpt-rag.ps1 (Complete script with validation and post-deployment steps)
#

$logFile = "C:\labfiles\progress.log"
function Write-Log($msg) {
    $stamp = (Get-Date).ToString("yyyy-MM-dd HHmmss")
    Add-Content $logFile "[INFO] $stamp $msg"
}

Write-Log "Script started in GitHub version."

# Pull environment variables
$AdminUserName  = $env:LAB_ADMIN_USERNAME
$AdminPassword  = $env:LAB_ADMIN_PASSWORD
$tenantId       = $env:LAB_TENANT_ID
$subscriptionId = $env:LAB_SUBSCRIPTION_ID
$clientId       = $env:LAB_CLIENT_ID
$clientSecret   = $env:LAB_CLIENT_SECRET
$labInstanceId  = $env:LAB_INSTANCE_ID
$location       = $env:LAB_LOCATION
if (-not $location) { $location = "eastus2" }

# Validate
if (-not $AdminUserName -or -not $AdminPassword) { Write-Log "Missing LAB_ADMIN_USERNAME or LAB_ADMIN_PASSWORD."; return }
if (-not $tenantId -or -not $subscriptionId) { Write-Log "Missing LAB_TENANT_ID or LAB_SUBSCRIPTION_ID."; return }
if (-not $clientId -or -not $clientSecret) { Write-Log "Missing LAB_CLIENT_ID or LAB_CLIENT_SECRET."; return }
if (-not $labInstanceId) { Write-Log "Missing LAB_INSTANCE_ID."; return }
Write-Log "Environment variables validated."

# Connect with lab credentials
try {
    $labCred = New-Object System.Management.Automation.PSCredential($AdminUserName, (ConvertTo-SecureString $AdminPassword -AsPlainText -Force))
    Connect-AzAccount -Credential $labCred | Out-Null
    Write-Log "Connected to Az using lab credentials."
} catch {
    Write-Log "Login with lab credentials failed."; return
}

# Login as SP
$env:AZURE_CLIENT_ID     = $clientId
$env:AZURE_CLIENT_SECRET = $clientSecret
$env:AZURE_TENANT_ID     = $tenantId
$env:AZD_NON_INTERACTIVE = "true"
$env:LAB_INSTANCE_ID     = $labInstanceId
azd auth login --client-id $clientId --client-secret $clientSecret --tenant-id $tenantId | Out-Null
az login --service-principal --username $clientId --password $clientSecret --tenant $tenantId | Out-Null
azd env set AZURE_NETWORK_ISOLATION true | Out-Null
Write-Log "Logged in with service principal."

# Quota and Role Check
Write-Log "Checking OpenAI S0 quota and SP roles..."
$roles = az role assignment list --assignee $clientId --query "[].roleDefinitionName" -o tsv
if ($roles -notmatch "Contributor|Owner") { Write-Log "SP missing Contributor/Owner role." }
else { Write-Log "SP role assignment OK." }

# Setup workspace
$deployPath = "$HOME\gpt-rag-deploy"
Remove-Item -Recurse -Force $deployPath -ErrorAction SilentlyContinue | Out-Null
New-Item -ItemType Directory -Path $deployPath -Force | Out-Null
Set-Location $deployPath
$env:AZD_SKIP_UPDATE_CHECK = "true"
azd init -t azure/gpt-rag -b workshop -e dev-lab | Out-Null
Write-Log "azd init complete."

# Key Vault patch
$newKvName = "kv-$labInstanceId"
$kvFiles = Get-ChildItem -Recurse -Include *.bicep,*.json -ErrorAction SilentlyContinue
foreach ($file in $kvFiles) {
    (Get-Content $file.FullName) -replace 'kv0-[a-z0-9]+' , $newKvName | Set-Content $file.FullName
    Write-Log "Updated Key Vault name in: $($file.FullName)"
}
azd env set AZURE_KEY_VAULT_NAME $newKvName | Out-Null
Write-Log "Set AZURE_KEY_VAULT_NAME to $newKvName"

# Configure
azd env set AZURE_SUBSCRIPTION_ID $subscriptionId | Out-Null
azd env set AZURE_LOCATION $location | Out-Null
#azd env set AZURE_NETWORK_ISOLATION true | Out-Null
az account set --subscription $subscriptionId | Out-Null
Write-Log "Environment configured."

# Provision
Write-Log "Provisioning environment..."
azd provision --environment dev-lab 2>&1 | Tee-Object -FilePath $logFile -Append
Write-Log "Provision complete."

# Discover RG
$resourceGroup = az group list --query "[?contains(name, 'rg-dev-lab')].name" -o tsv
if (-not $resourceGroup) { Write-Log "RG discovery failed."; return }
azd env set AZURE_RESOURCE_GROUP $resourceGroup | Out-Null
Write-Log "AZURE_RESOURCE_GROUP set to $resourceGroup"

# Deploy
Write-Log "Deploying environment..."
azd deploy --environment dev-lab 2>&1 | Tee-Object -FilePath $logFile -Append
Write-Log "Deployment complete."

# Post-Deployment Discovery
Write-Log "Discovering deployed resources..."
$storageAccount = az resource list --resource-group $resourceGroup --resource-type "Microsoft.Storage/storageAccounts" --query "[0].name" -o tsv
$ingestionFunc  = az resource list --resource-group $resourceGroup --resource-type "Microsoft.Web/sites" --query "[?contains(name, 'inges')].name" -o tsv
$orchestratorFunc = az resource list --resource-group $resourceGroup --resource-type "Microsoft.Web/sites" --query "[?contains(name, 'orch')].name" -o tsv

# Assign role
Write-Log "Assigning Storage Blob Data Contributor..."
$objectId = az ad sp show --id $clientId --query id -o tsv
az role assignment create --assignee-object-id $objectId --assignee-principal-type ServicePrincipal --role "Storage Blob Data Contributor" --scope "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Storage/storageAccounts/$storageAccount" | Out-Null

# Multimodal config
Write-Log "Configuring function apps for multimodal..."
az functionapp config appsettings set --name $ingestionFunc --resource-group $resourceGroup --settings MULTIMODAL=true | Out-Null
az functionapp restart --name $ingestionFunc --resource-group $resourceGroup | Out-Null
az functionapp config appsettings set --name $orchestratorFunc --resource-group $resourceGroup --settings AUTOGEN_ORCHESTRATION_STRATEGY=multimodal_rag | Out-Null
az functionapp restart --name $orchestratorFunc --resource-group $resourceGroup | Out-Null

# Upload PDF
Write-Log "Uploading test PDF..."
$pdfUrl  = "https://raw.githubusercontent.com/Azure/GPT-RAG/insiders/datasources/surface-pro-4-user-guide-EN.pdf"
$pdfPath = "$env:TEMP\surface-pro-4-user-guide-EN.pdf"
try {
    Invoke-WebRequest -Uri $pdfUrl -OutFile $pdfPath
    az storage blob upload --account-name $storageAccount --container-name documents --name surface-pro-4-user-guide-EN.pdf --file $pdfPath --auth-mode login --overwrite | Out-Null
    Write-Log "PDF uploaded."
} catch {
    Write-Log "PDF upload failed: $($_.Exception.Message)"
}

# Web app output
$webAppName = az resource list --resource-group $resourceGroup --resource-type "Microsoft.Web/sites" --query "[?contains(name, 'webgpt')].name" -o tsv
$webAppUrl  = az webapp show --name $webAppName --resource-group $resourceGroup --query "defaultHostName" -o tsv
Write-Host "Your GPT solution is live at: https://$webAppUrl"
Write-Log "Deployment complete. URL: https://$webAppUrl"

Write-Host "Done."
Write-Log "Script completed."
