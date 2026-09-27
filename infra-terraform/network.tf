resource "azurerm_virtual_network" "main" {
  name                = "vnet-${var.project_name}-${var.environment}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  address_space       = var.vnet_address_space

  tags = local.common_tags

  # "created-on" is added after creation by the course tenant, not by us.
  lifecycle {
    ignore_changes = [tags["created-on"]]
  }
}

resource "azurerm_subnet" "aks" {
  name                 = "snet-aks"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.aks_subnet_prefix]
}

# Dedicated subnet for the PostgreSQL flexible server. Azure requires it to be
# delegated to the service, so nothing else can be placed in it.
resource "azurerm_subnet" "postgres" {
  name                 = "snet-postgres"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.postgres_subnet_prefix]

  # Azure adds this endpoint itself when the server is created (the server
  # uses it for backups to Azure Storage). Declared here so Terraform does
  # not try to remove it on every run.
  service_endpoints = ["Microsoft.Storage"]

  delegation {
    name = "postgres-flexible-server"

    service_delegation {
      name    = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

# Private DNS: lets the cluster resolve the server's hostname to its private IP.
resource "azurerm_private_dns_zone" "postgres" {
  name                = "${var.project_name}.private.postgres.database.azure.com"
  resource_group_name = azurerm_resource_group.main.name

  tags = local.common_tags

  # "created-on" is added after creation by the course tenant, not by us.
  lifecycle {
    ignore_changes = [tags["created-on"]]
  }
}

resource "azurerm_private_dns_zone_virtual_network_link" "postgres" {
  name                  = "postgres-dns-link"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.postgres.name
  virtual_network_id    = azurerm_virtual_network.main.id

  tags = local.common_tags

  # "created-on" is added after creation by the course tenant, not by us.
  lifecycle {
    ignore_changes = [tags["created-on"]]
  }
}
