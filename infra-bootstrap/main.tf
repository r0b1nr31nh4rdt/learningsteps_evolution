# Bootstrap: things that must survive "terraform destroy" of the main stack
# in ../infra-terraform. Applied once, by hand, and then left alone.
#
# The GitHub pipeline signs in to Azure as the identity below. If it lived in
# the main stack, every rebuild would give it a new client ID and the GitHub
# settings would have to be changed each time. Its role assignments (what it
# may do) are made in the main stack (github.tf), because they point to
# resources that are rebuilt.

locals {
  tags = {
    project             = "learningsteps"
    environment         = "shared"
    owner               = "robin-reinhardt"
    managed-by          = "terraform"
    repository          = "github.com/${var.github_repository}"
    data-classification = "internal"
    cost-center         = "cybersteps-modul-3"
  }
}

resource "azurerm_resource_group" "bootstrap" {
  name     = "rg-learningsteps-bootstrap"
  location = var.location
  tags     = local.tags

  # "created-on" is added after creation by the course tenant, not by us.
  lifecycle {
    ignore_changes = [tags["created-on"]]
  }
}

# Identity of the GitHub Actions pipeline. It has no password or secret.
resource "azurerm_user_assigned_identity" "github" {
  name                = "id-github-learningsteps"
  location            = azurerm_resource_group.bootstrap.location
  resource_group_name = azurerm_resource_group.bootstrap.name
  tags                = local.tags

  lifecycle {
    ignore_changes = [tags["created-on"]]
  }
}

# OIDC trust: GitHub issues a signed token for every workflow run. Entra ID
# exchanges it for this identity only if the token says: this repository,
# this branch. Pull requests and other branches get no Azure access.
resource "azurerm_federated_identity_credential" "github_main" {
  name                      = "github-${var.github_branch}"
  user_assigned_identity_id = azurerm_user_assigned_identity.github.id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = "https://token.actions.githubusercontent.com"
  subject                   = "repo:${var.github_repository}:ref:refs/heads/${var.github_branch}"
}
