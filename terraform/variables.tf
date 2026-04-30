variable "name_prefix" {
  description = "Short prefix used to name all resources in the demo. Lowercase letters/numbers only."
  type        = string
  default     = "apimaidemo"

  validation {
    condition     = can(regex("^[a-z0-9]{3,12}$", var.name_prefix))
    error_message = "name_prefix must be 3-12 lowercase letters or digits."
  }
}

variable "location" {
  description = "Azure region. The demo is designed for East US 2."
  type        = string
  default     = "eastus2"
}

variable "publisher_name" {
  description = "APIM publisher display name (visible in the developer portal)."
  type        = string
  default     = "App Insights APIM Demo"
}

variable "publisher_email" {
  description = "APIM publisher email (must be a real address)."
  type        = string
}

variable "allowed_origins" {
  description = "Origins (full URLs) allowed to call the APIM telemetry proxy from the browser. The deployed Web App URL is added automatically."
  type        = list(string)
  default     = ["http://localhost:5173"]
}

variable "appinsights_ingestion_alert_threshold_mb" {
  description = "Alert threshold in MB for billable ingestion from this App Insights resource over the last hour."
  type        = number
  default     = 1024
}
