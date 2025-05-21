#Connect-AzAccount
# ===== CONFIGURATION - CHANGE THESE VALUES FOR YOUR NEEDS =====
$location = "eastus2"            # CHANGE: Azure region you want to query
$subscription = "@lab.CloudSubscription.Id"  # Your subscription ID (keep as is for lab environments)

# ===== AUTHENTICATION - USUALLY STAYS THE SAME =====
$accessToken = (Get-AzAccessToken -ResourceUrl "https://management.azure.com/").Token
Set-AzContext -Subscription $subscription

# ===== QUERY COMPUTE SKUS - USUALLY STAYS THE SAME =====
$apiResponse = Invoke-WebRequest -Method Get `
    -Uri "https://management.azure.com/subscriptions/$subscription/providers/Microsoft.Compute/skus?api-version=2021-07-01&`$filter=location eq '$location'" `
    -Headers @{
        "Authorization" = "Bearer $($accessToken)"
        "Content-Type" = "application/json"
    }

$objectResponse = ($apiResponse.Content | ConvertFrom-Json).value

# ===== FILTER COMPUTE RESOURCES - CUSTOMIZE THIS SECTION =====

# 1. First filter for VM resource type and only those without restrictions
$filteredResponse = $objectResponse | Where-Object { 
    $_.restrictions.Count -eq 0 -and 
    $_.resourceType -eq "virtualMachines"  # CHANGE: For disks use "disks", for snapshots use "snapshots", etc.
} 

# 2. Filter by resource capabilities - ADD/REMOVE/MODIFY these filters
$filteredResponse = $filteredResponse | Where-Object {
    # CHANGE: Set vCPU count - change value or remove if not needed
    $_.capabilities | Where-Object { $_.Name -eq "vCPUs" -and $_.Value -eq "2" }
} | Where-Object {
    # CHANGE: Set CPU architecture - change value or remove if not needed
    $_.capabilities | Where-Object { $_.Name -eq "CpuArchitectureType" -and $_.Value -eq "x64" }
} | Where-Object {
    # CHANGE: Require encryption support - remove if not needed
    $_.capabilities | Where-Object { $_.Name -eq "EncryptionAtHostSupported" -and $_.Value -eq $True }
} | Where-Object {
    # CHANGE: Require premium IO - remove if not needed
    $_.capabilities | Where-Object { $_.Name -eq "PremiumIO" -and $_.Value -eq $True }
} 

# 3. Filter VM families by name pattern
# CHANGE: Exclude B-series and C-series VMs, modify patterns as needed
$filteredResponse = $filteredResponse | Where-Object { 
    $_.name -notlike "*Standard_B*" -and  # Remove or change pattern to exclude different series
    $_.name -notlike "*C*"                # Remove or change pattern to exclude different series
}

# Extract names and families for easier handling
$vmNames = $filteredResponse | Select-Object -Property name, family

# ===== CHECK FOR QUOTA AVAILABILITY - USUALLY STAYS THE SAME =====
# Only finds VMs in families where you have available quota
$Quota = Get-AzVMUsage -Location $Location
$Quota = $Quota | Where-Object {$_.Limit -gt 0 -and $_.Name.LocalizedValue -like '*vCPUs'}

$matchingVMs = @()
foreach ($vm in $vmNames) {
    foreach ($q in $Quota) {
        if ($vm.family -eq $q.Name.Value) {
            $matchingVMs += $vm
        }
    }
}

# ===== SAVE RESULT - CUSTOMIZE VARIABLE NAME IF NEEDED =====
if ($matchingVMs.Count -gt 0) {
    set-LabVariable -Name "vmSku" -Value $matchingVMs[0].name  # CHANGE: Rename variable if needed
    Write-Host "Selected VM SKU: $($matchingVMs[0].name)"      # For debugging
} else {
    Write-Error "No matching VMs found. Consider adjusting your criteria."
}
