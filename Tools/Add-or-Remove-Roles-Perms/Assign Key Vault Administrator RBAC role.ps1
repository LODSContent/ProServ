$user = '@lab.CloudPortalCredential(User1).Username'
$rg = '@lab.CloudResourceGroup(TestingRG).Name'
$sub = '@lab.CloudSubscription.Id'
New-AzRoleAssignment -RoleDefinitionName "Key Vault Administrator" -SignInName $user -Scope /subscriptions/$sub/resourcegroups/$rg