# === [1] Logging Setup ===
$logDir     = "C:\labfiles"
$progressLog = Join-Path $logDir "progress.log"
$azdLog      = Join-Path $logDir "azd.log"

function Write-Log($msg) {
    $stamp = (Get-Date).ToString("yyyy-MM-dd HHmmss")
    Add-Content $progressLog "[INFO] $stamp $msg"
}

Write-Log "Script started (GitHub version)"

# === [2] Environment Variables ===
$AdminUserName  = $env:LAB_ADMIN_USERNAME
$AdminPassword  = $env:LAB_ADMIN_PASSWORD
$tenantId       = $env:LAB_TENANT_ID
$subscriptionId = $env:LAB_SUBSCRIPTION_ID
$clientId       = $env:LAB_CLIENT_ID
$clientSecret   = $env:LAB_CLIENT_SECRET

if (-not $AdminUserName -or -not $AdminPassword) { Write-Log "Missing LAB_ADMIN_USERNAME or LAB_ADMIN_PASSWORD."; return }
if (-not $tenantId -or -not $subscriptionId)     { Write-Log "Missing LAB_TENANT_ID or LAB_SUBSCRIPTION_ID."; return }
if (-not $clientId -or -not $clientSecret)       { Write-Log "Missing LAB_CLIENT_ID or LAB_CLIENT_SECRET."; return }

Write-Log "Environment variables loaded."

# === [3] Lab Credential Login ===
try {
    $labCred = New-Object System.Management.Automation.PSCredential(
        $AdminUserName,
        (ConvertTo-SecureString $AdminPassword -AsPlainText -Force)
    )
    Connect-AzAccount -Credential $labCred | Out-Null
    Write-Log "Connected to Az using lab credentials."
} catch {
    Write-Log "Lab credentials login failed: $($_.Exception.Message)"
    return
}

# === [4] SP Login for azd ===
$env:AZURE_CLIENT_ID     = $clientId
$env:AZURE_CLIENT_SECRET = $clientSecret
$env:AZURE_TENANT_ID     = $tenantId
$env:AZD_NON_INTERACTIVE = "true"

Write-Log "Authenticating with service principal for azd and az CLI..."
azd auth login --client-id $clientId --client-secret $clientSecret --tenant-id $tenantId | Out-Null
az login --service-principal --username $clientId --password $clientSecret --tenant $tenantId | Out-Null

# === [5] Prepare Deployment Folder ===
$deployPath = "$HOME\gpt-rag-deploy"
Write-Log "Setting up deployment folder at: $deployPath"
Remove-Item -Recurse -Force $deployPath -ErrorAction SilentlyContinue | Out-Null
New-Item -ItemType Directory -Path $deployPath -Force | Out-Null
Set-Location $deployPath

# === [6] azd Init ===
Write-Log "Initializing Azure Developer CLI template..."
azd init -t azure/gpt-rag -b workshop -e dev-lab | Tee-Object -FilePath $azdLog -Append

# === [7] Validate SP Roles ===
Write-Log "Validating service principal role assignments..."
$requiredRoles = @("Contributor", "Network Contributor", "Private DNS Zone Contributor")
$spObjectId = az ad sp show --id $clientId --query id -o tsv
if (-not $spObjectId) { Write-Log "Could not resolve SP object ID."; return }

foreach ($role in $requiredRoles) {
    $hasRole = az role assignment list `
        --assignee-object-id $spObjectId `
        --subscription $subscriptionId `
        --query "[?roleDefinitionName=='$role']" `
        -o json | ConvertFrom-Json

    if (-not $hasRole) {
        Write-Log "Missing role: $role. Assigning..."
        az role assignment create `
            --assignee-object-id $spObjectId `
            --role "$role" `
            --scope "/subscriptions/$subscriptionId" | Tee-Object -FilePath $azdLog -Append
        Write-Log "Assigned role: $role"
    } else {
        Write-Log "SP already has role: $role"
    }
}

# === [8] Outbound Connectivity Check ===
Write-Log "Testing outbound internet and DNS resolution..."
$testUrls = @(
    "https://management.azure.com",
    "https://www.azure.com",
    "https://blob.core.windows.net"
)
$failures = @()

foreach ($url in $testUrls) {
    try {
        Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 10 | Out-Null
        Write-Log "Outbound OK: $url"
    } catch {
        Write-Log "Outbound FAIL: $url"
        $failures += $url
    }
}

try {
    Resolve-DnsName -Server 168.63.129.16 "microsoft.com" | Out-Null
    Write-Log "DNS test passed (168.63.129.16)"
} catch {
    Write-Log "DNS test failed (168.63.129.16)"
    $failures += "DNS"
}

if ($failures.Count -gt 0) {
    Write-Log "WARNING: Outbound connectivity failed for: $($failures -join ', ')"
    Write-Host "`n[WARNING] Outbound connectivity failed for: $($failures -join ', ')"
    Write-Host "Continuing — assuming VM is within a private network using Private Endpoints."
}

# === [9] Configure azd Environment ===
Write-Log "Setting azd environment variables..."
azd env set AZURE_SUBSCRIPTION_ID $subscriptionId | Out-Null
azd env set AZURE_LOCATION eastus2 | Out-Null
azd env set AZURE_NETWORK_ISOLATION false | Out-Null
az account set --subscription $subscriptionId | Out-Null

# === [10] Provision Infrastructure ===
Write-Log "Provisioning infrastructure with azd..."
azd provision --environment dev-lab 2>&1 | Tee-Object -FilePath $azdLog -Append

## === [11] Deploy Application Code ===
#Write-Log "Deploying GPT-RAG application with azd..."
#azd deploy --environment dev-lab 2>&1 | Tee-Object -FilePath $azdLog -Append

# === [12] Output Web App URL ===
Write-Log "Retrieving Web App endpoint..."
$resourceGroup  = az group list --query "[?contains(name, 'gpt')].name" -o tsv
$webAppName     = az resource list --resource-group $resourceGroup --resource-type "Microsoft.Web/sites" --query "[?contains(name, 'webgpt')].name" -o tsv
$webAppUrl      = az webapp show --name $webAppName --resource-group $resourceGroup --query "defaultHostName" -o tsv

if ($webAppUrl) {
    Write-Log "Deployment complete: https://$webAppUrl"
    Write-Host "`nYour GPT solution is live at: https://$webAppUrl"
} else {
    Write-Log "Deployment finished but could not resolve Web App URL."
    Write-Host "Deployment finished but Web App URL could not be resolved."
}

Write-Log "Script completed."
Write-Host "Done."
