variable "subscription_id" {
  description = "ID of the Azure subscription"
  type        = string
}

variable "location" {
  description = "Azure region"
  type        = string
  default     = "westeurope"
}

variable "github_repository" {
  description = "GitHub repository (owner/name) whose pipeline may sign in to Azure"
  type        = string
  default     = "r0b1nr31nh4rdt/learningsteps_evolution"
}

variable "github_oidc_repository" {
  description = <<-EOT
    The repository as it appears in the subject of GitHub's OIDC token: owner and
    repository with their immutable numeric IDs (owner@id/repo@id). Unlike names,
    the IDs never change and are never reused, so a deleted and re-created
    repository with the same name does not get access. Taken from the subject
    GitHub presented (error AADSTS700213 in the first pipeline run).
  EOT
  type        = string
  default     = "r0b1nr31nh4rdt@55619504/learningsteps_evolution@1378709940"
}

variable "github_branch" {
  description = "Only workflow runs on this branch get the Azure identity"
  type        = string
  default     = "main"
}
