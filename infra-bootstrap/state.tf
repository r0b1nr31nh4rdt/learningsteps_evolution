# Remote state of the main stack (../infra-terraform). The state contains
# secrets (the database password), so: no account keys, access only through
# Entra ID roles, HTTPS only, versioning to recover an overwritten state.

data "azurerm_client_config" "current" {}

resource "azurerm_storage_account" "tfstate" {
  name                     = "stlearningstepstfstate"
  resource_group_name      = azurerm_resource_group.bootstrap.name
  location                 = azurerm_resource_group.bootstrap.location
  account_tier             = "Standard"
  account_replication_type = "LRS"

  shared_access_key_enabled       = false # no keys, only Entra ID
  default_to_oauth_authentication = true
  allow_nested_items_to_be_public = false
  https_traffic_only_enabled      = true
  min_tls_version                 = "TLS1_2"
  # Second layer of encryption at rest; can only be set when creating the account.
  infrastructure_encryption_enabled = true

  blob_properties {
    versioning_enabled = true # every write keeps the previous state version
    delete_retention_policy {
      days = 30
    }
    container_delete_retention_policy {
      days = 30
    }
  }

  tags = local.tags

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [tags["created-on"]]
  }
}

resource "azurerm_storage_container" "tfstate" {
  name                  = "tfstate"
  storage_account_id    = azurerm_storage_account.tfstate.id
  container_access_type = "private"
}

# Who may read and write the state
resource "azurerm_role_assignment" "tfstate_admin" {
  scope                = azurerm_storage_container.tfstate.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id # you (terraform from the Mac)
}

resource "azurerm_role_assignment" "tfstate_apply" {
  scope                = azurerm_storage_container.tfstate.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.terraform_apply.principal_id
}

# terraform plan needs the state too, and locks it while running.
resource "azurerm_role_assignment" "tfstate_plan" {
  scope                = azurerm_storage_container.tfstate.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.terraform_plan.principal_id
}
