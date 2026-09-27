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

variable "github_branch" {
  description = "Only workflow runs on this branch get the Azure identity"
  type        = string
  default     = "main"
}
