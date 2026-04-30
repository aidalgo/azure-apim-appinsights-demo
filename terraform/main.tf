terraform {
  required_version = ">= 1.6.0"

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
}

resource "random_string" "suffix" {
  length  = 6
  upper   = false
  lower   = true
  numeric = true
  special = false
}

locals {
  suffix             = random_string.suffix.result
  resource_group     = "${var.name_prefix}-rg"
  log_analytics_name = "${var.name_prefix}-law-${local.suffix}"
  appinsights_name   = "${var.name_prefix}-ai-${local.suffix}"
  plan_name          = "${var.name_prefix}-plan-${local.suffix}"
  webapp_name        = "${var.name_prefix}-web-${local.suffix}"
  apim_name          = "${var.name_prefix}-apim-${local.suffix}"

  webapp_url    = "https://${local.webapp_name}.azurewebsites.net"
  apim_base_url = "https://${local.apim_name}.azure-api.net"

  # Region prefix used by App Insights ingestion endpoints, e.g. "eastus2".
  ingestion_region    = lower(replace(var.location, " ", ""))
  ingestion_base_url  = "https://${local.ingestion_region}.in.applicationinsights.azure.com"
  ingestion_track_url = "${local.ingestion_base_url}/v2.1/track"

  # Browser connection string: keep the original ikey but route ingestion via APIM.
  browser_connection_string = "InstrumentationKey=${azurerm_application_insights.this.instrumentation_key};IngestionEndpoint=${local.apim_base_url}/"
}

resource "azurerm_resource_group" "this" {
  name     = local.resource_group
  location = var.location
}

resource "azurerm_log_analytics_workspace" "this" {
  name                = local.log_analytics_name
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

resource "azurerm_application_insights" "this" {
  name                          = local.appinsights_name
  location                      = azurerm_resource_group.this.location
  resource_group_name           = azurerm_resource_group.this.name
  workspace_id                  = azurerm_log_analytics_workspace.this.id
  application_type              = "web"
  local_authentication_disabled = true
}

# Allow the APIM managed identity to publish telemetry to Application Insights.
resource "azurerm_role_assignment" "apim_publishes_to_ai" {
  scope                = azurerm_application_insights.this.id
  role_definition_name = "Monitoring Metrics Publisher"
  principal_id         = azurerm_api_management.this.identity[0].principal_id
}

resource "azurerm_service_plan" "this" {
  name                = local.plan_name
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  os_type             = "Linux"
  sku_name            = "B1"
}

resource "azurerm_linux_web_app" "this" {
  name                = local.webapp_name
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  service_plan_id     = azurerm_service_plan.this.id
  https_only          = true

  site_config {
    always_on = true
    application_stack {
      node_version = "20-lts"
    }
    app_command_line = "npm run start"
  }

  app_settings = {
    WEBSITE_NODE_DEFAULT_VERSION       = "~20"
    SCM_DO_BUILD_DURING_DEPLOYMENT     = "true"
    VITE_APPINSIGHTS_CONNECTION_STRING = local.browser_connection_string
  }
}

resource "azurerm_api_management" "this" {
  name                = local.apim_name
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  publisher_name      = var.publisher_name
  publisher_email     = var.publisher_email
  sku_name            = "BasicV2_1"

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_api_management_named_value" "appinsights_proxy_real_ikey" {
  name                = "appinsights-proxy-real-ikey"
  display_name        = "appinsights-proxy-real-ikey"
  resource_group_name = azurerm_resource_group.this.name
  api_management_name = azurerm_api_management.this.name
  value               = azurerm_application_insights.this.instrumentation_key
  secret              = true
}

resource "azurerm_api_management_api" "appinsights_proxy" {
  name                  = "appinsights-proxy"
  resource_group_name   = azurerm_resource_group.this.name
  api_management_name   = azurerm_api_management.this.name
  revision              = "1"
  display_name          = "App Insights Proxy"
  path                  = "v2/track"
  protocols             = ["https"]
  service_url           = local.ingestion_track_url
  subscription_required = false
}

resource "azurerm_api_management_api_operation" "track_post" {
  operation_id        = "track-post"
  api_name            = azurerm_api_management_api.appinsights_proxy.name
  api_management_name = azurerm_api_management.this.name
  resource_group_name = azurerm_resource_group.this.name
  display_name        = "Track telemetry"
  method              = "POST"
  url_template        = "/"
}

# CORS preflight has to succeed without auth, so allow OPTIONS as well.
resource "azurerm_api_management_api_operation" "track_options" {
  operation_id        = "track-options"
  api_name            = azurerm_api_management_api.appinsights_proxy.name
  api_management_name = azurerm_api_management.this.name
  resource_group_name = azurerm_resource_group.this.name
  display_name        = "Track telemetry (CORS preflight)"
  method              = "OPTIONS"
  url_template        = "/"
}

resource "azurerm_api_management_api_policy" "appinsights_proxy" {
  api_name            = azurerm_api_management_api.appinsights_proxy.name
  api_management_name = azurerm_api_management.this.name
  resource_group_name = azurerm_resource_group.this.name

  xml_content = templatefile("${path.module}/apim-policy.xml.tftpl", {
    allowed_origins = concat(var.allowed_origins, [local.webapp_url])
  })
}

# ------------------------------------------------------------------
# Variant API: same proxy, but APIM injects the real instrumentation
# key into every telemetry envelope. Lets the browser ship a
# placeholder ikey so the real one never leaves Azure.
#
# Exposed to the browser SDK as:
#   IngestionEndpoint=https://<apim>.azure-api.net/v2-secure/
# Which the SDK expands to POST https://<apim>.azure-api.net/v2-secure/v2/track
# ------------------------------------------------------------------

resource "azurerm_api_management_api" "appinsights_proxy_ikey" {
  name                  = "appinsights-proxy-ikey"
  resource_group_name   = azurerm_resource_group.this.name
  api_management_name   = azurerm_api_management.this.name
  revision              = "1"
  display_name          = "App Insights Proxy (ikey injection)"
  path                  = "v2-secure"
  protocols             = ["https"]
  service_url           = local.ingestion_base_url
  subscription_required = false
}

resource "azurerm_api_management_api_operation" "track_post_ikey" {
  operation_id        = "track-post"
  api_name            = azurerm_api_management_api.appinsights_proxy_ikey.name
  api_management_name = azurerm_api_management.this.name
  resource_group_name = azurerm_resource_group.this.name
  display_name        = "Track telemetry"
  method              = "POST"
  url_template        = "/v2/track"
}

resource "azurerm_api_management_api_operation" "track_options_ikey" {
  operation_id        = "track-options"
  api_name            = azurerm_api_management_api.appinsights_proxy_ikey.name
  api_management_name = azurerm_api_management.this.name
  resource_group_name = azurerm_resource_group.this.name
  display_name        = "Track telemetry (CORS preflight)"
  method              = "OPTIONS"
  url_template        = "/v2/track"
}

resource "azurerm_api_management_api_policy" "appinsights_proxy_ikey" {
  api_name            = azurerm_api_management_api.appinsights_proxy_ikey.name
  api_management_name = azurerm_api_management.this.name
  resource_group_name = azurerm_resource_group.this.name

  depends_on = [azurerm_api_management_named_value.appinsights_proxy_real_ikey]

  xml_content = templatefile("${path.module}/apim-policy-ikey.xml.tftpl", {
    allowed_origins = concat(var.allowed_origins, [local.webapp_url])
  })
}
