# React + APIM + Application Insights demo

Minimal demo showing how a React (Vite) app can send browser telemetry through
**Azure API Management** so the Application Insights ingestion endpoint is
gated by APIM's managed identity instead of being called directly from the
browser.

> **Important caveat.** The Application Insights JavaScript SDK still needs an
> instrumentation key in the browser. Microsoft documents the ikey as a
> non‑secret identifier, not a security token. What this design hides is the
> *ingestion endpoint*: APIM authenticates to App Insights using its managed
> identity, and App Insights local authentication is disabled, so the public
> ingestion endpoint will reject any direct telemetry. See:
> <https://techcommunity.microsoft.com/blog/azureobservabilityblog/using-azure-api-management-as-a-proxy-for-application-insights-telemetry/4422236>.

## Architecture

```
Browser (React)
   │  POST https://<apim>.azure-api.net/v2/track
   ▼
Azure API Management (Developer tier, system-assigned MI)
   │  + authentication-managed-identity (resource=https://monitor.azure.com)
   ▼
https://eastus2.in.applicationinsights.azure.com/v2.1/track  (local auth disabled)
   ▼
Application Insights (workspace-based) → Log Analytics
```

All resources live in a single resource group in **East US 2**:

- Log Analytics workspace
- Application Insights (workspace-based, local auth disabled)
- App Service plan (Linux B1) + Linux Web App (Node 20)
- API Management (Basic v2) with system-assigned managed identity and an
  `appinsights-proxy` API exposing `POST /v2/track`

## Prerequisites

- Node.js 20+
- Terraform 1.6+
- Azure CLI, logged in to a subscription where you can create APIM
  (`az login` → `az account set --subscription <id>`)

## 1. Run locally (without infra)

You can validate the UI without provisioning anything; telemetry just won't
flow until the connection string points at a real APIM proxy.

```bash
npm install
cp .env.example .env.local
npm run dev
```

Open <http://localhost:5173> and click the buttons. Watch the Network tab —
once `VITE_APPINSIGHTS_CONNECTION_STRING` points at APIM, every telemetry
POST should target `https://<apim>.azure-api.net/v2/track`.

## 2. Provision Azure with Terraform

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars and set publisher_email
terraform init
terraform fmt
terraform validate
terraform plan
terraform apply
```

> APIM Basic v2 provisioning usually completes in a few minutes (the legacy
> Developer/Basic tiers took 30–45 minutes).

After apply, capture the outputs:

```bash
terraform output -raw browser_connection_string
terraform output -raw web_app_url
terraform output -raw apim_proxy_base_url
```

## 3. Build and deploy the React app

Vite bakes `VITE_APPINSIGHTS_CONNECTION_STRING` into the bundle at **build
time**. Terraform sets that value as an App Service app setting, so when
Oryx runs `npm run build` on the server it has the right connection string
and you do **not** need a `.env.production.local`. Just zip the source and
let Oryx build:

```bash
cd ..
# Zip source only — App Service (Oryx) will run npm install + npm run build + npm run start.
zip -r app.zip . -x "node_modules/*" "dist/*" "terraform/*" ".git/*" ".env*"

WEBAPP=$(cd terraform && terraform output -raw web_app_name)
RG=$(cd terraform && terraform output -raw resource_group_name)
az webapp deploy --resource-group "$RG" --name "$WEBAPP" --src-path app.zip --type zip
```

> If you change the connection string in Azure later, restart the Web App so
> Oryx rebuilds with the new value (`az webapp restart -g $RG -n $WEBAPP`).
> If the page shows `(connection string not set)`, the app setting was
> missing during build — re-run `terraform apply` and redeploy.

Open the `web_app_url` output and click each button.

## 4. Verify telemetry

In the Azure portal, open the Application Insights resource → **Logs** and run:

```kusto
union pageViews, customEvents, traces, customMetrics, exceptions
| where timestamp > ago(15m)
| project timestamp, itemType, name, message
| order by timestamp desc
```

You should see `demo-button-page-view`, `demo-button-clicked`, the trace
message, `demo-button-metric`, and the exception entry.

To prove the gating works, confirm that the App Insights resource shows
**Local Authentication: Disabled** (Properties pane), and that
`Monitoring Metrics Publisher` is granted to the APIM managed identity on
that resource (Access control → Role assignments).

## File map

| Path | Purpose |
| --- | --- |
| [src/appInsights.ts](src/appInsights.ts) | Initializes the JS SDK and exposes telemetry helpers |
| [src/App.tsx](src/App.tsx) | UI with one button per telemetry type |
| [terraform/main.tf](terraform/main.tf) | All Azure resources |
| [terraform/apim-policy.xml.tftpl](terraform/apim-policy.xml.tftpl) | CORS + managed-identity inbound policy |
| [terraform/outputs.tf](terraform/outputs.tf) | Web app URL, APIM URL, browser connection string |

## Cleanup

```bash
cd terraform
terraform destroy
```
