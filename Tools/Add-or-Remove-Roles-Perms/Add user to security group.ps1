Add user to security group
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

# Check if user is already a member of the group
Write-Host "Checking if user is already a member of the group" -ForegroundColor Cyan
try {
    $membersResponse = Invoke-RestMethod -Method Get -Uri "https://graph.microsoft.com/v1.0/groups/$targetGroupObjectId/members" -Headers $headers
    $members = $membersResponse.value
    
    # Check for user in the current members list
    $isAlreadyMember = $members | Where-Object { $_.id -eq $user.id }
    
    if ($isAlreadyMember) {
        Write-Host "User is already a member of the group" -ForegroundColor Yellow
        $success = $true
    } else {
        # Add user to group
        Write-Host "Adding user to group" -ForegroundColor Cyan
        
        try {
            $requestBody = @{
                "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$($user.id)"
            } | ConvertTo-Json
            
            Invoke-RestMethod -Method Post -Uri "https://graph.microsoft.com/v1.0/groups/$targetGroupObjectId/members/`$ref" -Headers $headers -Body $requestBody
            
            Write-Host "User add request submitted successfully" -ForegroundColor Green
            
            # Verify membership (with retry for replication delay)
            $verificationSuccessful = $false
            $maxRetries = 3
            $retryDelaySeconds = 5
            
            for ($i = 1; $i -le $maxRetries; $i++) {
                Write-Host "Verifying group membership (attempt ${i} of $maxRetries)" -ForegroundColor Cyan
                Start-Sleep -Seconds $retryDelaySeconds
                
                $updatedMembersResponse = Invoke-RestMethod -Method Get -Uri "https://graph.microsoft.com/v1.0/groups/$targetGroupObjectId/members" -Headers $headers
                $updatedMembers = $updatedMembersResponse.value
                
                $memberFound = $updatedMembers | Where-Object { $_.id -eq $user.id }
                
                if ($memberFound) {
                    Write-Host "Verification: User confirmed in group membership" -ForegroundColor Green
                    $verificationSuccessful = $true
                    break
                } else {
                    Write-Host "Verification attempt ${i} - User not found in group" -ForegroundColor Yellow
                }
            }
            
            $success = $verificationSuccessful
            
            if (-not $success) {
                Write-Host "Verification FAILED: User not found in group after multiple checks" -ForegroundColor Red
                Write-Host "This suggests the service principal doesn't have sufficient permissions" -ForegroundColor Yellow
                
                # List current group members for troubleshooting
                Write-Host "Current group members:" -ForegroundColor Cyan
                foreach ($member in $updatedMembers) {
                    Write-Host "- $($member.displayName) ($($member.id))" -ForegroundColor White
                }
            }
        }
        catch {
            $errorMessage = $_.ToString()
            Write-Host "Error adding user to group: $errorMessage" -ForegroundColor Red
            
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
    }
} catch {
    Write-Host "Error checking group membership: $_" -ForegroundColor Red
    $success = $false
}

# Track results
if ($success) {
    Write-Host "Successfully added user to group with Object ID $targetGroupObjectId" -ForegroundColor Green
    $successfulAdditions = 1
    $failedGroups = 0
} else {
    Write-Host "Failed to add user to group with Object ID $targetGroupObjectId" -ForegroundColor Red
    $successfulAdditions = 0
    $failedGroups = 1
    
    # If we failed, offer alternative solutions
    Write-Host "=== ALTERNATIVE SOLUTIONS ===" -ForegroundColor Yellow
    Write-Host "1. Assign E5 license directly to the user instead of using group-based licensing" -ForegroundColor Yellow
    Write-Host "2. Check your Service Principal's permissions in Azure AD" -ForegroundColor Yellow
    Write-Host "3. This may be a Microsoft restriction on programmatically managing license groups" -ForegroundColor Yellow
}

# Script summary
Write-Host "`n==============================================" -ForegroundColor Cyan
Write-Host "           SCRIPT EXECUTION SUMMARY           " -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "Total groups processed:  1" 
Write-Host "Successful additions:    $successfulAdditions" -ForegroundColor Green
Write-Host "Failed groups:           $failedGroups" -ForegroundColor $(if ($failedGroups -gt 0) { "Red" } else { "Green" })
Write-Host "==============================================`n" -ForegroundColor Cyan

# Return success/failure exit code
if ($failedGroups -gt 0) {
    exit 1
} else {
    exit 0
}