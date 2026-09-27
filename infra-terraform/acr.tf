# Registry names are globally unique and may only contain letters and digits.
resource "random_string" "acr_suffix" {
  length  = 6
  upper   = false
  special = false
}

resource "azurerm_container_registry" "main" {
  name                = "acr${var.project_name}${random_string.acr_suffix.result}"
  location            = data.azurerm_resource_group.main.location
  resource_group_name = data.azurerm_resource_group.main.name
  sku                 = "Basic"

  # No shared admin user/password. Access only through Azure identities and roles.
  admin_enabled = false

  tags = local.common_tags

  # "created-on" is added after creation by the course tenant, not by us.
  lifecycle {
    ignore_changes = [tags["created-on"]]
  }
}

# The nodes (kubelet identity) may pull images from the registry.
# This is what "az aks update --attach-acr" does.
resource "azurerm_role_assignment" "aks_acr_pull" {
  scope                = azurerm_container_registry.main.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_kubernetes_cluster.main.kubelet_identity[0].object_id
}
