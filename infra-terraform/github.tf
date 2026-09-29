# Permissions of the GitHub Actions pipeline. The identity itself lives in
# ../infra-bootstrap (it must survive a rebuild); the roles are granted here
# because they point to resources that are rebuilt. Apply the bootstrap once
# before this stack, otherwise the data source below finds nothing.

data "azurerm_user_assigned_identity" "github" {
  name                = var.github_identity_name
  resource_group_name = var.github_identity_resource_group
}

# Push images to the registry (no delete, no admin).
resource "azurerm_role_assignment" "github_acr_push" {
  scope                = azurerm_container_registry.main.id
  role_definition_name = "AcrPush"
  principal_id         = data.azurerm_user_assigned_identity.github.principal_id
}

# Fetch the cluster credentials (az aks get-credentials). With Entra ID and
# local accounts disabled they contain no secret; what the identity may do in
# the cluster is decided by the Kubernetes roles further below.
resource "azurerm_role_assignment" "github_aks_user" {
  scope                = azurerm_kubernetes_cluster.main.id
  role_definition_name = "Azure Kubernetes Service Cluster User Role"
  principal_id         = data.azurerm_user_assigned_identity.github.principal_id
}

# Read-only view of the resource group, so deploy.sh can look up names and
# IDs (registry, vault, app identity, cluster state) without Terraform state.
resource "azurerm_role_assignment" "github_rg_reader" {
  scope                = data.azurerm_resource_group.main.id
  role_definition_name = "Reader"
  principal_id         = data.azurerm_user_assigned_identity.github.principal_id
}

# Identities of Terraform in the pipeline (created in ../infra-bootstrap).
data "azurerm_user_assigned_identity" "terraform_apply" {
  name                = var.terraform_apply_identity_name
  resource_group_name = var.github_identity_resource_group
}

data "azurerm_user_assigned_identity" "terraform_plan" {
  name                = var.terraform_plan_identity_name
  resource_group_name = var.github_identity_resource_group
}

# terraform plan reads the current value of the secret to compare it with the
# code, so the plan identity needs read access to exactly this secret.
resource "azurerm_role_assignment" "terraform_plan_secret_reader" {
  scope                = azurerm_key_vault_secret.database_url.resource_versionless_id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = data.azurerm_user_assigned_identity.terraform_plan.principal_id
}

# The azurerm provider reads the cluster's credentials while refreshing
# (listClusterUserCredential), so plan needs this role, not just Reader.
# With local accounts disabled these credentials grant nothing by themselves;
# plan has no Kubernetes role, so it can do nothing inside the cluster.
resource "azurerm_role_assignment" "terraform_plan_aks_user" {
  scope                = azurerm_kubernetes_cluster.main.id
  role_definition_name = "Azure Kubernetes Service Cluster User Role"
  principal_id         = data.azurerm_user_assigned_identity.terraform_plan.principal_id
}

# ------------------------------------------------ rights inside the cluster
# (Azure RBAC for Kubernetes; only effective with Entra ID, see aks.tf)

# You: full access, for kubectl, helm and emergencies.
resource "azurerm_role_assignment" "aks_admin" {
  scope                = azurerm_kubernetes_cluster.main.id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = var.admin_object_id
}

# terraform-apply also applies the platform layer (k8s-manifests/platform.yaml:
# namespace, service accounts, Key Vault binding, network policies, and later
# monitoring). It only runs after approval, like terraform apply itself.
resource "azurerm_role_assignment" "terraform_apply_aks_admin" {
  scope                = azurerm_kubernetes_cluster.main.id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = data.azurerm_user_assigned_identity.terraform_apply.principal_id
}

# The deploy identity: only the app layer (k8s-manifests/app.yaml, db-init),
# only in the namespace learningsteps, only the custom role defined in
# ../infra-bootstrap (no secrets, network policies, service accounts, exec).
resource "azurerm_role_assignment" "github_app_deployer" {
  scope                = "${azurerm_kubernetes_cluster.main.id}/namespaces/${var.k8s_namespace}"
  role_definition_name = "LearningSteps App Deployer"
  principal_id         = data.azurerm_user_assigned_identity.github.principal_id
}
