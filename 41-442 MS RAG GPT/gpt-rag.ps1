#
# gpt-rag.ps1
#
# Hosted in GitHub. Contains NO Skillable tokens or colons in variable expansions.
# It reads environment variables for lab credentials, service principal, subscription, etc.
# Then it performs the typical GPT-RAG provisioning steps with azd and Azure CLI.
#

# 1) Minimal logging to a file
$logFile = "C:\labfiles\progress.log"
function Write-Log($msg) {
    $stamp = (Get-Date).ToString("yyyy-MM-dd HHmmss")
    Add-Content $logFile "[INFO] $stamp $msg"
}

Write-Log "Script started in GitHub version."

# 2) Pull environment variables (set by Lifecycle Action or other script)
$AdminUserName = $env:LAB_ADMIN_USERNAME
$AdminPassword = $env:LAB_ADMIN_PASSWORD
$tenantId      = $env:LAB_TENANT_ID
$subscriptionId= $env:LAB_SUBSCRIPTION_ID

# If you have a static or separate service principal for azd:
$clientId      = $env:LAB_CLIENT_ID
$clientSecret  = $env:LAB_CLIENT_SECRET

# 3) Basic validations
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

# 4) Login with lab user credentials
try {
    $labCred = New-Object System.Management.Automation.PSCredential(
        $AdminUserName,
        (ConvertTo-SecureString $AdminPassword -AsPlainText -Force)
    )
    Connect-AzAccount -Credential $labCred | Out-Null
    Write-Log "Connected to Az using lab credentials."
}
catch {
    Write-Host "Login with lab credentials failed: $($_.Exception.Message)"
    Write-Log  "Lab credentials login failed."
    return
}

# 5) Scripted login for service principal with azd + az
$env:AZURE_CLIENT_ID     = $clientId
$env:AZURE_CLIENT_SECRET = $clientSecret
$env:AZURE_TENANT_ID     = $tenantId
$env:AZD_NON_INTERACTIVE = "true"


Write-Log "Logging in with service principal for azd + az."
azd auth login --client-id $clientId --client-secret $clientSecret --tenant-id $tenantId
az login --service-principal --username $clientId --password $clientSecret --tenant $tenantId | Out-Null

# 6) Prepare a clean deployment directory
$deployPath = "$HOME\gpt-rag-deploy"
Write-Log "Cleaning deployment folder $deployPath"
Remove-Item -Recurse -Force $deployPath -ErrorAction SilentlyContinue | Out-Null
New-Item -ItemType Directory -Path $deployPath -Force | Out-Null
Set-Location $deployPath

# 7) Basic azd environment setup
$env:AZD_SKIP_UPDATE_CHECK = "true"
Write-Host "Initializing GPT-RAG template..."
azd init -t azure/gpt-rag -b workshop -e dev-lab | Out-Null

#verify that azd init worked
Write-Log "Files after azd init:"
Get-ChildItem | ForEach-Object { Write-Log $_.FullName }


Write-Log "Setting subscription to $subscriptionId location eastus2."
azd env set AZURE_SUBSCRIPTION_ID $subscriptionId | Out-Null
azd env set AZURE_LOCATION eastus2 | Out-Null
azd env set AZURE_NETWORK_ISOLATION true | Out-Null
az account set --subscription $subscriptionId | Out-Null


Write-Log "Provisioning environment..."
#azd provision --environment dev-lab | Out-Null
#azd provision --environment dev-lab 2>&1 | Tee-Object -FilePath $logFile -Append

Write-Host "Starting provisioning... this may take several minutes."
azd provision --environment dev-lab 2>&1 | Tee-Object -FilePath $logFile -Append
Write-Host "Provisioning complete."




Write-Log "Deploying environment..."
#azd deploy --environment dev-lab | Out-Null
azd deploy --environment dev-lab 2>&1 | Tee-Object -FilePath $logFile -Append


# # 8) Post-Deployment Resource Discovery
# Write-Log "Discovering resource names..."
# $resourceGroup  = az resource list --resource-type "Microsoft.Storage/storageAccounts" --query "[0].resourceGroup" -o tsv
# $storageAccount = az resource list --resource-group $resourceGroup --resource-type "Microsoft.Storage/storageAccounts" --query "sort_by([?type=='Microsoft.Storage/storageAccounts'], &length(name))[0].name" -o tsv
# $ingestionFunc  = az resource list --resource-group $resourceGroup --resource-type "Microsoft.Web/sites" --query "[?contains(name, 'inges')].name" -o tsv
# $orchestratorFunc = az resource list --resource-group $resourceGroup --resource-type "Microsoft.Web/sites" --query \"[?contains(name, 'orch')].name\" -o tsv
# $searchService  = az resource list --resource-group $resourceGroup --resource-type "Microsoft.Search/searchServices" --query "[0].name" -o tsv

# Write-Host "Resource group: $resourceGroup"
# Write-Log "Resource group discovered: $resourceGroup"

# # 9) Assign Storage Blob Data Contributor to SP
# Write-Log "Assigning Storage Blob Data Contributor role."
# $objectId = az ad sp show --id $clientId --query id -o tsv
# az role assignment create --assignee-object-id $objectId --assignee-principal-type ServicePrincipal --role "Storage Blob Data Contributor" --scope "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Storage/storageAccounts/$storageAccount" | Out-Null

# # 10) Update function apps for multimodal
# Write-Log "Updating function apps for multimodal config."
# az functionapp config appsettings set --name $ingestionFunc   --resource-group $resourceGroup --settings MULTIMODAL=true | Out-Null
# az functionapp restart --name $ingestionFunc   --resource-group $resourceGroup | Out-Null

# az functionapp config appsettings set --name $orchestratorFunc --resource-group $resourceGroup --settings AUTOGEN_ORCHESTRATION_STRATEGY=multimodal_rag | Out-Null
# az functionapp restart --name $orchestratorFunc --resource-group $resourceGroup | Out-Null

# # 11) Ingest a sample PDF (if the VM has outbound Internet)
# Write-Log "Downloading PDF from GitHub..."
# $pdfUrl  = "https://raw.githubusercontent.com/Azure/GPT-RAG/insiders/datasources/surface-pro-4-user-guide-EN.pdf"
# $pdfPath = "$env:TEMP\surface-pro-4-user-guide-EN.pdf"

# try {
#     Invoke-WebRequest -Uri $pdfUrl -OutFile $pdfPath
#     az storage blob upload --account-name $storageAccount --container-name documents --name surface-pro-4-user-guide-EN.pdf --file $pdfPath --auth-mode login --overwrite | Out-Null
#     Write-Log "PDF uploaded to 'documents' container."
# }
# catch {
#     Write-Host "PDF ingestion error: $($_.Exception.Message)"
#     Write-Log "Failed to ingest PDF."
# }

# 12) Output final web app URL
Write-Log "Getting web app URL..."
$webAppName = az resource list --resource-group $resourceGroup --resource-type "Microsoft.Web/sites" --query "[?contains(name, 'webgpt')].name" -o tsv
$webAppUrl  = az webapp show --name $webAppName --resource-group $resourceGroup --query "defaultHostName" -o tsv

Write-Host "Your GPT solution is live at: https://$webAppUrl"
Write-Log  "Deployment complete. URL: https://$webAppUrl"

Write-Host "Done."
Write-Log "Script completed."
