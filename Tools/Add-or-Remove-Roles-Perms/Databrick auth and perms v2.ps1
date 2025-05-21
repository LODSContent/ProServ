Databrick auth and perms v2
Execute Script in Cloud Platform
Language	PowerShell
Blocking	No
Delay	70 Seconds
Timeout	10 Minutes
Retries	3
Error Action	Log
# Register Microsoft.Compute provider (if not already registered)
Register-AzResourceProvider -ProviderNamespace Microsoft.Compute

# Define variables
$InformationPreference = 'Ignore'
$resourceGroupName = "@lab.CloudResourceGroup(RG1).Name"
$workspaceName = "dbkwks@lab.LabInstance.Id"
$userPrincipalName = "@lab.CloudPortalCredential(User1).Username"
$roleName = "Contributor"

# Timeout settings
$timeoutMinutes = 5
$checkIntervalSeconds = 15
$startTime = [DateTime]::Now

# Wait for Databricks workspace to exist
$workspace = $null
while ($null -eq $workspace) {
    $workspace = Get-AzResource -ResourceGroupName $resourceGroupName -ResourceType "Microsoft.Databricks/workspaces" -ResourceName $workspaceName

    if ($null -eq $workspace) {
        if (([DateTime]::Now - $startTime).TotalMinutes -ge $timeoutMinutes) {
            Write-Error "Timeout reached. Databricks workspace not found."
            exit
        }
        Start-Sleep -Seconds $checkIntervalSeconds
    }
}

# Wait for workspaceUrl to become available
while (-not $workspace.Properties.workspaceUrl) {
    Write-Host "Waiting for workspaceUrl to be assigned..."
    Start-Sleep -Seconds $checkIntervalSeconds
    $workspace = Get-AzResource -ResourceGroupName $resourceGroupName -ResourceType "Microsoft.Databricks/workspaces" -ResourceName $workspaceName
}

# Assign role to user
$user = Get-AzADUser -UserPrincipalName $userPrincipalName
if ($null -eq $user) {
    Write-Error "User not found."
    exit
}
New-AzRoleAssignment -ObjectId $user.Id -RoleDefinitionName $roleName -Scope $workspace.Id | Out-Null

# Prepare for Databricks API calls
$workspaceUrl = $workspace.Properties.workspaceUrl
$workspaceId = $workspace.Id
$aadToken = "Bearer $((Get-AzAccessToken).Token)"

# Generate Databricks PAT token
$tokenResponse = Invoke-RestMethod -Uri "https://management.azure.com$workspaceId/generateToken?api-version=2018-04-01" `
    -Method POST -Headers @{ Authorization = $aadToken } -Body "{}" -ContentType "application/json"
$databricksToken = $tokenResponse.properties.token

# Headers for Databricks REST API
$headers = @{
    "Authorization" = "Bearer $databricksToken"
    "Content-Type"  = "application/json"
}

# Check available node types from API (optional but informative)
$nodeTypesResp = Invoke-RestMethod -Uri "https://$workspaceUrl/api/2.0/clusters/list-node-types" -Method GET -Headers $headers
$availableNodeTypes = $nodeTypesResp.node_types | ForEach-Object { $_.node_type_id }
Write-Host "Available node types: $($availableNodeTypes -join ', ')"

# Define fallback node types (most commonly available SKUs)
$nodeTypes = @("Standard_D4s_v3", "Standard_D4s_v4", "Standard_D3_v2", "Standard_E4s_v3", "Standard_B4ms", "Standard_F4s_v2")
$availableNodeType = $null
$sparkVersion = "11.3.x-scala2.12"
$clusterName = "LabCluster"
$minWorkers = 1
$maxWorkers = 2
$autoTerminationMinutes = 30

# Test each node type to find one that works
foreach ($type in $nodeTypes) {
    $testClusterConfig = @{
        "cluster_name" = "SkuTestCluster"
        "spark_version" = $sparkVersion
        "node_type_id" = $type
        "autotermination_minutes" = 10
        "num_workers" = 0
        "spark_conf" = @{}
        "custom_tags" = @{ "ResourceClass" = "SingleNode" }
    } | ConvertTo-Json -Depth 10

    try {
        $testResponse = Invoke-RestMethod -Uri "https://$workspaceUrl/api/2.0/clusters/create" -Method POST -Headers $headers -Body $testClusterConfig
        $availableNodeType = $type

        $deleteBody = @{ "cluster_id" = $testResponse.cluster_id } | ConvertTo-Json
        Invoke-RestMethod -Uri "https://$workspaceUrl/api/2.0/clusters/delete" -Method POST -Headers $headers -Body $deleteBody
        break
    } catch {
        Write-Host "Node type $type not available: $($_.Exception.Message)"
    }
}

if (-not $availableNodeType) {
    Write-Error "None of the specified node types are available in this region."
    exit
}

# Create production cluster
$clusterConfig = @{
    "cluster_name" = $clusterName
    "spark_version" = $sparkVersion
    "node_type_id" = $availableNodeType
    "autotermination_minutes" = $autoTerminationMinutes
    "spark_conf" = @{ "spark.speculation" = "true" }
    "num_workers" = $minWorkers
    "autoscale" = @{
        "min_workers" = $minWorkers
        "max_workers" = $maxWorkers
    }
} | ConvertTo-Json -Depth 10

$clusterResponse = Invoke-RestMethod -Uri "https://$workspaceUrl/api/2.0/clusters/create" -Method POST -Headers $headers -Body $clusterConfig
Write-Host "Created cluster with ID: $($clusterResponse.cluster_id) using node type: $availableNodeType"

# Grant user permission to attach, restart, and manage the created cluster
$permissionsBody = @{
    access_control_list = @(
        @{
            user_name = $user.UserPrincipalName
            permission_level = "CAN_ATTACH_TO"
        },
        @{
            user_name = $user.UserPrincipalName
            permission_level = "CAN_RESTART"
        },
        @{
            user_name = $user.UserPrincipalName
            permission_level = "CAN_MANAGE"
        }
    )
} | ConvertTo-Json -Depth 10

Invoke-RestMethod -Uri "https://$workspaceUrl/api/2.0/permissions/clusters/$($clusterResponse.cluster_id)" `
    -Method POST -Headers $headers -Body $permissionsBody

Write-Host "Assigned CAN_ATTACH_TO, CAN_RESTART, and CAN_MANAGE permissions for user $($user.UserPrincipalName)"