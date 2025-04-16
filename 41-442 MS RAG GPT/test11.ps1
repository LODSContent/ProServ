#
# gpt-rag.ps1 (Latest version with dynamic Key Vault & Cognitive Services names,
#           location support, detailed NI logging, core Bicep validation and forced build,
#           and no what-if deployment preview)
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

# 5) Clone GPT-RAG repo and prepare deployment path
$deployPath = "$HOME\gpt-rag-deploy"
Write-Log "Cloning GPT-RAG repo (agentic branch) into $deployPath"
Remove-Item -Recurse -Force $deployPath -ErrorAction SilentlyContinue | Out-Null
git clone -b agentic https://github.com/Azure/gpt-rag.git $deployPath | Tee-Object -FilePath $logFile -Append
Set-Location $deployPath

# 6.0) Clean up any hook lines (preprovision/predeploy) from azure.yaml
$yamlPath = Join-Path $deployPath "azure.yaml"
if (Test-Path $yamlPath) {
    Write-Log "Cleaning preprovision and predeploy references from azure.yaml..."

    $yamlContent = Get-Content $yamlPath -Raw

    # Remove standalone hook block if present
    $yamlContent = $yamlContent -replace "(?ms)^hooks:.*?(?=^[^\s]|$)", ""

    # Remove any lingering hook lines in service blocks
    $yamlContent = $yamlContent -replace '(?m)^\s*preprovision:.*$', ''
    $yamlContent = $yamlContent -replace '(?m)^\s*predeploy:.*$', ''

    # Remove any host: '' lines that would now be invalid
    $yamlContent = $yamlContent -replace "(?m)^\s*host:\s*''\s*$", ''

    Set-Content -Path $yamlPath -Value $yamlContent -NoNewline
    Write-Log "Sanitized azure.yaml successfully."
} else {
    Write-Log "azure.yaml not found at $yamlPath"
}





# 6) Init GPT-RAG environment from local repo
$env:AZD_SKIP_UPDATE_CHECK = "true"
$env:AZD_NON_INTERACTIVE = "true"
$env:AZD_DEFAULT_YES = "true"
Write-Host "Initializing GPT-RAG template from local repo..."
azd init --environment dev-lab --no-prompt | Tee-Object -FilePath $logFile -Append
Write-Log "azd init complete."

# 6.1) Remove preprovision.ps1 and preDeploy.ps1 to prevent interactive prompts
$infraScriptPath = Join-Path $deployPath "infra\scripts"

$preprovisionPath = Join-Path $infraScriptPath "preprovision.ps1"
if (Test-Path $preprovisionPath) {
    Write-Log "Removing preprovision.ps1 to avoid [Y/n] prompt during provisioning."
    Remove-Item $preprovisionPath -Force
} else {
    Write-Log "preprovision.ps1 not found — skipping."
}

$preDeployPath = Join-Path $infraScriptPath "preDeploy.ps1"
if (Test-Path $preDeployPath) {
    Write-Log "Removing preDeploy.ps1 to avoid [Y/n] prompt during deployment."
    Remove-Item $preDeployPath -Force
} else {
    Write-Log "preDeploy.ps1 not found — skipping."
}

# 6.2) Set AZURE_NETWORK_ISOLATION manually in .env to avoid prompt
Write-Log "Setting AZURE_NETWORK_ISOLATION to true in .env..."
$envDir = Join-Path $deployPath ".azure\dev-lab"
$envFile = Join-Path $envDir ".env"

if (-not (Test-Path $envFile)) {
    Write-Log "[ERROR] Environment .env file not found at $envFile"
} else {
    $envContent = Get-Content $envFile

    function Set-Or-Update-Key($lines, $key, $value) {
        if ($lines -match "^$key=") {
            return $lines -replace "^$key=.*", "$key=$value"
        } else {
            # Append on a new line so that the key is clearly separated
            return $lines + "`n" + "$key=$value"
        }
    }

    $envContent = Set-Or-Update-Key $envContent "AZURE_NETWORK_ISOLATION" "true"
    $envContent | Set-Content $envFile

    Write-Log "AZURE_NETWORK_ISOLATION set to true in .env"
}

# 7) Replace Key Vault name dynamically
$newKvName = "kv-$labInstanceId"
$kvFiles = Get-ChildItem -Recurse -Include *.bicep,*.json -ErrorAction SilentlyContinue
foreach ($file in $kvFiles) {
    (Get-Content $file.FullName) -replace 'kv0-[a-z0-9]+' , $newKvName | Set-Content $file.FullName
    Write-Log "Updated Key Vault name in: $($file.FullName)"
}
azd env set AZURE_KEY_VAULT_NAME $newKvName | Tee-Object -FilePath $logFile -Append
Write-Log "Set AZURE_KEY_VAULT_NAME to $newKvName"

# 7.1) Replace Cognitive Services names dynamically to avoid restoring soft-deleted resources
$uniqueSuffix = (Get-Date -Format "yyyyMMddHHmmss")
$csFiles = Get-ChildItem -Recurse -Include *.bicep,*.json -ErrorAction SilentlyContinue
foreach ($file in $csFiles) {
    $content = Get-Content $file.FullName -Raw
    $newContent = $content -replace 'oai0-[a-z0-9]+', "oai0-$labInstanceId-$uniqueSuffix"
    $newContent = $newContent -replace 'ai0-[a-z0-9]+', "ai0-$labInstanceId-$uniqueSuffix"
    if ($content -ne $newContent) {
        Set-Content $file.FullName $newContent
        Write-Log "Updated Cognitive Services names in: $($file.FullName) to include unique suffix $uniqueSuffix"
    }
}

# 7.2) Validate that all Bicep files are present in the "infra/core" folder
$expectedCount = 30
$coreFolder = Join-Path $deployPath "infra\core"
if (Test-Path $coreFolder) {
    $maxRetries = 5
    $retryCount = 0
    do {
        $coreBicepFiles = Get-ChildItem -Path $coreFolder -Filter *.bicep -Recurse
        if ($coreBicepFiles.Count -ge $expectedCount) {
            break
        }
        Write-Log "Found only $($coreBicepFiles.Count) Bicep file(s) in 'infra/core'. Expected $expectedCount. Retrying in 10 seconds..."
        Start-Sleep -Seconds 10
        $retryCount++
    } while ($retryCount -lt $maxRetries)
    
    if ($coreBicepFiles.Count -lt $expectedCount) {
        Write-Log "[ERROR] Expected $expectedCount Bicep files in 'infra/core', but only found $($coreBicepFiles.Count). Aborting."
        exit 1
    } else {
        Write-Log "Found $($coreBicepFiles.Count) Bicep file(s) in 'infra/core' folder."
        foreach ($file in $coreBicepFiles) {
             Write-Log "Bicep file: $($file.FullName)"
        }
    }
} else {
    Write-Log "[WARNING] 'infra/core' folder not found at $coreFolder"
}

# 7.3) Force all 30 core Bicep files to be used by compiling them
Write-Log "Building all Bicep files in 'infra/core' to force usage..."
foreach ($file in $coreBicepFiles) {
    Write-Log "Building Bicep file: $($file.FullName)"
    $buildOutput = bicep build $file.FullName 2>&1 | Out-String
    Write-Log "Build output for $($file.FullName): $buildOutput"
    if ($buildOutput -match "Error") {
        Write-Log "[ERROR] Building Bicep file $($file.FullName) failed. Aborting."
        exit 1
    }
}
Write-Log "All Bicep files in 'infra/core' built successfully."

# 8) Configure environment
Write-Log "Setting azd environment variables..."
azd env set AZURE_SUBSCRIPTION_ID $subscriptionId | Tee-Object -FilePath $logFile -Append
azd env set AZURE_LOCATION $location | Tee-Object -FilePath $logFile -Append
az account set --subscription $subscriptionId | Tee-Object -FilePath $logFile -Append
Write-Log "Environment configured."

# 9) Provision resources
Write-Log "Provisioning environment..."
Write-Host "Starting provisioning... this may take several minutes."
azd provision --environment dev-lab 2>&1 | Tee-Object -FilePath $logFile -Append
Write-Log "azd provision complete."

# 10) Discover resource group (with retry)
Write-Log "Discovering resource group for AZURE_RESOURCE_GROUP..."
$resourceGroup = $null
$attempts = 0
while (-not $resourceGroup -and $attempts -lt 5) {
    Start-Sleep -Seconds 10
    $resourceGroup = az group list --query "[?contains(name, 'rg-dev-lab')].name" -o tsv
    $attempts++
}
if (-not $resourceGroup) {
    Write-Host "Failed to discover resource group. Exiting."
    Write-Log "Failed to detect resource group. Cannot continue deployment."
    return
}
azd env set AZURE_RESOURCE_GROUP $resourceGroup | Tee-Object -FilePath $logFile -Append
Write-Log "Set AZURE_RESOURCE_GROUP to $resourceGroup"

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

# 14) Output web app URL
Write-Log "Getting web app URL..."
$webAppName = az resource list --resource-group $resourceGroup --resource-type "Microsoft.Web/sites" --query "[?contains(name, 'webgpt')].name" -o tsv
$webAppUrl  = az webapp show --name $webAppName --resource-group $resourceGroup --query "defaultHostName" -o tsv

Write-Host "Your GPT solution is live at: https://$webAppUrl"
Write-Log "Deployment complete. URL: https://$webAppUrl"

Write-Host "Done."
Write-Log "Script completed."
