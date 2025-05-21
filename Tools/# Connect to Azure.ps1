# Connect to Azure
`$creds = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList (`$AdminUserName, (ConvertTo-SecureString -AsPlainText -Force -String `$AdminPassword))
Connect-AzAccount -Credential `$creds | Out-Null