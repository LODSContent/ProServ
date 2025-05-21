
# keyvault perms
# Execute Script in Cloud Platform
# Language	PowerShell
# Blocking	No
# Delay	180 Seconds
# Timeout	10 Minutes
# Retries	2
# Error Action	Log


# Set PSGallery as a trusted repository
Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted -WarningAction SilentlyContinue

# Install the Az module if not already installed
if (-not (Get-Module -ListAvailable -Name Az)) {
    Install-Module -Name Az -AllowClobber -Scope CurrentUser -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
}

# Import the Az module
Import-Module Az -ErrorAction SilentlyContinue -WarningAction SilentlyContinue

# Authenticate to Azure
Connect-AzAccount -ErrorAction SilentlyContinue -WarningAction SilentlyContinue

# Variables
$resourceGroupName = '@lab.CloudResourceGroup(RG1).Name'
$location = '@lab.CloudResourceGroup(RG1).Location'
$keyVaultName = 'kv3-@lab.LabInstance.Id'
$userEmail = '@lab.CloudPortalCredential(User1).Username'
$appName = 'azuredatabricks'
$roleName = 'Key Vault Contributor'
$memberEmail = 'fabric@lab.LabInstance.Id'

# Check if the key vault exists
$vault = Get-AzKeyVault -VaultName $keyVaultName -ErrorAction SilentlyContinue -WarningAction SilentlyContinue

if ($vault -eq $null) {
    # Vault does not exist, create it
    New-AzKeyVault -Name $keyVaultName -ResourceGroupName $resourceGroupName -Location $location -ErrorAction SilentlyContinue -WarningAction SilentlyContinue | Out-Null
}

# Get the user's ObjectId
$userObjectId = (Get-AzADUser -UserPrincipalName $userEmail -ErrorAction SilentlyContinue -WarningAction SilentlyContinue).Id

# Set access policy for the user
Set-AzKeyVaultAccessPolicy -VaultName $keyVaultName -ObjectId $userObjectId -PermissionsToSecrets Get,List,Set,Delete,Recover,Purge -ErrorAction SilentlyContinue -WarningAction SilentlyContinue | Out-Null

# Get the ObjectId for the application
$appObjectId = (Get-AzADServicePrincipal -DisplayName $appName -ErrorAction SilentlyContinue -WarningAction SilentlyContinue).Id

# Set access policy for the application
Set-AzKeyVaultAccessPolicy -VaultName $keyVaultName -ObjectId $appObjectId -PermissionsToSecrets Get,List,Set,Delete,Recover,Purge -ErrorAction SilentlyContinue -WarningAction SilentlyContinue | Out-Null

# Get the ObjectId for the member
$memberObjectId = (Get-AzADUser -UserPrincipalName $memberEmail -ErrorAction SilentlyContinue -WarningAction SilentlyContinue).Id

# Add role assignment for the member
New-AzRoleAssignment -ObjectId $memberObjectId -RoleDefinitionName $roleName -Scope $vault.ResourceId -ErrorAction SilentlyContinue -WarningAction SilentlyContinue