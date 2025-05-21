First Displayable target VM

Add user to security group v1 w/logging 
Execute Script in Virtual Machine
Machine	Base VM
Language	PowerShell
Blocking	No
Timeout	10 Minutes
Retries	0
Error Action	Log
# === Variables ===
$username = "@lab.CloudPortalCredential(User1).Username"
$password = '@lab.CloudPortalCredential(User1).Password'
$subscription = "@lab.CloudSubscription.Id"
$tenantId = "@lab.CloudSubscription.TenantId"

# Group target - use Object ID for direct reference
$targetGroupObjectId = "405fc830-4d93-4a50-8c7a-277879031b36"  # From Azure portal screenshot

# Service Principal details
$appId = "0c85b887-c9e6-4b51-86ba-89da36dbdff4"
$appSecret = "VR.8Q~5bzjb0HL3AJwCH4kUJq3ZMiG-VjuEOjc~K"

# Setup logging
$logFile = Join-Path "C:\Users\Admin\Desktop" "AzureGroupAddition_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$ErrorActionPreference = "Continue"  # Allow script to continue on errors

# Function for consistent logging to both console and file
function Write-Log {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Message,

        [Parameter(Mandatory=$false)]
        [ValidateSet("INFO", "WARNING", "ERROR", "SUCCESS", "DEBUG")]
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"

    # Define colors for console output
    $colors = @{
        "INFO" = "White"
        "WARNING" = "Yellow"
        "ERROR" = "Red"
        "SUCCESS" = "Green"
        "DEBUG" = "Cyan"
    }

    # Write to console with color
    Write-Host $logEntry -ForegroundColor $colors[$Level]

    # Write to log file
    Add-Content -Path $logFile -Value $logEntry
}

# Initialize log file with header
"=== Script Execution Started at $(Get-Date) ===" | Out-File -FilePath $logFile -Force
Write-Log "Log file initialized at: $logFile" -Level "INFO"
Write-Log "Script started with target user: $username" -Level "INFO"
Write-Log "Targeting subscription: $subscription" -Level "INFO"
Write-Log "Targeting tenant: $tenantId" -Level "INFO"
Write-Log "Targeting group Object ID: $targetGroupObjectId" -Level "INFO"
Write-Log "Using Service Principal (App ID): $appId" -Level "INFO"

# We'll use Microsoft Graph REST API directly with auth token
# This approach doesn't require installing any PowerShell modules
Write-Log "Getting authentication token via REST API" -Level "INFO"

try {
    # Construct the token request
    $tokenUri = "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token"
    $tokenBody = @{
        client_id     = $appId
        scope         = "https://graph.microsoft.com/.default"
        client_secret = $appSecret
        grant_type    = "client_credentials"
    }

    # Get the token
    $tokenResponse = Invoke-RestMethod -Uri $tokenUri -Method Post -Body $tokenBody
    $token = $tokenResponse.access_token
    
    Write-Log "Successfully acquired authentication token" -Level "SUCCESS"
} catch {
    Write-Log "Failed to get authentication token: $_" -Level "ERROR"
    Write-Log "Check your App ID, Client Secret, and Tenant ID" -Level "ERROR"
    exit 1
}

# Set up headers for all Graph API calls
$headers = @{
    "Authorization" = "Bearer $token"
    "Content-Type"  = "application/json"
}

# Get group details
Write-Log "Verifying group exists" -Level "INFO"
try {
    $groupResponse = Invoke-RestMethod -Method Get -Uri "https://graph.microsoft.com/v1.0/groups/$targetGroupObjectId" -Headers $headers
    Write-Log "Group found: $($groupResponse.displayName) (ID: $($groupResponse.id))" -Level "SUCCESS"
} catch {
    Write-Log "Error: Group not found - $_" -Level "ERROR"
    exit 1
}

# Get user details
Write-Log "Looking up user details" -Level "INFO"
try {
    $userResponse = Invoke-RestMethod -Method Get -Uri "https://graph.microsoft.com/v1.0/users?`$filter=userPrincipalName eq '$username'" -Headers $headers
    
    if ($userResponse.value.Count -eq 0) {
        Write-Log "User $username not found" -Level "ERROR"
        exit 1
    }
    
    $user = $userResponse.value[0]
    Write-Log "User found: $($user.displayName) (ID: $($user.id))" -Level "SUCCESS"
} catch {
    Write-Log "Error looking up user: $_" -Level "ERROR"
    exit 1
}

# Check if user is already a member of the group
Write-Log "Checking if user is already a member of the group" -Level "INFO"
try {
    $membersResponse = Invoke-RestMethod -Method Get -Uri "https://graph.microsoft.com/v1.0/groups/$targetGroupObjectId/members" -Headers $headers
    $members = $membersResponse.value
    
    # Check for user in the current members list
    $isAlreadyMember = $members | Where-Object { $_.id -eq $user.id }
    
    if ($isAlreadyMember) {
        Write-Log "User is already a member of the group" -Level "WARNING"
        $success = $true
    } else {
        # Add user to group
        Write-Log "Adding user to group" -Level "INFO"
        
        try {
            $requestBody = @{
                "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$($user.id)"
            } | ConvertTo-Json
            
            Invoke-RestMethod -Method Post -Uri "https://graph.microsoft.com/v1.0/groups/$targetGroupObjectId/members/`$ref" -Headers $headers -Body $requestBody
            
            Write-Log "User add request submitted successfully" -Level "SUCCESS"
            
            # Verify membership (with retry for replication delay)
            $verificationSuccessful = $false
            $maxRetries = 3
            $retryDelaySeconds = 5
            
            for ($i = 1; $i -le $maxRetries; $i++) {
                # Fixed the string to avoid the colon issue
                Write-Log "Verifying group membership (attempt ${i} of $maxRetries)" -Level "INFO"
                Start-Sleep -Seconds $retryDelaySeconds
                
                $updatedMembersResponse = Invoke-RestMethod -Method Get -Uri "https://graph.microsoft.com/v1.0/groups/$targetGroupObjectId/members" -Headers $headers
                $updatedMembers = $updatedMembersResponse.value
                
                $memberFound = $updatedMembers | Where-Object { $_.id -eq $user.id }
                
                if ($memberFound) {
                    Write-Log "Verification: User confirmed in group membership" -Level "SUCCESS"
                    $verificationSuccessful = $true
                    break
                } else {
                    # Fixed the string to avoid the colon issue
                    Write-Log "Verification attempt ${i} - User not found in group" -Level "WARNING"
                }
            }
            
            $success = $verificationSuccessful
            
            if (-not $success) {
                Write-Log "Verification FAILED: User not found in group after multiple checks" -Level "ERROR"
                Write-Log "This suggests the service principal doesn't have sufficient permissions" -Level "WARNING"
                
                # List current group members for troubleshooting
                Write-Log "Current group members:" -Level "INFO"
                foreach ($member in $updatedMembers) {
                    Write-Log "- $($member.displayName) ($($member.id))" -Level "INFO"
                }
            }
        }
        catch {
            $errorMessage = $_.ToString()
            Write-Log "Error adding user to group: $errorMessage" -Level "ERROR"
            
            if ($errorMessage -match "Authorization_RequestDenied" -or $errorMessage -match "Forbidden") {
                Write-Log "Permission denied. The Service Principal doesn't have sufficient rights to modify this group." -Level "ERROR"
                Write-Log "Make sure you've granted Group.ReadWrite.All and Directory.ReadWrite.All permissions" -Level "WARNING"
                Write-Log "AND that an administrator has granted admin consent for these permissions" -Level "WARNING"
            } 
            elseif ($errorMessage -match "Request_BadRequest") {
                Write-Log "Bad request error. This might be due to group type restrictions." -Level "ERROR"
                Write-Log "This specific group may not allow programmatic membership management." -Level "WARNING"
            }
            
            $success = $false
        }
    }
} catch {
    Write-Log "Error checking group membership: $_" -Level "ERROR"
    $success = $false
}

# Track results
if ($success) {
    Write-Log "Successfully added user to group with Object ID $targetGroupObjectId" -Level "SUCCESS"
    $successfulAdditions = 1
    $failedGroups = 0
} else {
    Write-Log "Failed to add user to group with Object ID $targetGroupObjectId" -Level "ERROR"
    $successfulAdditions = 0
    $failedGroups = 1
    
    # If we failed, offer alternative solutions
    Write-Log "=== ALTERNATIVE SOLUTIONS ===" -Level "WARNING"
    Write-Log "1. Assign E5 license directly to the user instead of using group-based licensing" -Level "WARNING"
    Write-Log "2. Check your Service Principal's permissions in Azure AD" -Level "WARNING"
    Write-Log "3. This may be a Microsoft restriction on programmatically managing license groups" -Level "WARNING"
}

# Script summary
Write-Log "=== Script Execution Summary ===" -Level "INFO"
Write-Log "Total groups processed: 1" -Level "INFO"
Write-Log "Successful additions: $successfulAdditions" -Level "INFO"
Write-Log "Failed groups: $failedGroups" -Level "INFO"
Write-Log "Log file location: $logFile" -Level "INFO"
Write-Log "Script execution completed at: $(Get-Date)" -Level "INFO"

# Print final summary to console
Write-Host "`n==============================================" -ForegroundColor Cyan
Write-Host "           SCRIPT EXECUTION SUMMARY           " -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "Total groups processed:  1"
Write-Host "Successful additions:    $successfulAdditions" -ForegroundColor Green
Write-Host "Failed groups:           $failedGroups" -ForegroundColor $(if ($failedGroups -gt 0) { "Red" } else { "Green" })
Write-Host "Log file location:       $logFile"
Write-Host "==============================================`n" -ForegroundColor Cyan

# Return success/failure exit code
if ($failedGroups -gt 0) {
    exit 1
} else {
    exit 0
}