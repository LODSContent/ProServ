# CSR profiles only
# Name:Remove permissions
# Action: Execute Script in Cloud Platform
# Event: Tearing Down
# Blocking 	
# Delay: 0 Seconds
# Timeout: 10 Minutes
# Repeat: 	 
# Retries: 0
# Error Action: Log
# Enabled

# Configuration:
# PowerShell Version PS 7.1.3 | Az 6.0.0

Remove-AzRoleAssignment -SignInName '@lab.CloudPortalCredential(LabUser).Username' -RoleDefinitionName "Cognitive Services Usages Reader" -Scope '/subscriptions/@lab.CloudSubscription.Id' -InformationAction 'Ignore'