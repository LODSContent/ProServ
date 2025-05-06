# === Config ===
$repoUrl = "https://github.com/gxjorge/AI-Agents-Lab.git"
$destinationPath = "C:\Users\LabUser\Lab Files"
$repoAzurePath = Join-Path $destinationPath "azure"
$mainBicepPath = Join-Path $repoAzurePath "main.bicep"
$logFile = "C:\Users\LabUser\deployment.log"
$traceLog = "C:\Users\LabUser\git-trace.log"
$username = "@lab.CloudPortalCredential(User1).Username"
$password = '@lab.CloudPortalCredential(User1).Password'

# === Init Logs ===
if (Test-Path $logFile) { Remove-Item -Force $logFile }
if (Test-Path $traceLog) { Remove-Item -Force $traceLog }
"==== DEPLOYMENT STARTED $(Get-Date) ====" | Out-File $logFile

# === Wait for internet connectivity ===
function Wait-ForInternet {
    param ([int]$RetryIntervalSeconds = 5, [int]$MaxRetries = 60)
    $retryCount = 0
    while ($retryCount -lt $MaxRetries) {
        if (Test-Connection -ComputerName 8.8.8.8 -Count 1 -Quiet) {
            Write-Host "Internet connection detected." -ForegroundColor Green
            "Internet connection detected." | Out-File -Append $logFile
            return
        }
        Write-Host "Waiting for internet..." -ForegroundColor Yellow
        "Waiting for internet..." | Out-File -Append $logFile
        Start-Sleep -Seconds $RetryIntervalSeconds
        $retryCount++
    }
    throw "Internet not detected after $($RetryIntervalSeconds * $MaxRetries) seconds."
}
Wait-ForInternet

# === Git Check ===
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    "ERROR: Git not found." | Out-File -Append $logFile
    exit 1
}
"Git found: $(Get-Command git).Source" | Out-File -Append $logFile

try {
    Invoke-WebRequest -Uri "https://github.com" -UseBasicParsing -TimeoutSec 10 | Out-Null
    "GitHub is reachable." | Out-File -Append $logFile
} catch {
    "GitHub not reachable: $_" | Out-File -Append $logFile
}

# === Git Clone with Timeout via Background Job (no $using:) ===
if (Test-Path $destinationPath) {
    Remove-Item -Recurse -Force $destinationPath
    "Removed existing directory $destinationPath" | Out-File -Append $logFile
}

$env:GIT_TERMINAL_PROMPT = "0"
$env:GIT_TRACE = $traceLog
$env:GIT_CURL_VERBOSE = "1"
"Git trace log: $traceLog" | Out-File -Append $logFile

Start-Job -Name GitClone -ScriptBlock {
    param($repoUrl, $destinationPath)
    git clone --single-branch --depth 1 $repoUrl $destinationPath
} -ArgumentList $repoUrl, $destinationPath | Out-Null

$timeout = 60
$elapsed = 0
while ($true) {
    $job = Get-Job -Name GitClone
    if ($job.State -eq 'Completed') {
        Receive-Job -Name GitClone | Tee-Object -Append -FilePath $logFile
        Remove-Job -Name GitClone
        break
    }
    if ($elapsed -ge $timeout) {
        Stop-Job -Name GitClone -Force
        Remove-Job -Name GitClone
        "Git clone timed out after $timeout seconds." | Out-File -Append $logFile
        break
    }
    Start-Sleep -Seconds 2
    $elapsed += 2
}

Start-Sleep -Seconds 2
$gitDir = Join-Path $destinationPath ".git"
if (Test-Path $gitDir) {
    "Git clone verified: .git folder found." | Out-File -Append $logFile
} else {
    "Git clone failed or incomplete: .git folder not found." | Out-File -Append $logFile
}

# === Login to Azure with Lab Credentials (PowerShell 7 safe) ===
$labCred = New-Object System.Management.Automation.PSCredential($username, (ConvertTo-SecureString $password -AsPlainText -Force))
try {
    Connect-AzAccount -Credential $labCred -ErrorAction Stop | Out-Null
    "Connected to Azure." | Out-File -Append $logFile

    $subId = (Get-AzContext).Subscription.Id
    az account set --subscription $subId --only-show-errors 2>&1 | Tee-Object -Append -FilePath $logFile
    "CLI subscription set: $subId" | Out-File -Append $logFile
} catch {
    "Azure login failed: $_" | Out-File -Append $logFile
}

# === Run Bicep Deployment ===
if (Test-Path $mainBicepPath) {
    Set-Location $repoAzurePath
    "Running Bicep deployment..." | Out-File -Append $logFile

    az deployment group create `
        --resource-group agents-lab `
        --template-file main.bicep `
        --only-show-errors 2>&1 | Tee-Object -Append -FilePath $logFile
} else {
    "main.bicep not found. Deployment skipped." | Out-File -Append $logFile
}

# === Validate Deployment ===
try {
    $Deployment = Get-AzResourceGroupDeployment -ResourceGroup agents-lab
    $SucceededCount = ($Deployment | Where-Object { $_.ProvisioningState -eq 'Succeeded' }).Count
    "Succeeded deployments: $SucceededCount" | Out-File -Append $logFile

    if ($SucceededCount -ne 7) {
        "Deployment validation failed: $SucceededCount of 7 succeeded." | Out-File -Append $logFile
    } else {
        "Deployment validation successful: all 7 succeeded." | Out-File -Append $logFile
    }
} catch {
    "Error validating deployment: $_" | Out-File -Append $logFile
}

"==== DEPLOYMENT COMPLETE $(Get-Date) ====" | Out-File -Append $logFile
