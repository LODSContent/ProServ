# LCA_RunRAGGitHubScript_WithWait.ps1

$transcriptPath = "C:\labfiles\transcript.log"
$progressLog    = "C:\labfiles\progress.log"
$scriptUrl      = "https://raw.githubusercontent.com/LODSContent/ProServ/refs/heads/main/41-442%20MS%20RAG%20GPT/test5.ps1"
$labInstanceId  = "@lab.LabInstance.Id"

# Ensure a labfiles folder exists
if (-not (Test-Path "C:\labfiles")) {
    New-Item -Path "C:\labfiles" -ItemType Directory | Out-Null
}

# Clear old logs
Remove-Item $transcriptPath, $progressLog -ErrorAction SilentlyContinue

# Start transcript
Start-Transcript -Path $transcriptPath -IncludeInvocationHeader -Force

# --------------------------------------------------
# [1] WAIT LOOP FOR INTERNET
# --------------------------------------------------
$destination = "github.com"
$maxAttempts = 5
$attempt     = 0
$haveInternet= $false

while (-not $haveInternet -and $attempt -lt $maxAttempts) {
    $ping = Test-Connection $destination -Count 1 -Quiet
    if ($ping) {
        $haveInternet = $true
    } else {
        $attempt++
        Write-Host "No internet on attempt $attempt of $maxAttempts. Waiting 15 seconds..."
        Add-Content $progressLog "[INFO] No internet on attempt $attempt of $maxAttempts. Waiting 15 seconds..."
        Start-Sleep -Seconds 15
    }
}

if ($haveInternet) {
    Write-Host "Internet connectivity confirmed."
    Add-Content $progressLog "[INFO] Internet connectivity confirmed."
} else {
    Write-Warning "No internet after $maxAttempts attempts. Continuing anyway."
    Add-Content $progressLog "[WARNING] No internet after $maxAttempts attempts. Continuing..."
}

# --------------------------------------------------
# [2] GET TOKENS FOR LAB CREDENTIALS
# --------------------------------------------------
$adminUser    = '@lab.CloudPortalCredential(User1).Username'
$adminPass    = '@lab.CloudPortalCredential(User1).Password'
$tenantId     = '@lab.CloudSubscription.TenantId'
$subscription = '@lab.CloudSubscription.Id'
$location     = "eastus2"  # Optional: Use Skillable token here if available

# Verify tokens were replaced
if ($adminUser -like '@lab.*' -or $subscription -like '@lab.*') {
    Write-Host "Tokens not replaced. Exiting."
    Add-Content $progressLog "[ERROR] Tokens not replaced."
    Stop-Transcript
    return
}

Add-Content $progressLog "[INFO] Lab tokens replaced. User=$adminUser, Sub=$subscription, Tenant=$tenantId"

# --------------------------------------------------
# [3] DOWNLOAD RAW GITHUB SCRIPT (NO TOKENS)
# --------------------------------------------------
Write-Host "Downloading script from: $scriptUrl"
try {
    $rawScript = (Invoke-WebRequest -Uri $scriptUrl -UseBasicParsing).Content
    Add-Content $progressLog "[INFO] Downloaded script from GitHub."
}
catch {
    Write-Host "Failed to download script: $($_.Exception.Message)"
    Add-Content $progressLog "[ERROR] Download script failed: $($_.Exception.Message)"
    Stop-Transcript
    return
}

# --------------------------------------------------
# [4] BUILD PROCESSSTARTINFO AND PASS ENV VARS
# --------------------------------------------------
$startInfo = New-Object System.Diagnostics.ProcessStartInfo
$startInfo.FileName  = "pwsh.exe"
$startInfo.Arguments = "-NoProfile -EncodedCommand REPLACE_ME"
$startInfo.UseShellExecute = $false
$startInfo.RedirectStandardOutput = $false
$startInfo.RedirectStandardError  = $false

# Environment variables for the GitHub script
$startInfo.Environment["LAB_ADMIN_USERNAME"]  = $adminUser
$startInfo.Environment["LAB_ADMIN_PASSWORD"]  = $adminPass
$startInfo.Environment["LAB_TENANT_ID"]       = $tenantId
$startInfo.Environment["LAB_SUBSCRIPTION_ID"] = $subscription
$startInfo.Environment["LAB_CLIENT_ID"]       = "45587fa8-5f05-46d9-8d71-595d74062152"
$startInfo.Environment["LAB_CLIENT_SECRET"]   = "qw5148hvEKmywm9J4RVdUcdAxkD2bxEPRhRfseNRYcQ="
$startInfo.Environment["LAB_INSTANCE_ID"]     = $labInstanceId
$startInfo.Environment["LAB_LOCATION"]        = $location

# --------------------------------------------------
# [5] ENCODE THE SCRIPT FOR pwsh -EncodedCommand
# --------------------------------------------------
$bytes   = [System.Text.Encoding]::Unicode.GetBytes($rawScript)
$encoded = [Convert]::ToBase64String($bytes)
$startInfo.Arguments = "-NoProfile -EncodedCommand $encoded"

Add-Content $progressLog "[INFO] Prepared script for pwsh -EncodedCommand."

# --------------------------------------------------
# [6] LAUNCH THE SCRIPT
# --------------------------------------------------
try {
    $proc = [System.Diagnostics.Process]::Start($startInfo)
    Add-Content $progressLog "[INFO] GitHub script launched. PID=$($proc.Id)"

    while (-not $proc.HasExited) {
        Write-Host "GitHub script (PID=$($proc.Id)) is running $(Get-Date)"
        Start-Sleep 5
    }

    Add-Content $progressLog "[INFO] Script completed at $(Get-Date)"
    Write-Host "Script finished."
}
catch {
    Write-Warning "Failed to launch the GitHub script."
    Add-Content $progressLog "[ERROR] $($_.Exception.Message)"
}

Stop-Transcript
