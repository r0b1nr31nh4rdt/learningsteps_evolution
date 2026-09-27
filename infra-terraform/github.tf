# Permissions of the GitHub Actions pipeline. The identity itself lives in
# ../infra-bootstrap (it must survive a rebuild); the roles are granted here
# because they point to resources that are rebuilt. Apply the bootstrap once
# before this stack, otherwise the data source below finds nothing.

data "azurerm_user_assigned_identity" "github" {
  name                = var.github_identity_name
  resource_group_name = var.github_identity_resource_group
}

# Push images to the registry (no delete, no admin).
resource "azurerm_role_assignment" "github_acr_push" {
  scope                = azurerm_container_registry.main.id
  role_definition_name = "AcrPush"
  principal_id         = data.azurerm_user_assigned_identity.github.principal_id
}

# Fetch the cluster credentials (az aks get-credentials). Without Entra ID
# integration on the cluster, these credentials give full access inside the
# cluster; see README "Pipeline" for the limitation.
resource "azurerm_role_assignment" "github_aks_user" {
  scope                = azurerm_kubernetes_cluster.main.id
  role_definition_name = "Azure Kubernetes Service Cluster User Role"
  principal_id         = data.azurerm_user_assigned_identity.github.principal_id
}

# Read-only view of the resource group, so deploy.sh can look up names and
# IDs (registry, vault, app identity, cluster state) without Terraform state.
resource "azurerm_role_assignment" "github_rg_reader" {
  scope                = azurerm_resource_group.main.id
  role_definition_name = "Reader"
  principal_id         = data.azurerm_user_assigned_identity.github.principal_id
}
