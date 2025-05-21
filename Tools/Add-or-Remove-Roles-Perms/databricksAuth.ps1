
# Databricks Auth
# Execute Script in Cloud Platform
# Language	PowerShell
# Blocking	No
# Delay	90 Seconds
# Timeout	10 Minutes
# Retries	3
# Error Action	End Lab


# Register the Microsoft.Compute resource provider
Register-AzResourceProvider -ProviderNamespace Microsoft.Compute

# Define variables
$resourceGroupName = "@lab.CloudResourceGroup(RG1).Name"
$workspaceName = "dbkwks@lab.LabInstance.Id"
$userPrincipalName = "@lab.CloudPortalCredential(User1).Username"
$roleName = "Contributor" # or "Owner"

# Define timeout and check interval
$timeoutMinutes = 5
$checkIntervalSeconds = 15
$startTime = [DateTime]::Now

# Loop to check for the Databricks workspace
$workspace = $null
while ($null -eq $workspace) {
    $workspace = Get-AzResource -ResourceGroupName $resourceGroupName -ResourceType "Microsoft.Databricks/workspaces" -ResourceName $workspaceName

    if ($null -eq $workspace) {
        # Check if the timeout has been reached
        $elapsedTime = ([DateTime]::Now - $startTime).TotalMinutes
        if ($elapsedTime -ge $timeoutMinutes) {
            Write-Error "Timeout reached. Databricks workspace not found."
            exit
        }

        # Wait before checking again
        Start-Sleep -Seconds $checkIntervalSeconds
    }
}

# Get the user object ID
$user = Get-AzADUser -UserPrincipalName $userPrincipalName

# Check if the user was found
if ($null -eq $user) {
    Write-Error "User not found."
    exit
}

# Assign the role
New-AzRoleAssignment -ObjectId $user.Id -RoleDefinitionName $roleName -Scope $workspace.Id

Write-Output "Role assignment completed."