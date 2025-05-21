# CSS Profiles ONLY
# Name: Tear down Open AI deployments and Accounts
# Action: Execute Script in Cloud Platform
# Event: Tearing Down
# Blocking:
# Delay: 0 Seconds
# Timeout: 3 Minutes
# Repeat: 	 
# Retries: 1
# Error Action: Log
# Enabled

# Configuration:
# PowerShell Version PS 7.4.0 | Az 11.1.0 (Release Candidate)



# Query for all OpenAI deployment accounts in the subscription or resource group, depending on the context scope.

$AIObjs = Get-AzResource -ResourceType "Microsoft.CognitiveServices/accounts" | Where-Object { $_.Kind -eq "OpenAI" } | Select-Object ResourceGroupName, Name, ResourceId

# Get the model deployments for each OpenAI account and store them in an array

$AIObjArray = @()
foreach ($AIobj in $AIObjs) {
    $AIObjArray += Get-AzCognitiveServicesAccountDeployment -ResourceGroupName $AIobj.ResourceGroupName -AccountName $AIobj.Name
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

