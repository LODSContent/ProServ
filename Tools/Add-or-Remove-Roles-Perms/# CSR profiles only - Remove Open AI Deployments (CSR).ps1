# CSR Only - Remove Open AI Deployments (CSR)
# Name: Remove Open AI Deployments (CSR)
# Action: Execute Script in Cloud Platform
# Event: Tearing Down
# Blocking: 	
# Delay: 0 Seconds
# Timeout: 5 Minutes
# Repeat: 	 
# Retries: 0
# Error Action: Log
# Enabled	

# Configuration:
# PowerShell Version PS 7.4.0 | Az 11.1.0 (Release Candidate)



$LabInstanceId = "@lab.LabInstance.Id"
$resourceGroups = Get-AzResourceGroup | Where-Object { $_.ResourceGroupName -match $labinstanceId }

# Query for all OpenAI deployment accounts in the discovered resource groups and store them in an array.

$AIObjArray = @()
foreach ($resourceGroup in $resourceGroups) {
    $AIObjs = Get-AzResource -ResourceType "Microsoft.CognitiveServices/accounts" -ResourceGroupName $resourceGroup.ResourceGroupName | Where-Object { $_.Kind -eq "OpenAI" } | Select-Object ResourceGroupName, Name, ResourceId
    foreach ($AIobj in $AIObjs) {
        $AIObjArray += Get-AzCognitiveServicesAccountDeployment -ResourceGroupName $AIobj.ResourceGroupName -AccountName $AIobj.Name
    }
}

#Loop through each model deployment and delete it
foreach ($Deployment in $AIObjArray) {
    Remove-AzCognitiveServicesAccountDeployment -ResourceId $deployment.Id -Force    
}


# Loop through each Open AI deployment account and delete it
foreach ($account in $AIObjs) {
    Remove-AzResource -ResourceId $account.ResourceId -Force
    Write-Output "Deleted OpenAI deployment: $($account.Name)"
}

