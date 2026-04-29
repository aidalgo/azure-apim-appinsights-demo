output "resource_group_name" {
  value = azurerm_resource_group.this.name
}

output "web_app_name" {
  value = azurerm_linux_web_app.this.name
}

output "web_app_url" {
  value = local.webapp_url
}

output "apim_proxy_base_url" {
  description = "Set this as IngestionEndpoint in the browser connection string."
  value       = local.apim_base_url
}

output "application_insights_name" {
  value = azurerm_application_insights.this.name
}

output "browser_connection_string" {
  description = "Drop into VITE_APPINSIGHTS_CONNECTION_STRING for the React app."
  value       = local.browser_connection_string
  sensitive   = true
}
