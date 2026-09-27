# Tags on every resource that supports them. They answer "what is this, who
# owns it, who pays, how sensitive is it" directly in Azure (asset inventory).
locals {
  common_tags = {
    project             = var.project_name
    environment         = var.environment
    owner               = var.owner
    managed-by          = "terraform"
    repository          = "github.com/r0b1nr31nh4rdt/learningsteps_evolution"
    data-classification = var.data_classification
    cost-center         = var.cost_center
  }
}

resource "azurerm_resource_group" "main" {
  name     = "rg-${var.project_name}-${var.environment}"
  location = var.location

  tags = local.common_tags

  # "created-on" is added after creation by the course tenant, not by us.
  lifecycle {
    ignore_changes = [tags["created-on"]]
  }
}
