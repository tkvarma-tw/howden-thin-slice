terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.70.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4.0"
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
  default = "02"
}

variable "acr_name" {
  type = string
  default = "acrhowdendevcin01.azurecr.io"
}

variable "postgresql_admin_username" {
  type    = string
  default = "psqladmin"
}

variable "postgresql_admin_password" {
  type      = string
  sensitive = true
  default   = "Postgres@123"
}

variable "app_version" {
  type        = string
  default     = "v1"
  description = "The image tag used for all Docker containers"
}

data "azurerm_client_config" "current" {}

# --- Parse per-service .env files into maps (static, non-secret vars only) ---
locals {
  _parse_env = {
    cell    = file("${path.module}/envs/cell.env")
    funding = file("${path.module}/envs/funding.env")
    audit   = file("${path.module}/envs/audit.env")
  }
  env_vars = {
    for svc, content in local._parse_env :
    svc => {
      for line in [
        for l in split("\n", content) : trimspace(l)
        if length(trimspace(l)) > 0 && !startswith(trimspace(l), "#")
      ] :
      element(split("=", line), 0) => join("=", slice(split("=", line), 1, length(split("=", line))))
      if length(split("=", line)) >= 2
    }
  }
}


# --- Official Azure Naming Module ---
module "naming" {
  source  = "Azure/naming/azurerm"
  version = "~> 0.4.0"
  suffix  = [var.workload, var.environment, var.region_abbr, var.instance]
}

# --- Resource Group ---
resource "azurerm_resource_group" "main" {
  name     = module.naming.resource_group.name
  location = "centralindia"
}

# --- Virtual Network & Subnets ---
resource "azurerm_virtual_network" "vnet" {
  name                = module.naming.virtual_network.name
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  address_space       = ["10.0.0.0/16"]
}

# --- Web App Subnet (Frontend) ---
resource "azurerm_subnet" "snet_webapp" {
  name                 = "snet-webapp"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"]

  delegation {
    name = "webapp-delegation"
    service_delegation {
      name    = "Microsoft.Web/serverFarms"
      actions = ["Microsoft.Network/virtualNetworks/subnets/action"]
    }
  }
}

# --- Container Apps Environment Subnet ---
resource "azurerm_subnet" "snet_cae" {
  name                 = "snet-cae"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.2.0/23"]

  delegation {
    name = "cae-delegation"
    service_delegation {
      name    = "Microsoft.App/environments"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

# --- APIM Subnet ---
resource "azurerm_subnet" "snet_apim" {
  name                 = "snet-apim"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.5.0/24"]
}

# --- NSG for APIM Subnet ---
resource "azurerm_network_security_group" "apim" {
  name                = module.naming.network_security_group.name
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  security_rule {
    name                       = "AllowApimManagementInbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3443"
    source_address_prefix      = "ApiManagement"
    destination_address_prefix = "VirtualNetwork"
  }

  security_rule {
    name                       = "AllowAzureLoadBalancerInbound"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "6390"
    source_address_prefix      = "AzureLoadBalancer"
    destination_address_prefix = "VirtualNetwork"
  }

  security_rule {
    name                       = "AllowAPIMWebAppInbound"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "VirtualNetwork"
  }
}

resource "azurerm_subnet_network_security_group_association" "apim" {
  subnet_id                 = azurerm_subnet.snet_apim.id
  network_security_group_id = azurerm_network_security_group.apim.id
}

# --- Application Gateway Subnet ---
resource "azurerm_subnet" "snet_appgateway" {
  name                 = "snet-appgateway"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.4.0/24"]
  service_endpoints    = ["Microsoft.Web"]
}

# --- Private Endpoint Subnet ---
resource "azurerm_subnet" "snet_private_endpoint" {
  name                 = "snet-pe"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.0.0/24"]

  # Required for NSG rules to be enforced on private endpoint NICs.
  # Azure disables network policies for PEs by default.
  private_endpoint_network_policies = "Enabled"
}

# --- NSG for Private Endpoint Subnet ---
resource "azurerm_network_security_group" "nsg_pe" {
  location            = azurerm_resource_group.main.location
  name                = "${module.naming.network_security_group.name}-pe"
  resource_group_name = azurerm_resource_group.main.name

  security_rule {
    name                       = "AllowVnetInbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["1433", "443", "5432", "5671", "5672"]
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "VirtualNetwork"
  }

  security_rule {
    name                       = "DenyInternetInbound"
    priority                   = 200
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "pe" {
  subnet_id                 = azurerm_subnet.snet_private_endpoint.id
  network_security_group_id = azurerm_network_security_group.nsg_pe.id
}

# --- User-Assigned Managed Identity for Container Apps ---
resource "azurerm_user_assigned_identity" "container_app_identity" {
  name                = module.naming.user_assigned_identity.name
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
}

# --- Role Assignment: UAMI -> AcrPull on ACR ---
resource "azurerm_role_assignment" "uami_acr_pull" {
  scope                = "/subscriptions/bf64dbbf-7dac-472e-92ca-6ee6c08d1055/resourceGroups/rg-howden-dev-cin-01/providers/Microsoft.ContainerRegistry/registries/acrhowdendevcin01"
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.container_app_identity.principal_id
}


resource "random_string" "frontend_suffix" {
  length  = 5
  lower   = true
  upper   = false
  special = false
}

# --- Container App Environment ---
resource "azurerm_container_app_environment" "cae" {
  name                = module.naming.container_app_environment.name
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  infrastructure_subnet_id       = azurerm_subnet.snet_cae.id
  internal_load_balancer_enabled = true
  zone_redundancy_enabled        = false

  infrastructure_resource_group_name = "ME_${module.naming.container_app_environment.name}_${azurerm_resource_group.main.name}_${azurerm_resource_group.main.location}"

  workload_profile {
    name                  = "Consumption"
    workload_profile_type = "Consumption"
  }
}

resource "azurerm_network_security_group" "nsg_cae" {
  location            = azurerm_resource_group.main.location
  name                = "${module.naming.network_security_group.name}-cae"
  resource_group_name = azurerm_resource_group.main.name
  security_rule       = []
  tags                = {}
}

resource "azurerm_subnet_network_security_group_association" "cae" {
  subnet_id                 = azurerm_subnet.snet_cae.id
  network_security_group_id = azurerm_network_security_group.nsg_cae.id
}

# --- Private DNS Zone for CAE (resolves container app FQDNs inside the VNet) ---
resource "azurerm_private_dns_zone" "cae_zone" {
  name                = azurerm_container_app_environment.cae.default_domain
  resource_group_name = azurerm_resource_group.main.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "vnet_link" {
  name                  = "cae-vnet-link"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.cae_zone.name
  virtual_network_id    = azurerm_virtual_network.vnet.id
}

resource "azurerm_private_dns_a_record" "cae_record" {
  name                = "*"
  zone_name           = azurerm_private_dns_zone.cae_zone.name
  resource_group_name = azurerm_resource_group.main.name
  ttl                 = 300
  records             = [azurerm_container_app_environment.cae.static_ip_address]
}

# --- Container App: Cell Service ---
resource "azurerm_container_app" "cell_service" {
  name                         = "${module.naming.container_app.name}-cell"
  container_app_environment_id = azurerm_container_app_environment.cae.id
  resource_group_name          = azurerm_resource_group.main.name
  revision_mode                = "Single"
  workload_profile_name        = "Consumption"

  identity {
    type         = "SystemAssigned, UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.container_app_identity.id]
  }

  registry {
    server   = var.acr_name
    identity = azurerm_user_assigned_identity.container_app_identity.id
  }

  secret {
    name                = "db-connection-string"
    key_vault_secret_id = azurerm_key_vault_secret.cell_db_connection_string.id
    identity            = azurerm_user_assigned_identity.container_app_identity.id
  }

  secret {
    name                = "servicebus-connection-string"
    key_vault_secret_id = azurerm_key_vault_secret.servicebus_connection_string.id
    identity            = azurerm_user_assigned_identity.container_app_identity.id
  }

  template {
    container {
      name   = "cell-service"
      image  = "${var.acr_name}/cell-service:${var.app_version}"
      cpu    = 0.25
      memory = "0.5Gi"
      dynamic "env" {
        for_each = local.env_vars["cell"]
        content {
          name  = env.key
          value = env.value
        }
      }

      env {
        name        = "ConnectionStrings__CellDb"
        secret_name = "db-connection-string"
      }

      env {
        name        = "ConnectionStrings__ServiceBus"
        secret_name = "servicebus-connection-string"
      }

      env {
        name  = "FundingService__BaseUrl"
        value = "https://${module.naming.container_app.name}-funding.${azurerm_container_app_environment.cae.default_domain}"
      }

      env {
        name  = "AuditService__BaseUrl"
        value = "https://${azurerm_container_app.audit_service.ingress[0].fqdn}"
      }

      env {
        name        = "ServiceBus__ConnectionString"
        secret_name = "servicebus-connection-string"
      }

      env {
        name  = "ServiceBus__TopicName"
        value = azurerm_servicebus_topic.demo_events.name
      }
    }

    min_replicas = 1
    max_replicas = 3
  }

  ingress {
    allow_insecure_connections = true
    external_enabled           = true
    target_port                = 8080
    traffic_weight {
      percentage      = 100
      latest_revision = true
    }
  }
}

# --- Container App: Funding Service ---
resource "azurerm_container_app" "funding_service" {
  name                         = "${module.naming.container_app.name}-funding"
  container_app_environment_id = azurerm_container_app_environment.cae.id
  resource_group_name          = azurerm_resource_group.main.name
  revision_mode                = "Single"
  workload_profile_name        = "Consumption"

  identity {
    type         = "SystemAssigned, UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.container_app_identity.id]
  }

  registry {
    server   = var.acr_name
    identity = azurerm_user_assigned_identity.container_app_identity.id
  }

  secret {
    name                = "db-connection-string"
    key_vault_secret_id = azurerm_key_vault_secret.funding_db_connection_string.id
    identity            = azurerm_user_assigned_identity.container_app_identity.id
  }

  secret {
    name                = "servicebus-connection-string"
    key_vault_secret_id = azurerm_key_vault_secret.servicebus_connection_string.id
    identity            = azurerm_user_assigned_identity.container_app_identity.id
  }

  template {
    container {
      name   = "funding-service"
      image  = "${var.acr_name}/funding-service:${var.app_version}"
      cpu    = 0.25
      memory = "0.5Gi"
      dynamic "env" {
        for_each = local.env_vars["funding"]
        content {
          name  = env.key
          value = env.value
        }
      }

      env {
        name  = "CellService__BaseUrl"
        value = "https://${module.naming.container_app.name}-cell.${azurerm_container_app_environment.cae.default_domain}"
      }

      env {
        name  = "AuditService__BaseUrl"
        value = "https://${azurerm_container_app.audit_service.ingress[0].fqdn}"
      }

      env {
        name        = "ServiceBus__ConnectionString"
        secret_name = "servicebus-connection-string"
      }

      env {
        name        = "ConnectionStrings__FundingDatabase"
        secret_name = "db-connection-string"
      }

      env {
        name  = "ServiceBus__TopicName"
        value = azurerm_servicebus_topic.demo_events.name
      }
    }

    min_replicas = 1
    max_replicas = 3
  }

  ingress {
    allow_insecure_connections = true
    external_enabled           = true
    target_port                = 8081
    traffic_weight {
      percentage      = 100
      latest_revision = true
    }
  }
}

# --- Container App: Audit Service ---
resource "azurerm_container_app" "audit_service" {
  name                         = "${module.naming.container_app.name}-audit"
  container_app_environment_id = azurerm_container_app_environment.cae.id
  resource_group_name          = azurerm_resource_group.main.name
  revision_mode                = "Single"
  workload_profile_name        = "Consumption"

  identity {
    type         = "SystemAssigned, UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.container_app_identity.id]
  }

  registry {
    server   = var.acr_name
    identity = azurerm_user_assigned_identity.container_app_identity.id
  }

  secret {
    name                = "db-connection-string"
    key_vault_secret_id = azurerm_key_vault_secret.audit_db_connection_string.id
    identity            = azurerm_user_assigned_identity.container_app_identity.id
  }

  secret {
    name                = "servicebus-connection-string"
    key_vault_secret_id = azurerm_key_vault_secret.servicebus_connection_string.id
    identity            = azurerm_user_assigned_identity.container_app_identity.id
  }

  template {
    container {
      name   = "audit-service"
      image  = "${var.acr_name}/audit-service:${var.app_version}"
      cpu    = 0.25
      memory = "0.5Gi"
      dynamic "env" {
        for_each = local.env_vars["audit"]
        content {
          name  = env.key
          value = env.value
        }
      }

      env {
        name        = "ServiceBus__ConnectionString"
        secret_name = "servicebus-connection-string"
      }

      env {
        name        = "ConnectionStrings__DefaultConnection"
        secret_name = "db-connection-string"
      }

      env {
        name  = "ServiceBus__TopicName"
        value = azurerm_servicebus_topic.demo_events.name
      }

      env {
        name  = "ServiceBus__SubscriptionName"
        value = azurerm_servicebus_subscription.demo_processor.name
      }
    }

    min_replicas = 1
    max_replicas = 3
  }

  ingress {
    allow_insecure_connections = true
    external_enabled           = true
    target_port                = 8082
    traffic_weight {
      percentage      = 100
      latest_revision = true
    }
  }
}

# --- Service Bus ---
resource "azurerm_servicebus_namespace" "main" {
  name                         = module.naming.servicebus_namespace.name
  location                     = azurerm_resource_group.main.location
  resource_group_name          = azurerm_resource_group.main.name
  sku                          = "Premium"
  capacity                     = 1
  premium_messaging_partitions = 1
}

resource "azurerm_servicebus_topic" "demo_events" {
  name         = module.naming.servicebus_topic.name
  namespace_id = azurerm_servicebus_namespace.main.id
}

resource "azurerm_servicebus_subscription" "demo_processor" {
  name               = "${module.naming.servicebus_topic.name}-subscription"
  topic_id           = azurerm_servicebus_topic.demo_events.id
  max_delivery_count = 10
}

resource "azurerm_private_endpoint" "servicebus" {
  name                = "${module.naming.private_endpoint.name}-sb"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.snet_private_endpoint.id

  private_service_connection {
    name                           = "${module.naming.private_service_connection.name}-sb"
    private_connection_resource_id = azurerm_servicebus_namespace.main.id
    subresource_names              = ["namespace"]
    is_manual_connection           = false
  }
}

resource "azurerm_private_dns_zone" "servicebus" {
  name                = "privatelink.servicebus.windows.net"
  resource_group_name = azurerm_resource_group.main.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "servicebus_vnet_link" {
  name                  = "servicebus-vnet-link"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.servicebus.name
  virtual_network_id    = azurerm_virtual_network.vnet.id
  registration_enabled  = false
}

resource "azurerm_private_dns_a_record" "servicebus" {
  name                = azurerm_servicebus_namespace.main.name
  zone_name           = azurerm_private_dns_zone.servicebus.name
  resource_group_name = azurerm_resource_group.main.name
  ttl                 = 300
  records             = [azurerm_private_endpoint.servicebus.private_service_connection[0].private_ip_address]
}

# --- Role Assignment: Cell Service - Service Bus Data Sender ---
resource "azurerm_role_assignment" "cell_service_sender" {
  scope                = azurerm_servicebus_namespace.main.id
  role_definition_name = "Azure Service Bus Data Sender"
  principal_id         = azurerm_container_app.cell_service.identity[0].principal_id
}

resource "azurerm_role_assignment" "funding_service_sender" {
  scope                = azurerm_servicebus_namespace.main.id
  role_definition_name = "Azure Service Bus Data Sender"
  principal_id         = azurerm_container_app.funding_service.identity[0].principal_id
}

# --- Role Assignment: Audit Service - Service Bus Data Receiver ---
resource "azurerm_role_assignment" "audit_service_receiver" {
  scope                = azurerm_servicebus_namespace.main.id
  role_definition_name = "Azure Service Bus Data Receiver"
  principal_id         = azurerm_container_app.audit_service.identity[0].principal_id
}

# --- App Service Plan ---
resource "azurerm_service_plan" "asp" {
  name                   = module.naming.app_service_plan.name
  location               = azurerm_resource_group.main.location
  resource_group_name    = azurerm_resource_group.main.name
  os_type                = "Linux"
  sku_name               = "S1"
  zone_balancing_enabled = false
  worker_count           = 1
}

# --- Web App (Frontend) ---
resource "azurerm_linux_web_app" "frontend" {
  name                = "${module.naming.app_service.name}-${random_string.frontend_suffix.result}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  service_plan_id     = azurerm_service_plan.asp.id

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.container_app_identity.id]
  }

  virtual_network_subnet_id = azurerm_subnet.snet_webapp.id

  # Public access stays enabled but is locked to the App Gateway by the
  # access-restriction rules below (default Deny + Allow snet-appgateway over
  # the Microsoft.Web service endpoint). Disabling public access entirely makes
  # App Service 403 ALL traffic (incl. the AGW probe) since no private endpoint
  # exists, which breaks the gateway with 502.
  public_network_access_enabled = true

  site_config {
    vnet_route_all_enabled        = true
    ip_restriction_default_action = "Deny"

    health_check_path                 = "/health"
    health_check_eviction_time_in_min = 2

    container_registry_use_managed_identity       = true
    container_registry_managed_identity_client_id = azurerm_user_assigned_identity.container_app_identity.client_id

    application_stack {
      docker_image_name   = "frontend:${var.app_version}"
      docker_registry_url = "https://${var.acr_name}"
    }

    ip_restriction {
      action                    = "Allow"
      name                      = "InboundRuleWebApp${var.instance}"
      priority                  = 1
      virtual_network_subnet_id = azurerm_subnet.snet_appgateway.id
    }
  }

  app_settings = {
    "WEBSITES_ENABLE_APP_SERVICE_STORAGE" = "false"
    "WEBSITES_PORT"                       = "80"
    "REGION_NAME"                         = azurerm_resource_group.main.location
    # These are read at container startup by entrypoint.sh and written into
    # /usr/share/nginx/html/env-config.js, which the browser loads as a plain
    # script before the React bundle. No VITE_ prefix — Vite does not process
    # these; they are pure runtime environment variables for Nginx.
    "CELL_SERVICE_URL"    = "http://${azurerm_public_ip.apgw.fqdn}/cell"
    "FUNDING_SERVICE_URL" = "http://${azurerm_public_ip.apgw.fqdn}/funding"
    "AUDIT_SERVICE_URL"   = "http://${azurerm_public_ip.apgw.fqdn}/audit"
  }
}

resource "azurerm_network_security_group" "nsg_webapp" {
  name                = "${module.naming.network_security_group.name}-webapp"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  security_rule = [{
    access                                     = "Deny"
    description                                = ""
    destination_address_prefix                 = "*"
    destination_address_prefixes               = []
    destination_application_security_group_ids = []
    destination_port_range                     = "80"
    destination_port_ranges                    = []
    direction                                  = "Inbound"
    name                                       = "DenyInternetInbound"
    priority                                   = 100
    protocol                                   = "Tcp"
    source_address_prefix                      = "Internet"
    source_address_prefixes                    = []
    source_application_security_group_ids      = []
    source_port_range                          = "*"
    source_port_ranges                         = []
  }]
  tags = {}
}

resource "azurerm_subnet_network_security_group_association" "webapp" {
  subnet_id                 = azurerm_subnet.snet_webapp.id
  network_security_group_id = azurerm_network_security_group.nsg_webapp.id
}

# --- Public IP for APIM ---
resource "azurerm_public_ip" "apim" {
  name                = "${module.naming.public_ip.name}-apim"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"
  domain_name_label   = "mgmt-${module.naming.api_management.name}"
}

# --- API Management ---
resource "azurerm_api_management" "apim" {
  name                = module.naming.api_management.name
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  publisher_name      = module.naming.resource_group.name
  publisher_email     = "admin@example.com"

  sku_name = "Developer_1"

  virtual_network_type = "Internal"
  virtual_network_configuration {
    subnet_id = azurerm_subnet.snet_apim.id
  }

  public_ip_address_id = azurerm_public_ip.apim.id

  identity {
    type = "SystemAssigned"
  }

  depends_on = [azurerm_subnet_network_security_group_association.apim]
}

# --- Cell Service API ---
resource "azurerm_api_management_api" "cell_service" {
  name                  = "cell-service-api"
  resource_group_name   = azurerm_resource_group.main.name
  api_management_name   = azurerm_api_management.apim.name
  revision              = "1"
  display_name          = "Cell Service API"
  path                  = "cell"
  protocols             = ["http"]
  subscription_required = false
  service_url           = "http://${azurerm_container_app.cell_service.ingress[0].fqdn}"
}

resource "azurerm_api_management_api_operation" "get_all_cells" {
  operation_id        = "get-all-cells"
  api_name            = azurerm_api_management_api.cell_service.name
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.main.name
  display_name        = "Get All Cells"
  method              = "GET"
  url_template        = "/api/v1/cells"
  response {
    status_code = 200
  }
}

resource "azurerm_api_management_api_operation" "get_cell_summary" {
  operation_id        = "get-cell-summary"
  api_name            = azurerm_api_management_api.cell_service.name
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.main.name
  display_name        = "Get Cell Summary"
  method              = "GET"
  url_template        = "/api/v1/cells/{cellId}/summary"
  template_parameter {
    name     = "cellId"
    required = true
    type     = "string"
  }
  response {
    status_code = 200
  }
}

resource "azurerm_api_management_api_operation" "create_cell" {
  operation_id        = "create-cell"
  api_name            = azurerm_api_management_api.cell_service.name
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.main.name
  display_name        = "Create New Cell"
  method              = "POST"
  url_template        = "/api/v1/cells"
  response {
    status_code = 201
  }
}

resource "azurerm_api_management_api_operation" "reset_demo_data" {
  operation_id        = "reset-demo-data"
  api_name            = azurerm_api_management_api.cell_service.name
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.main.name
  display_name        = "Reset Demo Data"
  method              = "DELETE"
  url_template        = "/api/demo/reset/{cellId}"
  template_parameter {
    name     = "cellId"
    required = true
    type     = "string"
  }
  response {
    status_code = 200
  }
}

resource "azurerm_api_management_api_policy" "cell_service" {
  api_name            = azurerm_api_management_api.cell_service.name
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.main.name

  xml_content = <<XML
<policies>
  <inbound><base /></inbound>
  <backend><base /></backend>
  <outbound>
    <base />
    <set-header name="X-Served-Via-APIM" exists-action="override">
      <value>@(context.Deployment.ServiceName)</value>
    </set-header>
  </outbound>
  <on-error><base /></on-error>
</policies>
XML
}

# --- Funding Service API ---
resource "azurerm_api_management_api" "funding_service" {
  name                  = "funding-service-api"
  resource_group_name   = azurerm_resource_group.main.name
  api_management_name   = azurerm_api_management.apim.name
  revision              = "1"
  display_name          = "Funding Service API"
  path                  = "funding"
  protocols             = ["http"]
  subscription_required = false
  service_url           = "http://${azurerm_container_app.funding_service.ingress[0].fqdn}"
}

resource "azurerm_api_management_api_operation" "get_funding_status" {
  operation_id        = "get-funding-status"
  api_name            = azurerm_api_management_api.funding_service.name
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.main.name
  display_name        = "Get Funding Status"
  method              = "GET"
  url_template        = "/api/v1/funding/status/{cellId}"
  template_parameter {
    name     = "cellId"
    required = true
    type     = "string"
  }
  response {
    status_code = 200
  }
}

resource "azurerm_api_management_api_operation" "upload_actual_cashflows" {
  operation_id        = "upload-actual-cashflows"
  api_name            = azurerm_api_management_api.funding_service.name
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.main.name
  display_name        = "Upload Actual Cashflow"
  method              = "POST"
  url_template        = "/api/v1/funding/actual-cashflows"
  response {
    status_code = 200
  }
}

resource "azurerm_api_management_api_operation" "create_expected_cashflow" {
  operation_id        = "create-expected-cashflow"
  api_name            = azurerm_api_management_api.funding_service.name
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.main.name
  display_name        = "Create Expected Cashflow"
  method              = "POST"
  url_template        = "/api/v1/funding/expected-cashflows"
  response {
    status_code = 201
  }
}

resource "azurerm_api_management_api_policy" "funding_service" {
  api_name            = azurerm_api_management_api.funding_service.name
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.main.name

  xml_content = <<XML
<policies>
  <inbound><base /></inbound>
  <backend><base /></backend>
  <outbound>
    <base />
    <set-header name="X-Served-Via-APIM" exists-action="override">
      <value>@(context.Deployment.ServiceName)</value>
    </set-header>
  </outbound>
  <on-error><base /></on-error>
</policies>
XML
}

# --- Audit Service API ---
resource "azurerm_api_management_api" "audit_service" {
  name                  = "audit-service-api"
  resource_group_name   = azurerm_resource_group.main.name
  api_management_name   = azurerm_api_management.apim.name
  revision              = "1"
  display_name          = "Audit Service API"
  path                  = "audit"
  protocols             = ["http"]
  subscription_required = false
  service_url           = "http://${azurerm_container_app.audit_service.ingress[0].fqdn}"
}

resource "azurerm_api_management_api_operation" "get_audit_events" {
  operation_id        = "get-audit-events"
  api_name            = azurerm_api_management_api.audit_service.name
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.main.name
  display_name        = "Get Audit Events"
  method              = "GET"
  url_template        = "/api/v1/audit/events/{entityId}"
  template_parameter {
    name     = "entityId"
    required = true
    type     = "string"
  }
  response {
    status_code = 200
  }
}

resource "azurerm_api_management_api_policy" "audit_service" {
  api_name            = azurerm_api_management_api.audit_service.name
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.main.name

  xml_content = <<XML
<policies>
  <inbound><base /></inbound>
  <backend><base /></backend>
  <outbound>
    <base />
    <set-header name="X-Served-Via-APIM" exists-action="override">
      <value>@(context.Deployment.ServiceName)</value>
    </set-header>
  </outbound>
  <on-error><base /></on-error>
</policies>
XML
}

# --- Private DNS for APIM (resolves <apim-name>.azure-api.net inside the VNet) ---
resource "azurerm_private_dns_zone" "apim" {
  name                = "azure-api.net"
  resource_group_name = azurerm_resource_group.main.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "apim_vnet_link" {
  name                  = "apim-vnet-link"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.apim.name
  virtual_network_id    = azurerm_virtual_network.vnet.id
}

resource "azurerm_private_dns_a_record" "apim" {
  name                = azurerm_api_management.apim.name
  zone_name           = azurerm_private_dns_zone.apim.name
  resource_group_name = azurerm_resource_group.main.name
  ttl                 = 300
  records             = [azurerm_api_management.apim.private_ip_addresses[0]]
}

# --- WAF Policy ---
resource "azurerm_web_application_firewall_policy" "res-0" {
  location            = azurerm_resource_group.main.location
  name                = module.naming.web_application_firewall_policy.name
  resource_group_name = azurerm_resource_group.main.name
  tags                = {}
  managed_rules {
    managed_rule_set {
      type    = "OWASP"
      version = "3.2"
    }
  }
  policy_settings {
    enabled                          = true
    file_upload_limit_in_mb          = 100
    max_request_body_size_in_kb      = 128
    mode                             = "Detection"
    request_body_check               = true
    request_body_inspect_limit_in_kb = 128
  }
}

# --- Public IP for Application Gateway ---
resource "azurerm_public_ip" "apgw" {
  name                = "${module.naming.public_ip.name}-apgw"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"
  domain_name_label   = "howden"
}

# --- Application Gateway + WAF ---
resource "azurerm_application_gateway" "res-0" {
  fips_enabled                      = false
  firewall_policy_id                = azurerm_web_application_firewall_policy.res-0.id
  force_firewall_policy_association = false
  location                          = azurerm_resource_group.main.location
  name                              = module.naming.application_gateway.name
  resource_group_name               = azurerm_resource_group.main.name
  tags                              = {}
  backend_address_pool {
    name = "backend-pool-frontend-${var.instance}"
    # Pre-compute the hostname so App Gateway doesn't wait for the Frontend Web
    # App to finish provisioning. Both can now deploy in parallel (~11 min each).
    fqdns        = ["${module.naming.app_service.name}-${random_string.frontend_suffix.result}.azurewebsites.net"]
    ip_addresses = []
  }

  backend_address_pool {
    name         = "backend-pool-apim-${var.instance}"
    fqdns        = ["${azurerm_api_management.apim.name}.azure-api.net"]
    ip_addresses = []
  }

  ssl_policy {
    policy_type = "Predefined"
    policy_name = "AppGwSslPolicy20220101"
  }

  # probe must be declared before backend_http_settings — Azure API resolves
  # the probe reference during the same CreateOrUpdate call and returns
  # InvalidResourceReference if the probe appears later in the payload.
  probe {
    interval                                  = 30
    minimum_servers                           = 0
    name                                      = "healthprobe${var.instance}"
    path                                      = "/health"
    pick_host_name_from_backend_http_settings = true
    protocol                                  = "Http"
    timeout                                   = 20
    unhealthy_threshold                       = 3
    match {
      status_code = ["200-399"]
    }
  }

  # APIM returns 404 for unknown paths — accept 200-404 so the gateway is
  # considered healthy even though /status isn't a registered API path.
  probe {
    interval                                  = 30
    minimum_servers                           = 0
    name                                      = "healthprobe-apim-${var.instance}"
    path                                      = "/status"
    pick_host_name_from_backend_http_settings = true
    protocol                                  = "Http"
    timeout                                   = 20
    unhealthy_threshold                       = 3
    match {
      status_code = ["200-404"]
    }
  }

  backend_http_settings {
    cookie_based_affinity               = "Disabled"
    name                                = "backend-settings-${var.instance}"
    pick_host_name_from_backend_address = true
    port                                = 80
    probe_name                          = "healthprobe${var.instance}"
    protocol                            = "Http"
    request_timeout                     = 120
    trusted_root_certificate_names      = []
  }

  backend_http_settings {
    cookie_based_affinity               = "Disabled"
    name                                = "backend-settings-apim-${var.instance}"
    pick_host_name_from_backend_address = true
    port                                = 80
    probe_name                          = "healthprobe-apim-${var.instance}"
    protocol                            = "Http"
    request_timeout                     = 120
    trusted_root_certificate_names      = []
  }
  frontend_ip_configuration {
    name                            = "appGwPublicFrontendIpIPv4"
    private_ip_address              = ""
    private_ip_address_allocation   = "Dynamic"
    private_link_configuration_name = ""
    public_ip_address_id            = azurerm_public_ip.apgw.id
  }
  frontend_port {
    name = "port_80"
    port = 80
  }
  gateway_ip_configuration {
    name      = "appGatewayIpConfig"
    subnet_id = azurerm_subnet.snet_appgateway.id
  }
  http_listener {
    frontend_ip_configuration_name = "appGwPublicFrontendIpIPv4"
    frontend_port_name             = "port_80"
    name                           = "Listener${var.instance}"
    protocol                       = "Http"
    require_sni                    = false
  }
  url_path_map {
    name                               = "api-path-map"
    default_backend_address_pool_name  = "backend-pool-frontend-${var.instance}"
    default_backend_http_settings_name = "backend-settings-${var.instance}"

    path_rule {
      name                       = "cell-api-rule"
      paths                      = ["/cell/*"]
      backend_address_pool_name  = "backend-pool-apim-${var.instance}"
      backend_http_settings_name = "backend-settings-apim-${var.instance}"
    }

    path_rule {
      name                       = "funding-api-rule"
      paths                      = ["/funding/*"]
      backend_address_pool_name  = "backend-pool-apim-${var.instance}"
      backend_http_settings_name = "backend-settings-apim-${var.instance}"
    }

    path_rule {
      name                       = "audit-api-rule"
      paths                      = ["/audit/*"]
      backend_address_pool_name  = "backend-pool-apim-${var.instance}"
      backend_http_settings_name = "backend-settings-apim-${var.instance}"
    }
  }
  request_routing_rule {
    http_listener_name = "Listener${var.instance}"
    name               = "Rule${var.instance}"
    priority           = 1
    rule_type          = "PathBasedRouting"
    url_path_map_name  = "api-path-map"
  }
  sku {
    capacity = 1
    name     = "WAF_v2"
    tier     = "WAF_v2"
  }
}

# --- NSG for Application Gateway Subnet ---
resource "azurerm_network_security_group" "res-0" {
  location            = azurerm_resource_group.main.location
  name                = "${module.naming.network_security_group.name}-apgw"
  resource_group_name = azurerm_resource_group.main.name
  security_rule = [{
    access                                     = "Allow"
    description                                = ""
    destination_address_prefix                 = "*"
    destination_address_prefixes               = []
    destination_application_security_group_ids = []
    destination_port_range                     = "65200-65535"
    destination_port_ranges                    = []
    direction                                  = "Inbound"
    name                                       = "Allow-AppGateway-V2Ports"
    priority                                   = 100
    protocol                                   = "*"
    source_address_prefix                      = "*"
    source_address_prefixes                    = []
    source_application_security_group_ids      = []
    source_port_range                          = "*"
    source_port_ranges                         = []
    }, {
    access                                     = "Allow"
    description                                = ""
    destination_address_prefix                 = "VirtualNetwork"
    destination_address_prefixes               = []
    destination_application_security_group_ids = []
    destination_port_range                     = "80"
    destination_port_ranges                    = []
    direction                                  = "Inbound"
    name                                       = "Allow-Internet-HTTP"
    priority                                   = 110
    protocol                                   = "Tcp"
    source_address_prefix                      = "Internet"
    source_address_prefixes                    = []
    source_application_security_group_ids      = []
    source_port_range                          = "*"
    source_port_ranges                         = []
    }, {
    access                                     = "Allow"
    description                                = ""
    destination_address_prefix                 = "VirtualNetwork"
    destination_address_prefixes               = []
    destination_application_security_group_ids = []
    destination_port_range                     = "80"
    destination_port_ranges                    = []
    direction                                  = "Outbound"
    name                                       = "Allow-Outbound-WebApp"
    priority                                   = 110
    protocol                                   = "Tcp"
    source_address_prefix                      = "GatewayManager"
    source_address_prefixes                    = []
    source_application_security_group_ids      = []
    source_port_range                          = "80"
    source_port_ranges                         = []
  }]
  tags = {}
}

resource "azurerm_subnet_network_security_group_association" "apgw" {
  subnet_id                 = azurerm_subnet.snet_appgateway.id
  network_security_group_id = azurerm_network_security_group.res-0.id
}

# --- PostgreSQL Flexible Server: Cell Service ---
resource "azurerm_postgresql_flexible_server" "cell" {
  name                = "psql-${var.workload}-${var.environment}-${var.region_abbr}-${var.instance}-cell"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  version             = "16"
  administrator_login    = var.postgresql_admin_username
  administrator_password = var.postgresql_admin_password
  sku_name               = "B_Standard_B1ms"
  storage_mb             = 32768
  zone                   = "1"

  public_network_access_enabled = false
}

resource "azurerm_postgresql_flexible_server_database" "cell" {
  name      = "celldb"
  server_id = azurerm_postgresql_flexible_server.cell.id
  collation = "en_US.utf8"
  charset   = "utf8"
}

resource "azurerm_private_endpoint" "postgresql_cell" {
  name                = "${module.naming.private_endpoint.name}-psql-cell"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.snet_private_endpoint.id

  private_service_connection {
    name                           = "${module.naming.private_service_connection.name}-psql-cell"
    private_connection_resource_id = azurerm_postgresql_flexible_server.cell.id
    subresource_names              = ["postgresqlServer"]
    is_manual_connection           = false
  }
}

# --- PostgreSQL Flexible Server: Funding Service ---
resource "azurerm_postgresql_flexible_server" "funding" {
  name                = "psql-${var.workload}-${var.environment}-${var.region_abbr}-${var.instance}-funding"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  version             = "16"
  administrator_login    = var.postgresql_admin_username
  administrator_password = var.postgresql_admin_password
  sku_name               = "B_Standard_B1ms"
  storage_mb             = 32768
  zone                   = "1"

  public_network_access_enabled = false
}

resource "azurerm_postgresql_flexible_server_database" "funding" {
  name      = "fundingdb"
  server_id = azurerm_postgresql_flexible_server.funding.id
  collation = "en_US.utf8"
  charset   = "utf8"
}

resource "azurerm_private_endpoint" "postgresql_funding" {
  name                = "${module.naming.private_endpoint.name}-psql-funding"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.snet_private_endpoint.id

  private_service_connection {
    name                           = "${module.naming.private_service_connection.name}-psql-funding"
    private_connection_resource_id = azurerm_postgresql_flexible_server.funding.id
    subresource_names              = ["postgresqlServer"]
    is_manual_connection           = false
  }
}

# --- PostgreSQL Flexible Server: Audit Service ---
resource "azurerm_postgresql_flexible_server" "audit" {
  name                = "psql-${var.workload}-${var.environment}-${var.region_abbr}-${var.instance}-audit"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  version             = "16"
  administrator_login    = var.postgresql_admin_username
  administrator_password = var.postgresql_admin_password
  sku_name               = "B_Standard_B1ms"
  storage_mb             = 32768
  zone                   = "1"

  public_network_access_enabled = false
}

resource "azurerm_postgresql_flexible_server_database" "audit" {
  name      = "auditdb"
  server_id = azurerm_postgresql_flexible_server.audit.id
  collation = "en_US.utf8"
  charset   = "utf8"
}

resource "azurerm_private_endpoint" "postgresql_audit" {
  name                = "${module.naming.private_endpoint.name}-psql-audit"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.snet_private_endpoint.id

  private_service_connection {
    name                           = "${module.naming.private_service_connection.name}-psql-audit"
    private_connection_resource_id = azurerm_postgresql_flexible_server.audit.id
    subresource_names              = ["postgresqlServer"]
    is_manual_connection           = false
  }
}

resource "azurerm_private_dns_zone" "postgresql" {
  name                = "privatelink.postgres.database.azure.com"
  resource_group_name = azurerm_resource_group.main.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "postgresql_vnet_link" {
  name                  = "postgresql-vnet-link"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.postgresql.name
  virtual_network_id    = azurerm_virtual_network.vnet.id
  registration_enabled  = false
}

resource "azurerm_private_dns_a_record" "postgresql_cell" {
  name                = azurerm_postgresql_flexible_server.cell.name
  zone_name           = azurerm_private_dns_zone.postgresql.name
  resource_group_name = azurerm_resource_group.main.name
  ttl                 = 300
  records             = [azurerm_private_endpoint.postgresql_cell.private_service_connection[0].private_ip_address]
}

resource "azurerm_private_dns_a_record" "postgresql_funding" {
  name                = azurerm_postgresql_flexible_server.funding.name
  zone_name           = azurerm_private_dns_zone.postgresql.name
  resource_group_name = azurerm_resource_group.main.name
  ttl                 = 300
  records             = [azurerm_private_endpoint.postgresql_funding.private_service_connection[0].private_ip_address]
}

resource "azurerm_private_dns_a_record" "postgresql_audit" {
  name                = azurerm_postgresql_flexible_server.audit.name
  zone_name           = azurerm_private_dns_zone.postgresql.name
  resource_group_name = azurerm_resource_group.main.name
  ttl                 = 300
  records             = [azurerm_private_endpoint.postgresql_audit.private_service_connection[0].private_ip_address]
}

# --- Key Vault ---
resource "azurerm_key_vault" "main" {
  name                          = module.naming.key_vault.name
  location                      = azurerm_resource_group.main.location
  resource_group_name           = azurerm_resource_group.main.name
  tenant_id                     = data.azurerm_client_config.current.tenant_id
  sku_name                      = "standard"
  rbac_authorization_enabled    = true
  purge_protection_enabled      = false
  soft_delete_retention_days    = 7
  public_network_access_enabled = true
}

resource "azurerm_private_endpoint" "keyvault" {
  name                = "${module.naming.private_endpoint.name}-kv"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.snet_private_endpoint.id

  private_service_connection {
    name                           = "${module.naming.private_service_connection.name}-kv"
    private_connection_resource_id = azurerm_key_vault.main.id
    subresource_names              = ["vault"]
    is_manual_connection           = false
  }
}

resource "azurerm_private_dns_zone" "keyvault" {
  name                = "privatelink.vaultcore.azure.net"
  resource_group_name = azurerm_resource_group.main.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "keyvault_vnet_link" {
  name                  = "keyvault-vnet-link"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.keyvault.name
  virtual_network_id    = azurerm_virtual_network.vnet.id
  registration_enabled  = false
}

resource "azurerm_private_dns_a_record" "keyvault" {
  name                = azurerm_key_vault.main.name
  zone_name           = azurerm_private_dns_zone.keyvault.name
  resource_group_name = azurerm_resource_group.main.name
  ttl                 = 300
  records             = [azurerm_private_endpoint.keyvault.private_service_connection[0].private_ip_address]
}

# Terraform deployer can write secrets during `apply`
resource "azurerm_role_assignment" "terraform_kv_secrets_officer" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# UAMI used by all Container Apps can read secrets at runtime
resource "azurerm_role_assignment" "uami_kv_secrets_user" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.container_app_identity.principal_id
}

# --- Key Vault Secrets ---
resource "azurerm_key_vault_secret" "cell_db_connection_string" {
  name         = "cell-db-connection-string"
  value        = "Host=${azurerm_postgresql_flexible_server.cell.fqdn};Port=5432;Database=${azurerm_postgresql_flexible_server_database.cell.name};Username=${var.postgresql_admin_username};Password=${var.postgresql_admin_password};"
  key_vault_id = azurerm_key_vault.main.id
  depends_on   = [azurerm_role_assignment.terraform_kv_secrets_officer]
}

resource "azurerm_key_vault_secret" "funding_db_connection_string" {
  name         = "funding-db-connection-string"
  value        = "Host=${azurerm_postgresql_flexible_server.funding.fqdn};Port=5432;Database=${azurerm_postgresql_flexible_server_database.funding.name};Username=${var.postgresql_admin_username};Password=${var.postgresql_admin_password};"
  key_vault_id = azurerm_key_vault.main.id
  depends_on   = [azurerm_role_assignment.terraform_kv_secrets_officer]
}

resource "azurerm_key_vault_secret" "audit_db_connection_string" {
  name         = "audit-db-connection-string"
  value        = "Host=${azurerm_postgresql_flexible_server.audit.fqdn};Port=5432;Database=${azurerm_postgresql_flexible_server_database.audit.name};Username=${var.postgresql_admin_username};Password=${var.postgresql_admin_password};"
  key_vault_id = azurerm_key_vault.main.id
  depends_on   = [azurerm_role_assignment.terraform_kv_secrets_officer]
}

resource "azurerm_key_vault_secret" "servicebus_connection_string" {
  name         = "servicebus-connection-string"
  value        = azurerm_servicebus_namespace.main.default_primary_connection_string
  key_vault_id = azurerm_key_vault.main.id
  depends_on   = [azurerm_role_assignment.terraform_kv_secrets_officer]
}

# --- Outputs ---
output "frontend_url" {
  value = "http://${azurerm_linux_web_app.frontend.default_hostname}"
}

output "application_gateway_ip" {
  value       = azurerm_public_ip.apgw.ip_address
  description = "The static public IP address of the Application Gateway."
}

output "gateway_url" {
  value       = azurerm_public_ip.apgw.fqdn
  description = "The Application gateway url."
}

output "apim_gateway_url" {
  value       = azurerm_api_management.apim.gateway_url
  description = "APIM internal gateway URL (resolves to the private VIP via the azure-api.net private DNS zone)."
}

output "apim_name" {
  value       = azurerm_api_management.apim.name
  description = "The API Management service name."
}

output "cell_service_url" {
  value       = "http://${azurerm_container_app.cell_service.ingress[0].fqdn}"
  description = "Cell Service internal URL (resolves within the VNet via private DNS)."
}

output "funding_service_url" {
  value       = "http://${azurerm_container_app.funding_service.ingress[0].fqdn}"
  description = "Funding Service internal URL (resolves within the VNet via private DNS)."
}

output "audit_service_url" {
  value       = "http://${azurerm_container_app.audit_service.ingress[0].fqdn}"
  description = "Audit Service internal URL (resolves within the VNet via private DNS)."
}

output "sql_server_fqdn_cell" {
  value       = azurerm_postgresql_flexible_server.cell.fqdn
  description = "Cell Service PostgreSQL Server FQDN."
}

output "sql_server_fqdn_funding" {
  value       = azurerm_postgresql_flexible_server.funding.fqdn
  description = "Funding Service PostgreSQL Server FQDN."
}

output "sql_server_fqdn_audit" {
  value       = azurerm_postgresql_flexible_server.audit.fqdn
  description = "Audit Service PostgreSQL Server FQDN."
}

output "sql_database_cell" {
  value       = azurerm_postgresql_flexible_server_database.cell.name
  description = "PostgreSQL database name for Cell Service."
}

output "sql_database_funding" {
  value       = azurerm_postgresql_flexible_server_database.funding.name
  description = "PostgreSQL database name for Funding Service."
}

output "sql_database_audit" {
  value       = azurerm_postgresql_flexible_server_database.audit.name
  description = "PostgreSQL database name for Audit Service."
}
