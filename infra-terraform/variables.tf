variable "subscription_id" {
  description = "ID of the Azure subscription everything is created in"
  type        = string
}

variable "location" {
  description = "Azure region for all resources"
  type        = string
  default     = "westeurope"
}

variable "project_name" {
  description = "Project name, used as part of every resource name"
  type        = string
  default     = "learningsteps"
}

variable "environment" {
  description = "Environment (dev, prod, ...), used as part of every resource name"
  type        = string
  default     = "dev"
}

variable "vnet_address_space" {
  description = "Address space of the virtual network"
  type        = list(string)
  default     = ["10.10.0.0/16"]
}

variable "aks_subnet_prefix" {
  description = "Subnet for the AKS nodes (must be inside vnet_address_space)"
  type        = string
  default     = "10.10.0.0/24"
}

variable "postgres_subnet_prefix" {
  description = "Delegated subnet for the PostgreSQL flexible server (must be inside vnet_address_space)"
  type        = string
  default     = "10.10.1.0/24"
}

variable "aks_node_size" {
  description = "VM size of the AKS nodes"
  type        = string
  default     = "Standard_D2s_v6"
}

variable "aks_min_node_count" {
  description = "Minimum number of AKS nodes (cluster autoscaler)"
  type        = number
  default     = 2
}

variable "aks_max_node_count" {
  description = "Maximum number of AKS nodes (cluster autoscaler). 3 x 2 vCPU plus one upgrade node stays within the 10 vCPU quota"
  type        = number
  default     = 3
}

variable "aks_availability_zones" {
  description = "Availability zones for the AKS nodes. In westeurope, Standard_D2s_v6 is only available in zone 3 for this subscription"
  type        = list(string)
  default     = ["3"]
}

variable "postgres_version" {
  description = "PostgreSQL major version"
  type        = string
  default     = "16"
}

variable "postgres_sku" {
  description = "Compute size of the PostgreSQL flexible server (B_ = Burstable tier)"
  type        = string
  default     = "B_Standard_B1ms"
}

variable "postgres_storage_mb" {
  description = "Storage size of the PostgreSQL flexible server in MB (32768 is the smallest size)"
  type        = number
  default     = 32768
}

variable "postgres_zone" {
  description = "Availability zone of the PostgreSQL flexible server (same zone as the AKS nodes)"
  type        = string
  default     = "3"
}

variable "postgres_admin_user" {
  description = "Admin user of the PostgreSQL flexible server"
  type        = string
  default     = "psqladmin"
}

variable "postgres_database_name" {
  description = "Name of the application database"
  type        = string
  default     = "learning_journal"
}

variable "k8s_namespace" {
  description = "Kubernetes namespace the app runs in (part of the workload identity binding)"
  type        = string
  default     = "learningsteps"
}

variable "k8s_service_account" {
  description = "Kubernetes service account of the app (part of the workload identity binding)"
  type        = string
  default     = "learningsteps-app"
}

variable "owner" {
  description = "Person or team responsible for the resources (tag)"
  type        = string
  default     = "robin-reinhardt"
}

variable "data_classification" {
  description = "Sensitivity of the data the resources hold (tag): public, internal, confidential"
  type        = string
  default     = "internal"
}

variable "cost_center" {
  description = "Who pays for the resources (tag)"
  type        = string
  default     = "cybersteps-modul-3"
}

variable "github_identity_name" {
  description = "Identity of the GitHub pipeline, created in ../infra-bootstrap"
  type        = string
  default     = "id-github-learningsteps"
}

variable "github_identity_resource_group" {
  description = "Resource group of the GitHub pipeline identity (../infra-bootstrap)"
  type        = string
  default     = "rg-learningsteps-bootstrap"
}

variable "terraform_apply_identity_name" {
  description = "Identity of terraform apply in the pipeline (../infra-bootstrap)"
  type        = string
  default     = "id-github-terraform-apply"
}

variable "terraform_plan_identity_name" {
  description = "Identity of terraform plan in the pipeline (../infra-bootstrap)"
  type        = string
  default     = "id-github-terraform-plan"
}

variable "keyvault_admin_object_id" {
  description = "Object ID of the person who may also write Key Vault secrets (az ad signed-in-user show --query id)"
  type        = string
  default     = "7f532ea2-37ce-47db-a9e2-ab43789e96fb"
}
