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

# The resource group is created by ../infra-bootstrap (so the pipeline's apply
# identity needs rights on this group only). This stack just reads it.
data "azurerm_resource_group" "main" {
  name = "rg-${var.project_name}-${var.environment}"
}

# Earlier this stack created the group itself. "removed" drops it from this
# state WITHOUT deleting it in Azure; the bootstrap has imported it.
removed {
  from = azurerm_resource_group.main

  lifecycle {
    destroy = false
  }
}
