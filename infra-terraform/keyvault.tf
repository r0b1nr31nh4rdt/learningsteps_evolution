# Tenant ID and the identity Terraform runs as (your az login).
data "azurerm_client_config" "current" {}

# Vault names are globally unique and at most 24 characters long.
resource "random_string" "keyvault_suffix" {
  length  = 6
  upper   = false
  special = false
}

resource "azurerm_key_vault" "main" {
  name                = "kv-${var.project_name}-${random_string.keyvault_suffix.result}"
  location            = data.azurerm_resource_group.main.location
  resource_group_name = data.azurerm_resource_group.main.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  # Access is controlled with Azure roles (RBAC) instead of access policies.
  rbac_authorization_enabled = true

  # Deleted vaults are kept for 7 days (the minimum). Without purge protection
  # they can be purged right away, so terraform destroy + apply works.
  soft_delete_retention_days = 7
  purge_protection_enabled   = false

  tags = local.common_tags

  # "created-on" is added after creation by the course tenant, not by us.
  lifecycle {
    ignore_changes = [tags["created-on"]]
  }
}

# Who may write the secret: the pipeline's apply identity and you (terraform
# from the Mac, e.g. for destroy). Fixed principals instead of "whoever runs
# terraform right now", which would flip between you and the pipeline.
resource "azurerm_role_assignment" "keyvault_officer" {
  for_each = {
    terraform-apply = data.azurerm_user_assigned_identity.terraform_apply.principal_id
    admin           = var.keyvault_admin_object_id
  }

  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = each.value
}

# The old assignment (for you) is the same as the "admin" entry above.
moved {
  from = azurerm_role_assignment.keyvault_terraform
  to   = azurerm_role_assignment.keyvault_officer["admin"]
}

resource "azurerm_key_vault_secret" "database_url" {
  name         = "database-url"
  key_vault_id = azurerm_key_vault.main.id
  value        = "postgresql://${var.postgres_admin_user}:${random_password.postgres_admin.result}@${azurerm_postgresql_flexible_server.main.fqdn}:5432/${var.postgres_database_name}?sslmode=require"

  depends_on = [azurerm_role_assignment.keyvault_officer]
}

# Identity of the app. The pod takes it on through workload identity.
resource "azurerm_user_assigned_identity" "app" {
  name                = "id-app-${var.project_name}-${var.environment}"
  location            = data.azurerm_resource_group.main.location
  resource_group_name = data.azurerm_resource_group.main.name

  tags = local.common_tags

  # "created-on" is added after creation by the course tenant, not by us.
  lifecycle {
    ignore_changes = [tags["created-on"]]
  }
}

# Read access to this one secret only, not to the whole vault.
resource "azurerm_role_assignment" "keyvault_app" {
  scope                = azurerm_key_vault_secret.database_url.resource_versionless_id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.app.principal_id
}

# Trust between the cluster and the app identity: a token that AKS issues for
# exactly this service account may be exchanged for the app identity.
resource "azurerm_federated_identity_credential" "app" {
  name                      = "fic-${var.k8s_service_account}"
  user_assigned_identity_id = azurerm_user_assigned_identity.app.id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = azurerm_kubernetes_cluster.main.oidc_issuer_url
  subject                   = "system:serviceaccount:${var.k8s_namespace}:${var.k8s_service_account}"
}
