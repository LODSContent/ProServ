Remove user from Security group
Execute Script in Cloud Platform
Language	PowerShell
Blocking	Yes
Timeout	10 Minutes
Retries	1
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

$ErrorActionPreference = "Continue"  # Allow script to continue on errors

# We'll use Microsoft Graph REST API directly with auth token
Write-Host "Getting authentication token via REST API" -ForegroundColor Cyan
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
    
    Write-Host "Successfully acquired authentication token" -ForegroundColor Green
} catch {
    Write-Host "Failed to get authentication token: $_" -ForegroundColor Red
    exit 1
}

# Set up headers for all Graph API calls
$headers = @{
    "Authorization" = "Bearer $token"
    "Content-Type"  = "application/json"
}

# Get group details
Write-Host "Verifying group exists" -ForegroundColor Cyan
try {
    $groupResponse = Invoke-RestMethod -Method Get -Uri "https://graph.microsoft.com/v1.0/groups/$targetGroupObjectId" -Headers $headers
    Write-Host "Group found: $($groupResponse.displayName) (ID: $($groupResponse.id))" -ForegroundColor Green
} catch {
    Write-Host "Error: Group not found - $_" -ForegroundColor Red
    exit 1
}

# Get user details
Write-Host "Looking up user details" -ForegroundColor Cyan
try {
    $userResponse = Invoke-RestMethod -Method Get -Uri "https://graph.microsoft.com/v1.0/users?`$filter=userPrincipalName eq '$username'" -Headers $headers
    
    if ($userResponse.value.Count -eq 0) {
        Write-Host "User $username not found" -ForegroundColor Red
        exit 1
    }
    
    $user = $userResponse.value[0]
    Write-Host "User found: $($user.displayName) (ID: $($user.id))" -ForegroundColor Green
} catch {
    Write-Host "Error looking up user: $_" -ForegroundColor Red
    exit 1
}

# Check if user is a member of the group
Write-Host "Checking if user is a member of the group" -ForegroundColor Cyan
try {
    $membersResponse = Invoke-RestMethod -Method Get -Uri "https://graph.microsoft.com/v1.0/groups/$targetGroupObjectId/members" -Headers $headers
    $members = $membersResponse.value
    
    # Check for user in the current members list
    $isMember = $members | Where-Object { $_.id -eq $user.id }
    
    if ($isMember) {
        # Remove user from group
        Write-Host "User is a member of the group. Proceeding with removal." -ForegroundColor Cyan
        
        try {
            # The DELETE request to remove a member from a group
            $removeUri = "https://graph.microsoft.com/v1.0/groups/$targetGroupObjectId/members/$($user.id)/`$ref"
            Invoke-RestMethod -Method Delete -Uri $removeUri -Headers $headers
            
            Write-Host "User removal request submitted successfully" -ForegroundColor Green
            
            # Verify membership removal (with retry for replication delay)
            $verificationSuccessful = $false
            $maxRetries = 3
            $retryDelaySeconds = 5
            
            for ($i = 1; $i -le $maxRetries; $i++) {
                Write-Host "Verifying group membership removal (attempt ${i} of $maxRetries)" -ForegroundColor Cyan
                Start-Sleep -Seconds $retryDelaySeconds
                
                $updatedMembersResponse = Invoke-RestMethod -Method Get -Uri "https://graph.microsoft.com/v1.0/groups/$targetGroupObjectId/members" -Headers $headers
                $updatedMembers = $updatedMembersResponse.value
                
                $memberStillPresent = $updatedMembers | Where-Object { $_.id -eq $user.id }
                
                if (-not $memberStillPresent) {
                    Write-Host "Verification: User confirmed removed from group membership" -ForegroundColor Green
                    $verificationSuccessful = $true
                    break
                } else {
                    Write-Host "Verification attempt ${i} - User still present in group" -ForegroundColor Yellow
                }
            }
            
            $success = $verificationSuccessful
            
            if (-not $success) {
                Write-Host "Verification FAILED: User still found in group after multiple checks" -ForegroundColor Red
                Write-Host "This suggests the service principal doesn't have sufficient permissions to remove the user" -ForegroundColor Yellow
                
                # List current group members for troubleshooting
                Write-Host "Current group members:" -ForegroundColor Cyan
                foreach ($member in $updatedMembers) {
                    Write-Host "- $($member.displayName) ($($member.id))" -ForegroundColor White
                }
            }
        }
        catch {
            $errorMessage = $_.ToString()
            Write-Host "Error removing user from group: $errorMessage" -ForegroundColor Red
            
            if ($errorMessage -match "Authorization_RequestDenied" -or $errorMessage -match "Forbidden") {
                Write-Host "Permission denied. The Service Principal doesn't have sufficient rights to modify this group." -ForegroundColor Red
                Write-Host "Make sure you've granted Group.ReadWrite.All and Directory.ReadWrite.All permissions" -ForegroundColor Yellow
                Write-Host "AND that an administrator has granted admin consent for these permissions" -ForegroundColor Yellow
            } 
            elseif ($errorMessage -match "Request_BadRequest") {
                Write-Host "Bad request error. This might be due to group type restrictions." -ForegroundColor Red
                Write-Host "This specific group may not allow programmatic membership management." -ForegroundColor Yellow
            }
            
            $success = $false
        }
    } else {
        Write-Host "User is not a member of the group. No removal necessary." -ForegroundColor Yellow
        $success = $true # Consider this a success since the end state is what we want
    }
} catch {
    Write-Host "Error checking group membership: $_" -ForegroundColor Red
    $success = $false
}

# Track results
if ($success) {
    Write-Host "Successfully removed user from group with Object ID $targetGroupObjectId" -ForegroundColor Green
    $successfulRemovals = 1
    $failedGroups = 0
} else {
    Write-Host "Failed to remove user from group with Object ID $targetGroupObjectId" -ForegroundColor Red
    $successfulRemovals = 0
    $failedGroups = 1
    
    # If we failed, offer alternative solutions
    Write-Host "=== ALTERNATIVE SOLUTIONS ===" -ForegroundColor Yellow
    Write-Host "1. Try removing the user directly through the Microsoft 365 Admin Center" -ForegroundColor Yellow
    Write-Host "2. Check your Service Principal's permissions in Azure AD" -ForegroundColor Yellow 
    Write-Host "3. This may be a Microsoft restriction on programmatically managing license groups" -ForegroundColor Yellow
}

# Script summary
Write-Host "`n==============================================" -ForegroundColor Cyan
Write-Host "           SCRIPT EXECUTION SUMMARY           " -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "Total groups processed:  1"
Write-Host "Successful removals:    $successfulRemovals" -ForegroundColor Green
Write-Host "Failed groups:           $failedGroups" -ForegroundColor $(if ($failedGroups -gt 0) { "Red" } else { "Green" })
Write-Host "==============================================`n" -ForegroundColor Cyan

# Return success/failure exit code
if ($failedGroups -gt 0) {
    exit 1
} else {
    exit 0
}