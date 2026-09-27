# Values needed after terraform apply: for az/kubectl commands and for the
# Kubernetes manifests. None of them is a secret.

output "resource_group_name" {
  description = "Resource group of all resources (for az aks get-credentials)"
  value       = data.azurerm_resource_group.main.name
}

output "aks_cluster_name" {
  description = "Name of the AKS cluster (for az aks get-credentials)"
  value       = azurerm_kubernetes_cluster.main.name
}

output "acr_login_server" {
  description = "Registry address, used as image prefix (docker push, Deployment)"
  value       = azurerm_container_registry.main.login_server
}

output "app_identity_client_id" {
  description = "Client ID of the app identity (ServiceAccount annotation, SecretProviderClass)"
  value       = azurerm_user_assigned_identity.app.client_id
}

output "tenant_id" {
  description = "Microsoft Entra tenant ID (SecretProviderClass)"
  value       = data.azurerm_client_config.current.tenant_id
}

output "key_vault_name" {
  description = "Name of the Key Vault (SecretProviderClass)"
  value       = azurerm_key_vault.main.name
}

output "k8s_namespace" {
  description = "Namespace the workload identity is bound to"
  value       = var.k8s_namespace
}

output "k8s_service_account" {
  description = "ServiceAccount the workload identity is bound to"
  value       = var.k8s_service_account
}
