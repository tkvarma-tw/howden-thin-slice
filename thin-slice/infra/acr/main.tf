terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.70.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "3.3.0"
    }
  }
}

provider "azurerm" {
  features {}
}

# --- Variables ---
variable "environment" {
  type    = string
  default = "dev"
}

variable "workload" {
  type    = string
  default = "howden"
}

variable "region_abbr" {
  type    = string
  default = "cin"
}

variable "instance" {
  type    = string
  default = "01"
}

variable "app_version" {
  type        = string
  default     = "v1"
  description = "Tag applied to all images when pushed to ACR"
}

# Local image names reflect what the developer tagged when running `docker build`.
# Override via -var or terraform.tfvars if your local names differ.

variable "frontend_local_image" {
  type        = string
  default     = "poc-frontend"
  description = "Local Docker image name for the frontend (poc_frontend_ils repo)"
}

variable "frontend_local_tag" {
  type        = string
  default     = "latest"
  description = "Local Docker tag for the frontend image"
}

variable "audit_service_local_image" {
  type        = string
  default     = "audit-service"
  description = "Local Docker image name for the audit-service repo"
}

variable "audit_service_local_tag" {
  type        = string
  default     = "latest"
  description = "Local Docker tag for the audit service image"
}

variable "funding_service_local_image" {
  type        = string
  default     = "funding-service"
  description = "Local Docker image name for the funding-service repo"
}

variable "funding_service_local_tag" {
  type        = string
  default     = "latest"
  description = "Local Docker tag for the funding service image"
}

variable "cell_service_local_image" {
  type        = string
  default     = "cell-service"
  description = "Local Docker image name for the cell-service repo"
}

variable "cell_service_local_tag" {
  type        = string
  default     = "latest"
  description = "Local Docker tag for the cell service image"
}

# --- Naming module (same suffix convention as main infra) ---
module "naming" {
  source  = "Azure/naming/azurerm"
  version = "~> 0.4.0"
  suffix  = [var.workload, var.environment, var.region_abbr, var.instance]
}

# --- Resource Group for ACR ---
resource "azurerm_resource_group" "acr" {
  name     = module.naming.resource_group.name
  location = "centralindia"
}

# --- Azure Container Registry ---
resource "azurerm_container_registry" "acr" {
  name                = module.naming.container_registry.name
  resource_group_name = azurerm_resource_group.acr.name
  location            = azurerm_resource_group.acr.location
  sku                 = "Basic"
  admin_enabled       = true
}

# --- User-Assigned Managed Identity for Container Apps ---
resource "azurerm_user_assigned_identity" "container_app_identity" {
  name                = module.naming.user_assigned_identity.name
  resource_group_name = azurerm_resource_group.acr.name
  location            = azurerm_resource_group.acr.location
}

# --- Role Assignment: UAMI -> AcrPull on ACR ---
resource "azurerm_role_assignment" "uami_acr_pull" {
  scope                = azurerm_container_registry.acr.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.container_app_identity.principal_id
}

# --- Push Docker images to ACR ---
# Single login via the current Azure CLI session followed by sequential pushes.
# Re-runs automatically when app_version or any local image name/tag changes.
resource "null_resource" "push_images" {
  triggers = {
    version_tag           = var.app_version
    acr_server            = azurerm_container_registry.acr.login_server
    frontend_image        = var.frontend_local_image
    frontend_tag          = var.frontend_local_tag
    audit_service_image   = var.audit_service_local_image
    audit_service_tag     = var.audit_service_local_tag
    funding_service_image = var.funding_service_local_image
    funding_service_tag   = var.funding_service_local_tag
    cell_service_image    = var.cell_service_local_image
    cell_service_tag      = var.cell_service_local_tag
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      docker logout ${azurerm_container_registry.acr.login_server} 2>/dev/null || true
      az acr login --name ${azurerm_container_registry.acr.name} --resource-group ${azurerm_resource_group.acr.name}

      docker tag ${var.frontend_local_image}:${var.frontend_local_tag} ${azurerm_container_registry.acr.login_server}/poc-frontend:${var.app_version}
      docker push ${azurerm_container_registry.acr.login_server}/poc-frontend:${var.app_version}

      docker tag ${var.audit_service_local_image}:${var.audit_service_local_tag} ${azurerm_container_registry.acr.login_server}/audit-service:${var.app_version}
      docker push ${azurerm_container_registry.acr.login_server}/audit-service:${var.app_version}

      docker tag ${var.funding_service_local_image}:${var.funding_service_local_tag} ${azurerm_container_registry.acr.login_server}/funding-service:${var.app_version}
      docker push ${azurerm_container_registry.acr.login_server}/funding-service:${var.app_version}

      docker tag ${var.cell_service_local_image}:${var.cell_service_local_tag} ${azurerm_container_registry.acr.login_server}/cell-service:${var.app_version}
      docker push ${azurerm_container_registry.acr.login_server}/cell-service:${var.app_version}
    EOT
  }

  depends_on = [azurerm_container_registry.acr]
}

# --- Outputs ---
output "uami_id" {
  value       = azurerm_user_assigned_identity.container_app_identity.id
  description = "UAMI resource ID — reference this in container app identity blocks in main infra."
}

output "uami_principal_id" {
  value       = azurerm_user_assigned_identity.container_app_identity.principal_id
  description = "UAMI principal ID."
}

output "acr_login_server" {
  value       = azurerm_container_registry.acr.login_server
  description = "ACR login server URL"
}

output "acr_name" {
  value       = azurerm_container_registry.acr.name
  description = "ACR resource name"
}

output "acr_id" {
  value       = azurerm_container_registry.acr.id
  description = "ACR resource ID"
}

output "acr_admin_username" {
  value       = azurerm_container_registry.acr.admin_username
  description = "ACR admin username (used by Web App for docker registry auth)"
  sensitive   = true
}

output "acr_admin_password" {
  value       = azurerm_container_registry.acr.admin_password
  description = "ACR admin password (used by Web App for docker registry auth)"
  sensitive   = true
}
