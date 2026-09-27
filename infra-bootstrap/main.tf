# Bootstrap: things that must exist before the main stack in ../infra-terraform
# and survive its "terraform destroy". Applied by hand (as Owner), rarely.
#
#   main.tf        resource groups, deploy identity (build/push/deploy)
#   state.tf       storage for the Terraform state of the main stack
#   identities.tf  plan and apply identities for Terraform in the pipeline
#
# The pipeline identities live here so their client IDs stay the same across
# rebuilds; otherwise the GitHub variables would have to change each time.

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
    prevent_destroy = true
    ignore_changes  = [tags["created-on"]]
  }
}

# Resource group of the application. Created here and not in the main stack,
# so the apply identity needs rights on this one group only, instead of
# Contributor on the whole subscription (which would include every other
# resource group). The group already existed (created by the main stack);
# the import block takes it over without recreating it.
import {
  to = azurerm_resource_group.app
  id = "/subscriptions/${var.subscription_id}/resourceGroups/rg-learningsteps-dev"
}

resource "azurerm_resource_group" "app" {
  name     = "rg-learningsteps-dev"
  location = var.location
  tags     = merge(local.tags, { environment = "dev" })

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [tags["created-on"]]
  }
}

# Identity of the deploy steps (build, push, deploy). No password or secret.
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
  subject                   = "repo:${var.github_oidc_repository}:ref:refs/heads/${var.github_branch}"
}

# The deploy job runs in the GitHub environment "production" (deployment
# history on GitHub). A job with an environment gets a token whose subject
# names the environment instead of the branch.
resource "azurerm_federated_identity_credential" "github_production" {
  name                      = "github-environment-production"
  user_assigned_identity_id = azurerm_user_assigned_identity.github.id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = "https://token.actions.githubusercontent.com"
  subject                   = "repo:${var.github_oidc_repository}:environment:production"
}
