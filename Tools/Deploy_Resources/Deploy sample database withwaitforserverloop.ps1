$resourceGroupName = '@lab.CloudResourceGroup(ResourceGroup1).Name'                                                              
$templateUri = "https://raw.githubusercontent.com/LODSContent/Tom-Demo/master/template.json" 
$sqlServerName = "SQL@lab.LabInstance.Id"
$maxAttempts = 20

# Loop until the SQL server is found or the maximum number of attempts is reached
for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
    try {
        # Check if the SQL server exists
        $server = Get-AzSqlServer -ResourceGroupName $resourceGroupName -ServerName $sqlServerName -ErrorAction Stop
        Write-Host "SQL server '$sqlServerName' exists in resource group '$resourceGroupName'."
        break
    } catch {
        #Write-Host "Attempt '$attempt': SQL server '$sqlServerName' not found. Checking again in 30 seconds..."
        Start-Sleep -Seconds 3
    }
}

if ($attempt -gt $maxAttempts) {
    Write-Host "SQL server '$sqlServerName' was not found after $maxAttempts attempts."
}

$location = (Get-AzResourceGroup -Name $resourceGroupName).Location

$params = @{
    collation = "SQL_Latin1_General_CP1_CI_AS"
    databaseName = "DB01"
    tier = "GeneralPurpose"
    skuName = "GP_S_Gen5_1"
    maxSizeBytes = 34359738368
    sampleName = "AdventureWorksLT"
    serverLocation = $location
    serverName = $sqlServerName
    minCapacity = "0.5"
    autoPauseDelay = 60
    sqlLedgerTemplateLink = "https://sqlazureextension.hosting.portal.azure.net/sqlazureextension/Content/2.1.02687198/DeploymentTemplates/SqlLedger.json"
    privateLinkPrivateDnsZoneFQDN = "privatelink.database.windows.net"
    privateEndpointTemplateLink = "https://sqlazureextension.hosting.portal.azure.net/sqlazureextension/Content/2.1.02687198/DeploymentTemplates/PrivateEndpoint.json"
    privateDnsForPrivateEndpointTemplateLink = "https://sqlazureextension.hosting.portal.azure.net/sqlazureextension/Content/2.1.02687198/DeploymentTemplates/PrivateDnsForPrivateEndpoint.json"
    privateDnsForPrivateEndpointNicTemplateLink = "https://sqlazureextension.hosting.portal.azure.net/sqlazureextension/Content/2.1.02687198/DeploymentTemplates/PrivateDnsForPrivateEndpointNic.json"
    privateDnsForPrivateEndpointIpConfigTemplateLink = "https://sqlazureextension.hosting.portal.azure.net/sqlazureextension/Content/2.1.02687198/DeploymentTemplates/PrivateDnsForPrivateEndpointIpConfig.json"
    requestedBackupStorageRedundancy = "Local"
    freeLimitExhaustionBehavior = "AutoPause"
}

New-AzResourceGroupDeployment -ResourceGroupName $resourceGroupName -TemplateUri $templateUri -TemplateParameterObject $params