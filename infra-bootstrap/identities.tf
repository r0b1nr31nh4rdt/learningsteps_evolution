# Two identities for Terraform in the pipeline, separated by power:
#
#   terraform-plan   read only; runs on every push to main and on pull requests
#   terraform-apply  changes the infrastructure; only in the GitHub environment
#                    "infrastructure", which requires a manual approval
#
# The subject of the federated credential decides which workflow job gets
# which identity. A job that runs in an environment gets a token naming that
# environment, so only the approved job can become terraform-apply.

locals {
  github_issuer = "https://token.actions.githubusercontent.com"
  github_repo   = "repo:${var.github_oidc_repository}"

  # Roles the main stack assigns. terraform-apply may assign these and no
  # others (in particular not Owner or User Access Administrator).
  assignable_role_ids = [
    "4d97b98b-1d4f-4787-a291-c67834d212e7", # Network Contributor (AKS on its subnet)
    "7f951dda-4ed3-4680-a7ca-43fe172d538d", # AcrPull (nodes)
    "8311e382-0749-4cb8-b61a-304f252e45ec", # AcrPush (pipeline)
    "b86a8fe4-44ce-4948-aee5-eccb2c155cd7", # Key Vault Secrets Officer (write the secret)
    "4633458b-17de-408a-b874-0445c86b69e6", # Key Vault Secrets User (app, plan)
    "acdd72a7-3385-48ef-bd42-f606fba81ae7", # Reader (pipeline)
    "4abbcc35-e782-43d8-92c5-2d3f1bd2253f", # Azure Kubernetes Service Cluster User Role (pipeline)
  ]
  assignable_roles = join(", ", local.assignable_role_ids)
}

# ---------------------------------------------------------------- plan
resource "azurerm_user_assigned_identity" "terraform_plan" {
  name                = "id-github-terraform-plan"
  location            = azurerm_resource_group.bootstrap.location
  resource_group_name = azurerm_resource_group.bootstrap.name
  tags                = local.tags

  lifecycle {
    ignore_changes = [tags["created-on"]]
  }
}

resource "azurerm_federated_identity_credential" "plan_main" {
  name                      = "github-main"
  user_assigned_identity_id = azurerm_user_assigned_identity.terraform_plan.id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = local.github_issuer
  subject                   = "${local.github_repo}:ref:refs/heads/${var.github_branch}"
}

resource "azurerm_federated_identity_credential" "plan_pull_request" {
  name                      = "github-pull-request"
  user_assigned_identity_id = azurerm_user_assigned_identity.terraform_plan.id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = local.github_issuer
  subject                   = "${local.github_repo}:pull_request"
}

resource "azurerm_role_assignment" "plan_reader_app" {
  scope                = azurerm_resource_group.app.id
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.terraform_plan.principal_id
}

# The main stack reads the pipeline identities from here (data sources).
resource "azurerm_role_assignment" "plan_reader_bootstrap" {
  scope                = azurerm_resource_group.bootstrap.id
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.terraform_plan.principal_id
}

# ---------------------------------------------------------------- apply
resource "azurerm_user_assigned_identity" "terraform_apply" {
  name                = "id-github-terraform-apply"
  location            = azurerm_resource_group.bootstrap.location
  resource_group_name = azurerm_resource_group.bootstrap.name
  tags                = local.tags

  lifecycle {
    ignore_changes = [tags["created-on"]]
  }
}

resource "azurerm_federated_identity_credential" "apply_environment" {
  name                      = "github-environment-infrastructure"
  user_assigned_identity_id = azurerm_user_assigned_identity.terraform_apply.id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = local.github_issuer
  subject                   = "${local.github_repo}:environment:infrastructure"
}

# Create and change everything inside the application resource group only.
resource "azurerm_role_assignment" "apply_contributor" {
  scope                = azurerm_resource_group.app.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_user_assigned_identity.terraform_apply.principal_id
}

# Assign roles, but only the ones listed above (constrained delegation). The
# condition applies to creating and to deleting role assignments.
resource "azurerm_role_assignment" "apply_rbac_admin" {
  scope                = azurerm_resource_group.app.id
  role_definition_name = "Role Based Access Control Administrator"
  principal_id         = azurerm_user_assigned_identity.terraform_apply.principal_id
  condition_version    = "2.0"
  condition            = <<-EOT
    (
      (!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'}))
      OR
      (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {${local.assignable_roles}})
    )
    AND
    (
      (!(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'}))
      OR
      (@Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {${local.assignable_roles}})
    )
  EOT
}

resource "azurerm_role_assignment" "apply_reader_bootstrap" {
  scope                = azurerm_resource_group.bootstrap.id
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.terraform_apply.principal_id
}
