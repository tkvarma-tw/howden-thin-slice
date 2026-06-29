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

variable "acr_instance" {
  type        = string
  default     = "01"
  description = "Instance used by the acr/ module — used to look up ACR and UAMI resources"
}

variable "app_version" {
  type        = string
  default     = "v1"
  description = "The image tag used for both the frontend and backend Docker containers"
}

variable "weather_latitude" {
  type        = string
  default     = "17.385"
  description = "Latitude the backend uses to query the public weather API (default: Hyderabad)"
}

variable "weather_longitude" {
  type        = string
  default     = "78.4867"
  description = "Longitude the backend uses to query the public weather API (default: Hyderabad)"
}

data "azurerm_client_config" "current" {}


# --- Official Azure Naming Module ---
module "naming" {
  source  = "Azure/naming/azurerm"
  version = "~> 0.4.0"
  suffix  = [var.workload, var.environment, var.region_abbr, var.instance]
}

# --- Naming module for ACR instance (instance 01) ---
module "naming_acr" {
  source  = "Azure/naming/azurerm"
  version = "~> 0.4.0"
  suffix  = [var.workload, var.environment, var.region_abbr, var.acr_instance]
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

resource "azurerm_subnet" "snet_apim" {
  name                 = "snet-apim"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.5.0/24"]
}

# --- NSG for APIM subnet (required for Internal VNet mode) ---
# Internal-mode APIM rejects inbound by default; it needs the management
# endpoint (3443) open from the ApiManagement service tag and the infra
# load balancer (6390). Default NSG rules cover everything else.
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

resource "azurerm_subnet" "snet_appgateway" {
  name                 = "snet-appgateway"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.4.0/24"]
  service_endpoints    = ["Microsoft.Web"]

}

# --- Private Subnet for Service Bus Private Endpoint ---
resource "azurerm_subnet" "snet_private_endpoint" {
  name                 = "snet-pe"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.0.0/24"]
}

# --- NAT Gateway (deterministic outbound egress for the backend) ---
# Associated with snet_cae so the Container App backend's outbound traffic
# (to the public weather API) leaves the VNet through a single static IP.
resource "azurerm_public_ip" "nat" {
  name                = module.naming.public_ip.name
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_nat_gateway" "nat" {
  name                = module.naming.nat_gateway.name
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku_name            = "Standard"
}

resource "azurerm_nat_gateway_public_ip_association" "nat" {
  nat_gateway_id       = azurerm_nat_gateway.nat.id
  public_ip_address_id = azurerm_public_ip.nat.id
}

resource "azurerm_subnet_nat_gateway_association" "cae" {
  subnet_id      = azurerm_subnet.snet_cae.id
  nat_gateway_id = azurerm_nat_gateway.nat.id
}

resource "azurerm_network_security_group" "nsg_pe" {
  location            = azurerm_resource_group.main.location
  name                = "${module.naming.network_security_group.name}-pe"
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

resource "azurerm_subnet_network_security_group_association" "pe" {
  subnet_id                 = azurerm_subnet.snet_private_endpoint.id
  network_security_group_id = azurerm_network_security_group.nsg_pe.id
}

# --- Reference UAMI created by the acr/ module ---
data "azurerm_user_assigned_identity" "container_app_identity" {
  name                = module.naming_acr.user_assigned_identity.name
  resource_group_name = module.naming_acr.resource_group.name
}

# --- Reference ACR provisioned by the acr/ module ---
data "azurerm_container_registry" "acr" {
  name                = module.naming_acr.container_registry.name
  resource_group_name = module.naming_acr.resource_group.name
}

resource "random_string" "frontend_suffix" {
  length  = 5
  lower   = true
  upper   = false
  special = false
}

# --- Container App Environment (Private) ---
resource "azurerm_container_app_environment" "cae" {
  name                = module.naming.container_app_environment.name
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  # Lock it inside the Virtual Network
  infrastructure_subnet_id       = azurerm_subnet.snet_cae.id
  internal_load_balancer_enabled = true
  zone_redundancy_enabled        = false

  # Explicitly define the name Azure created
  infrastructure_resource_group_name = "ME_${module.naming.container_app_environment.name}_${azurerm_resource_group.main.name}_${azurerm_resource_group.main.location}"

  # NAT Gateway egress requires a workload profiles environment (not Consumption-only).
  workload_profile {
    name                  = "Consumption"
    workload_profile_type = "Consumption"
  }

  depends_on = [azurerm_subnet_nat_gateway_association.cae]
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

# --- Private DNS Zone for CAE ---
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

# --- Container App (Backend) ---
resource "azurerm_container_app" "backend" {
  name                         = module.naming.container_app.name
  container_app_environment_id = azurerm_container_app_environment.cae.id
  resource_group_name          = azurerm_resource_group.main.name
  revision_mode                = "Single"
  workload_profile_name        = "Consumption"

  identity {
    type         = "SystemAssigned, UserAssigned"
    identity_ids = [data.azurerm_user_assigned_identity.container_app_identity.id]
  }

  registry {
    server   = data.azurerm_container_registry.acr.login_server
    identity = data.azurerm_user_assigned_identity.container_app_identity.id
  }

  template {
    container {
      name   = "demo-backend"
      image  = "${data.azurerm_container_registry.acr.login_server}/demo-backend:${var.app_version}"
      cpu    = 0.25
      memory = "0.5Gi"
      env {
        name  = "WEATHER_LATITUDE"
        value = var.weather_latitude
      }
      env {
        name  = "WEATHER_LONGITUDE"
        value = var.weather_longitude
      }
      env {
        name  = "SERVICEBUS_NAMESPACE"
        value = azurerm_servicebus_namespace.main.name
      }
      env {
        name  = "SERVICEBUS_TOPIC_NAME"
        value = azurerm_servicebus_topic.demo_events.name
      }
      env {
        name  = "SERVICEBUS_SUBSCRIPTION_NAME"
        value = azurerm_servicebus_subscription.demo_processor.name
      }
      env {
        name  = "SQL_SERVER"
        value = "${azurerm_mssql_server.main.name}.database.windows.net"
      }
      env {
        name  = "SQL_DATABASE"
        value = azurerm_mssql_database.main.name
      }
    }

    min_replicas = 1
    max_replicas = 3
  }

  ingress {
    allow_insecure_connections = true
    external_enabled           = false
    target_port                = 80
    traffic_weight {
      percentage      = 100
      latest_revision = true
    }
  }
}

# --- Container App (Aggregator Backend / Service B) ---
resource "azurerm_container_app" "aggregator_backend" {
  name                         = "${module.naming.container_app.name}-aggregator"
  container_app_environment_id = azurerm_container_app_environment.cae.id
  resource_group_name          = azurerm_resource_group.main.name
  revision_mode                = "Single"
  workload_profile_name        = "Consumption"

  identity {
    type         = "SystemAssigned, UserAssigned"
    identity_ids = [data.azurerm_user_assigned_identity.container_app_identity.id]
  }

  registry {
    server   = data.azurerm_container_registry.acr.login_server
    identity = data.azurerm_user_assigned_identity.container_app_identity.id
  }

  template {
    container {
      name   = "demo-aggregator-backend"
      image  = "${data.azurerm_container_registry.acr.login_server}/demo-aggregator-backend:${var.app_version}"
      cpu    = 0.25
      memory = "0.5Gi"

      env {
        name  = "BACKEND_A_URL"
        value = "https://${azurerm_container_app.backend.ingress[0].fqdn}"
      }
      env {
        name  = "SERVICEBUS_NAMESPACE"
        value = azurerm_servicebus_namespace.main.name
      }
      env {
        name  = "SERVICEBUS_TOPIC_NAME"
        value = azurerm_servicebus_topic.demo_events.name
      }
    }
    min_replicas = 1
    max_replicas = 3
  }

  # external_enabled = true exposes the aggregator on the Container App
  # Environment's load balancer. Because the environment is internal-LB
  # (internal_load_balancer_enabled = true), this is VNet-visible only — NOT
  # public. APIM lives in snet-apim (outside this environment); an
  # internal-ingress (external_enabled = false) app is reachable ONLY from other
  # apps inside the same environment, so APIM cannot route to it and the
  # environment returns 404. Making it external lets APIM reach it while it
  # stays private to the VNet. The FQDN drops the ".internal." label as a result.
  ingress {
    allow_insecure_connections = true
    external_enabled           = true
    target_port                = 80
    traffic_weight {
      percentage      = 100
      latest_revision = true
    }
  }
}

# --- Service Bus Namespace ---
resource "azurerm_servicebus_namespace" "main" {
  name                         = module.naming.servicebus_namespace.name
  location                     = azurerm_resource_group.main.location
  resource_group_name          = azurerm_resource_group.main.name
  sku                          = "Premium"
  capacity                     = 1
  premium_messaging_partitions = 1
}

# --- Service Bus Topic ---
resource "azurerm_servicebus_topic" "demo_events" {
  name         = module.naming.servicebus_topic.name
  namespace_id = azurerm_servicebus_namespace.main.id
}

# --- Service Bus Subscription ---
resource "azurerm_servicebus_subscription" "demo_processor" {
  name               = "${module.naming.servicebus_topic.name}-subscription"
  topic_id           = azurerm_servicebus_topic.demo_events.id
  max_delivery_count = 10
}

# --- Service Bus Private Endpoint ---
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

# --- Private DNS Zone for Service Bus ---
resource "azurerm_private_dns_zone" "servicebus" {
  name                = "privatelink.servicebus.windows.net"
  resource_group_name = azurerm_resource_group.main.name
}

# --- Link Private DNS Zone to VNet ---
resource "azurerm_private_dns_zone_virtual_network_link" "servicebus_vnet_link" {
  name                  = "servicebus-vnet-link"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.servicebus.name
  virtual_network_id    = azurerm_virtual_network.vnet.id
  registration_enabled  = false
}

# --- Private DNS A Record for Service Bus ---
resource "azurerm_private_dns_a_record" "servicebus" {
  name                = azurerm_servicebus_namespace.main.name
  zone_name           = azurerm_private_dns_zone.servicebus.name
  resource_group_name = azurerm_resource_group.main.name
  ttl                 = 300
  records             = [azurerm_private_endpoint.servicebus.private_service_connection[0].private_ip_address]
}

# --- Role Assignment: Aggregator Backend - Service Bus Data Sender ---
resource "azurerm_role_assignment" "aggregator_backend_sender" {
  scope                = azurerm_servicebus_namespace.main.id
  role_definition_name = "Azure Service Bus Data Sender"
  principal_id         = azurerm_container_app.aggregator_backend.identity[0].principal_id
}

# --- Role Assignment: Backend - Service Bus Data Receiver ---
resource "azurerm_role_assignment" "backend_receiver" {
  scope                = azurerm_servicebus_namespace.main.id
  role_definition_name = "Azure Service Bus Data Receiver"
  principal_id         = azurerm_container_app.backend.identity[0].principal_id
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

  # Connect to the VNet Subnet
  virtual_network_subnet_id = azurerm_subnet.snet_webapp.id

  # Public access stays enabled but is locked to the App Gateway by the
  # access-restriction rules below (default Deny + Allow snet-appgateway over
  # the Microsoft.Web service endpoint). Disabling public access entirely makes
  # App Service 403 ALL traffic (incl. the AGW probe) since no private endpoint
  # exists, which breaks the gateway with 502.
  public_network_access_enabled = true

  site_config {
    # Force traffic to use Private DNS for resolution
    vnet_route_all_enabled        = true
    ip_restriction_default_action = "Deny"

    # --- HEALTH PROBE CONFIGURATION ---
    health_check_path                 = "/health"
    health_check_eviction_time_in_min = 2
    # ----------------------------------

    application_stack {
      docker_image_name        = "demo-frontend:${var.app_version}"
      docker_registry_url      = "https://${data.azurerm_container_registry.acr.login_server}"
      docker_registry_username = data.azurerm_container_registry.acr.admin_username
      docker_registry_password = data.azurerm_container_registry.acr.admin_password
    }

    ip_restriction {
      action                    = "Allow"
      name                      = "InboundRuleWebApp${var.instance}"
      priority                  = 1
      virtual_network_subnet_id = azurerm_subnet.snet_appgateway.id
    }
  }

  app_settings = {
    # APIM gateway URL is always https://<name>.azure-api.net — known at plan
    # time from the naming module, so we don't need to wait for APIM to finish
    # provisioning (which takes 30-45 min). This lets the Frontend and App
    # Gateway deploy in parallel with APIM.
    "BACKEND_URL"                         = "https://${module.naming.api_management.name}.azure-api.net"
    "WEBSITES_ENABLE_APP_SERVICE_STORAGE" = "false"
    "REGION_NAME"                         = azurerm_resource_group.main.location
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

resource "azurerm_api_management" "apim" {
  name                = module.naming.api_management.name
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  publisher_name      = module.naming.resource_group.name
  publisher_email     = "admin@example.com"

  # Developer tier supports Internal VNet injection; no SLA but sufficient for POC.
  sku_name = "Developer_1"

  # Internal mode — APIM gets a private VIP on snet-apim; no public gateway.
  virtual_network_type = "Internal"
  virtual_network_configuration {
    subnet_id = azurerm_subnet.snet_apim.id
  }

  public_ip_address_id = azurerm_public_ip.apim.id

  identity {
    type = "SystemAssigned"
  }

  # NSG must be in place before APIM is injected into the subnet.
  depends_on = [azurerm_subnet_network_security_group_association.apim]
}

# --- Public IP for APIM Management ---
resource "azurerm_public_ip" "apim" {
  name                = "${module.naming.public_ip.name}-apim"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"
  domain_name_label   = "mgmt-${module.naming.api_management.name}"
}

# --- APIM API: forwards the frontend's calls to the (internal) Aggregator ---
# path="" puts operations at the gateway root, and each operation carries the
# full /api/... path, so APIM forwards to service_url + /api/... unchanged —
# exactly the routes aggregator-backend/server.js already serves.
resource "azurerm_api_management_api" "aggregator" {
  name                  = "aggregator-api"
  resource_group_name   = azurerm_resource_group.main.name
  api_management_name   = azurerm_api_management.apim.name
  revision              = "1"
  display_name          = "Aggregator API"
  path                  = "api"
  protocols             = ["https"]
  subscription_required = false
  service_url           = "https://${azurerm_container_app.aggregator_backend.ingress[0].fqdn}/api"
}

resource "azurerm_api_management_api_operation" "publish_event" {
  operation_id        = "publish-event"
  api_name            = azurerm_api_management_api.aggregator.name
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.main.name
  display_name        = "Publish Event"
  method              = "POST"
  url_template        = "/publish-event"
  response {
    status_code = 200
  }
}

resource "azurerm_api_management_api_operation" "event_status" {
  operation_id        = "event-status"
  api_name            = azurerm_api_management_api.aggregator.name
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.main.name
  display_name        = "Event Status"
  method              = "GET"
  url_template        = "/event-status"
  response {
    status_code = 200
  }
}

resource "azurerm_api_management_api_operation" "aggregated_data" {
  operation_id        = "aggregated-data"
  api_name            = azurerm_api_management_api.aggregator.name
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.main.name
  display_name        = "Aggregated Data"
  method              = "GET"
  url_template        = "/aggregated-data"
  response {
    status_code = 200
  }
}

resource "azurerm_api_management_api_operation" "sql_data" {
  operation_id        = "sql-data"
  api_name            = azurerm_api_management_api.aggregator.name
  api_management_name = azurerm_api_management.apim.name
  resource_group_name = azurerm_resource_group.main.name
  display_name        = "SQL Data"
  method              = "GET"
  url_template        = "/sql-data"
  response {
    status_code = 200
  }
}

# --- APIM policy: stamp a response header so the demo can prove traffic
# actually passed through APIM (the aggregator never sets this header). ---
resource "azurerm_api_management_api_policy" "aggregator" {
  api_name            = azurerm_api_management_api.aggregator.name
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

resource "azurerm_public_ip" "apgw" {
  name                = "${module.naming.public_ip.name}-apgw"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"
  domain_name_label   = "sample-poc"
}



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

  ssl_policy {
    policy_type = "Predefined"
    policy_name = "AppGwSslPolicy20220101"
  }
  backend_http_settings {
    cookie_based_affinity               = "Disabled"
    name                                = "backend-settings-${var.instance}"
    pick_host_name_from_backend_address = true
    port                                = 80
    probe_name                          = "healthprobe${var.instance}"
    protocol                            = "Http"
    request_timeout                     = 20
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
  probe {
    interval                                  = 30
    minimum_servers                           = 0
    name                                      = "healthprobe${var.instance}"
    path                                      = "/health"
    pick_host_name_from_backend_http_settings = true
    protocol                                  = "Http"
    timeout                                   = 30
    unhealthy_threshold                       = 3
    match {
      status_code = ["200-399"]
    }
  }
  request_routing_rule {
    backend_address_pool_name  = "backend-pool-frontend-${var.instance}"
    backend_http_settings_name = "backend-settings-${var.instance}"
    http_listener_name         = "Listener${var.instance}"
    name                       = "Rule${var.instance}"
    priority                   = 1
    rule_type                  = "Basic"
  }
  sku {
    capacity = 1
    name     = "WAF_v2"
    tier     = "WAF_v2"
  }
}

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

# --- Azure SQL Server & Database ---
resource "azurerm_mssql_server" "main" {
  name                = "sql-${var.workload}-${var.environment}-${var.region_abbr}-${var.instance}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  version             = "12.0"

  azuread_administrator {
    login_username              = data.azurerm_client_config.current.object_id
    object_id                   = data.azurerm_client_config.current.object_id
    azuread_authentication_only = true
  }

  public_network_access_enabled = false
}

resource "azurerm_mssql_database" "main" {
  name           = module.naming.mssql_database.name
  server_id      = azurerm_mssql_server.main.id
  sku_name       = "GP_S_Gen5_1"
  zone_redundant = false
}

# --- Private Endpoint for SQL ---
resource "azurerm_private_endpoint" "sql" {
  name                = "${module.naming.private_endpoint.name}-sql"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.snet_private_endpoint.id

  private_service_connection {
    name                           = "${module.naming.private_service_connection.name}-sql"
    private_connection_resource_id = azurerm_mssql_server.main.id
    subresource_names              = ["sqlServer"]
    is_manual_connection           = false
  }
}

resource "azurerm_private_dns_zone" "sql" {
  name                = "privatelink.database.windows.net"
  resource_group_name = azurerm_resource_group.main.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "sql_vnet_link" {
  name                  = "sql-vnet-link"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.sql.name
  virtual_network_id    = azurerm_virtual_network.vnet.id
  registration_enabled  = false
}

resource "azurerm_private_dns_a_record" "sql" {
  name                = azurerm_mssql_server.main.name
  zone_name           = azurerm_private_dns_zone.sql.name
  resource_group_name = azurerm_resource_group.main.name
  ttl                 = 300
  records             = [azurerm_private_endpoint.sql.private_service_connection[0].private_ip_address]
}

# --- Outputs ---
output "frontend_url" {
  value = "http://${azurerm_linux_web_app.frontend.default_hostname}"
}

output "aggregator_backend_url" {
  value       = "http://${azurerm_container_app.aggregator_backend.ingress[0].fqdn}"
  description = "Service B endpoint for frontend requests."
}

output "backend_url" {
  value       = "http://${azurerm_container_app.backend.ingress[0].fqdn}"
  description = "Note: This existing backend is internal-only and will only resolve from within the private network."
}

output "nat_egress_ip" {
  value       = azurerm_public_ip.nat.ip_address
  description = "Static public IP the backend uses to reach the public weather API via the NAT Gateway."
}

output "servicebus_namespace_name" {
  value       = azurerm_servicebus_namespace.main.name
  description = "Service Bus namespace name for use with managed identity authentication."
}

output "servicebus_namespace_id" {
  value       = azurerm_servicebus_namespace.main.id
  description = "Service Bus namespace resource ID."
}

output "servicebus_private_endpoint_ip" {
  value       = azurerm_private_endpoint.servicebus.private_service_connection[0].private_ip_address
  description = "Private IP address of the Service Bus private endpoint."
}

output "private_dns_zone_id" {
  value       = azurerm_private_dns_zone.servicebus.id
  description = "Private DNS zone ID for Service Bus (privatelink.servicebus.windows.net)."
}

output "application_gateway_ip" {
  value       = azurerm_public_ip.apgw.ip_address
  description = "The static public IP address of the Application Gateway."
}

output "apim_gateway_url" {
  value       = azurerm_api_management.apim.gateway_url
  description = "APIM internal gateway URL (resolves to the private VIP via the azure-api.net private DNS zone)."
}

output "apim_name" {
  value       = azurerm_api_management.apim.name
  description = "The API Management service name."
}

output "gateway_url" {
  value       = azurerm_public_ip.apgw.fqdn
  description = "The Application gateway url"
}

# --- Private DNS for APIM (Internal VNet mode) ---
# Internal-mode APIM responds only to its default FQDN (<name>.azure-api.net),
# never to its raw private IP, so we host that zone privately and point the
# gateway hostname at the APIM private VIP. Microsoft suggests scoping rather
# than hosting the whole azure-api.net zone, but for this isolated single-VNet
# demo the full-zone approach is simplest and safe.
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