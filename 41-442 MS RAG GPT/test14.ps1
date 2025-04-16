# gpt-rag.ps1 (Trimmed for EncodedCommand execution)
$logFile = "C:\labfiles\progress.log"
$bicepErrorLog = "C:\labfiles\bicep_errors.log"
function Write-Log($m) { Add-Content $logFile "[INFO] $(Get-Date -Format 'yyyy-MM-dd HHmmss') $m" }
Write-Log "Script started in GitHub version."
$envs = "LAB_ADMIN_USERNAME","LAB_ADMIN_PASSWORD","LAB_TENANT_ID","LAB_SUBSCRIPTION_ID","LAB_CLIENT_ID","LAB_CLIENT_SECRET","LAB_INSTANCE_ID","LAB_LOCATION"
foreach ($e in $envs) { if (-not $env:$e) { Write-Log "Missing $e"; return } }
$location = $env:LAB_LOCATION; if (-not $location) { $location = "eastus2" }
$clientId,$clientSecret,$tenantId = $env:LAB_CLIENT_ID,$env:LAB_CLIENT_SECRET,$env:LAB_TENANT_ID
$labInstanceId = $env:LAB_INSTANCE_ID
Connect-AzAccount -Credential (New-Object PSCredential($env:LAB_ADMIN_USERNAME, (ConvertTo-SecureString $env:LAB_ADMIN_PASSWORD -AsPlainText -Force))) | Out-Null
azd auth login --client-id $clientId --client-secret $clientSecret --tenant-id $tenantId | Out-Null
az login --service-principal -u $clientId -p $clientSecret --tenant $tenantId | Out-Null
$deployPath = "$HOME\gpt-rag-deploy"
Remove-Item -Recurse -Force $deployPath -ErrorAction SilentlyContinue
git clone -b agentic https://github.com/Azure/gpt-rag.git $deployPath
Set-Location $deployPath
$yaml = @"
name: azure-gpt-rag
metadata:
  template: azure-gpt-rag
services:
  dataIngest: { project: ./.azure/gpt-rag-ingestion, language: python, host: function }
  orchestrator: { project: ./.azure/gpt-rag-orchestrator, language: python, host: function }
  frontend: { project: ./.azure/gpt-rag-frontend, language: python, host: appservice }
"@
$yaml | Set-Content "$deployPath\azure.yaml"
$env:AZD_SKIP_UPDATE_CHECK = "true"; $env:AZD_DEFAULT_YES = "true"
azd init --environment dev-lab --no-prompt | Out-Null
Remove-Item "$deployPath\infra\scripts\preprovision.ps1","$deployPath\infra\scripts\preDeploy.ps1" -ErrorAction SilentlyContinue
$envPath = "$deployPath\.azure\dev-lab\.env"
if (Test-Path $envPath -and -not (Get-Content $envPath | Select-String "AZURE_NETWORK_ISOLATION")) {
  Add-Content $envPath "`nAZURE_NETWORK_ISOLATION=true"
}
$newKv = "kv-$labInstanceId"
Get-ChildItem -Recurse -Include *.bicep,*.json | ForEach-Object {
  (Get-Content $_) -replace 'kv0-[a-z0-9]+', $newKv | Set-Content $_
}
$openaiBicep = "$deployPath\infra\core\ai\openai.bicep"
if (Test-Path $openaiBicep) {
  (Get-Content $openaiBicep) | ForEach-Object { if ($_ -notmatch "^//") { "// $_" } else { $_ } } | Set-Content $openaiBicep
}
$core = "$deployPath\infra\core"
$retry = 0
do { $biceps = Get-ChildItem -Path $core -Filter *.bicep -Recurse; if ($biceps.Count -ge 30) { break }; Start-Sleep 10; $retry++ } while ($retry -lt 5)
if ($biceps.Count -lt 30) { Write-Log "[ERROR] Only $($biceps.Count)/30 Bicep files found."; exit 1 }
foreach ($f in $biceps) {
  $b = bicep build $f.FullName 2>&1
  Write-Log "Build output for $($f.Name): $b"
  if ($b -match "Error") { Write-Log "[ERROR] Bicep build failed."; exit 1 }
}
azd env set AZURE_KEY_VAULT_NAME $newKv | Out-Null
azd env set AZURE_SUBSCRIPTION_ID $env:LAB_SUBSCRIPTION_ID | Out-Null
azd env set AZURE_LOCATION $location | Out-Null
az account set --subscription $env:LAB_SUBSCRIPTION_ID | Out-Null
azd provision --environment dev-lab | Tee-Object -FilePath $logFile -Append
$rg = $null; $a=0
while (-not $rg -and $a -lt 5) {
  $rg = az group list --query "[?contains(name, 'rg-dev-lab')].name" -o tsv
  Start-Sleep 5; $a++
}
azd env set AZURE_RESOURCE_GROUP $rg | Out-Null
$openAiName = az resource list --resource-group $rg --resource-type "Microsoft.CognitiveServices/accounts" --query "[?contains(name, 'oai0')].name" -o tsv
$pstate = ""; if ($openAiName) {
  $pstate = az cognitiveservices account show --name $openAiName --resource-group $rg --query "provisioningState" -o tsv
}
if (-not $openAiName -or $pstate -ne "Succeeded") {
  $s = "$env:TEMP\provision-openai.ps1"
  Invoke-WebRequest -Uri "https://raw.githubusercontent.com/LODSContent/ProServ/refs/heads/main/41-442%20MS%20RAG%20GPT/provision-openai.ps1" -OutFile $s
  & $s -subscriptionId $env:LAB_SUBSCRIPTION_ID -resourceGroup $rg -location $location -labInstanceId $labInstanceId -clientId $clientId -clientSecret $clientSecret -tenantId $tenantId -logFile $logFile
}
