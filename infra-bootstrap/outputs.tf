# Values for the GitHub repository variables (Settings > Secrets and
# variables > Actions > Variables). None of them is a secret.

output "AZURE_CLIENT_ID" {
  value = azurerm_user_assigned_identity.github.client_id
}

output "AZURE_TENANT_ID" {
  value = azurerm_user_assigned_identity.github.tenant_id
}

output "AZURE_SUBSCRIPTION_ID" {
  value = var.subscription_id
}

output "github_identity_name" {
  value = azurerm_user_assigned_identity.github.name
}

output "github_identity_resource_group" {
  value = azurerm_resource_group.bootstrap.name
}
