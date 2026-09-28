# Identity of the cluster itself. It is created before the cluster so it can be
# granted access to the subnet first.
resource "azurerm_user_assigned_identity" "aks" {
  name                = "id-aks-${var.project_name}-${var.environment}"
  location            = data.azurerm_resource_group.main.location
  resource_group_name = data.azurerm_resource_group.main.name

  tags = local.common_tags

  # "created-on" is added after creation by the course tenant, not by us.
  lifecycle {
    ignore_changes = [tags["created-on"]]
  }
}

# AKS must be allowed to place nodes into our subnet.
resource "azurerm_role_assignment" "aks_subnet" {
  scope                = azurerm_subnet.aks.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.aks.principal_id
}

resource "azurerm_kubernetes_cluster" "main" {
  name                = "aks-${var.project_name}-${var.environment}"
  location            = data.azurerm_resource_group.main.location
  resource_group_name = data.azurerm_resource_group.main.name
  dns_prefix          = "${var.project_name}-${var.environment}"

  default_node_pool {
    name    = "system"
    vm_size = var.aks_node_size
    zones   = var.aks_availability_zones

    # Cluster autoscaler: adds a VM when pods are Pending for lack of room
    # and removes it again when it has been idle for about 10 minutes.
    # No node_count: the autoscaler owns the number of nodes (a fixed value
    # would show up as drift in every terraform plan).
    auto_scaling_enabled = true
    min_count            = var.aks_min_node_count
    max_count            = var.aks_max_node_count

    vnet_subnet_id = azurerm_subnet.aks.id
    tags           = local.common_tags

    # Azure's default values, written out so terraform plan shows no drift.
    upgrade_settings {
      max_surge                     = "10%"
      drain_timeout_in_minutes      = 0
      node_soak_duration_in_minutes = 0
    }
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.aks.id]
  }

  # Azure CNI Overlay: pods get addresses from an internal range, so only the
  # nodes use up addresses of our subnet.
  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"

    # Cilium as data plane, which also enforces Kubernetes NetworkPolicies.
    # Without a policy engine, NetworkPolicy objects would be silently ignored.
    network_data_plane = "cilium"
    network_policy     = "cilium"
  }

  # Kubernetes RBAC (Role/RoleBinding). On by default in AKS, stated
  # explicitly so it cannot be switched off by accident (and scanners see it).
  role_based_access_control_enabled = false

  # Workload identity lets a pod authenticate to Azure (Key Vault) without a password.
  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  # Add-on that makes Key Vault secrets available inside the cluster.
  key_vault_secrets_provider {
    secret_rotation_enabled = false
  }

  # Managed NGINX ingress controller (the "Ingress" of the project).
  # An empty list means: no DNS zone, the ingress is reached by its IP.
  web_app_routing {
    dns_zone_ids = []
  }

  tags = local.common_tags

  # "created-on" is added after creation by the course tenant, not by us.
  lifecycle {
    ignore_changes = [tags["created-on"]]
  }

  # Nothing in this file references the role assignment, so Terraform would not
  # know it has to exist first. depends_on says it explicitly.
  depends_on = [azurerm_role_assignment.aks_subnet]
}
