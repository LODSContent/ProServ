Storage Container and directories
Execute Script in Cloud Platform
Language	PowerShell
Blocking	No
Delay	120 Seconds
Timeout	10 Minutes
Retries	2
Error Action	Log
# Set the variables for your storage account, resource group, and container names
$resourceGroupName = "@lab.CloudResourceGroup(RG1).Name"
$storageAccountName = "sa@lab.LabInstance.Id"
$containerName = "medallion"

# Get the storage account context
$storageAccount = Get-AzStorageAccount -ResourceGroupName $resourceGroupName -Name $storageAccountName
$ctx = $storageAccount.Context

# Check if the container exists and create it if it doesn't
$container = Get-AzStorageContainer -Context $ctx -Name $containerName -ErrorAction SilentlyContinue
if (-not $container) {
    New-AzStorageContainer -Name $containerName -Context $ctx
}

# Ensure Az.Storage is installed
Install-Module -Name Az.Storage -AllowClobber -Force

# Create the directories
$blobServiceClient = [Microsoft.Azure.Storage.Blob.CloudBlobClient]::new($ctx.StorageAccount.BlobEndpoint, $ctx.StorageAccount.Credentials)

# Function to create directory
function New-Directory {
    param (
        [string]$directoryPath
    )
    $container = $blobServiceClient.GetContainerReference($containerName)
    $directory = $container.GetDirectoryReference($directoryPath)
    $dummyFile = $directory.GetBlockBlobReference("dummy.txt")
    $dummyFile.UploadText("This is a dummy file to create the directory structure.")
    $dummyFile.Delete()
}

# Create directories
New-Directory -directoryPath "bronze"
New-Directory -directoryPath "silver"
New-Directory -directoryPath "gold"