New-AzRoleAssignment -SignInName @lab.CloudPortalCredential(User1).Username -RoleDefinitionName "Contributor" -Scope "/subscriptions/@lab.CloudSubscription.Id"

Remove-AzRoleAssignment -SignInName @lab.CloudPortalCredential(User1).Username -RoleDefinitionName "LODOwner" -ResourceGroup "@lab.CloudResourceGroup(rg-ms-learn-vision).Name"