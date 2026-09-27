terraform {
  required_version = ">= 1.7" # "removed" blocks in main.tf

  # State in Azure Storage (created by ../infra-bootstrap) instead of a local
  # file: shared by the laptop and the pipeline, encrypted, versioned, locked
  # while Terraform runs. Access with Entra ID only (no storage keys): locally
  # through "az login", in the pipeline through OIDC (ARM_USE_OIDC=true).
  backend "azurerm" {
    resource_group_name  = "rg-learningsteps-bootstrap"
    storage_account_name = "stlearningstepstfstate"
    container_name       = "tfstate"
    key                  = "learningsteps-dev.tfstate"
    use_azuread_auth     = true
  }

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}
