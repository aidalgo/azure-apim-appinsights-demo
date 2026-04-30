# APIM + Application Insights ingestion proxy demo

This repo shows a pattern for public-facing apps that send telemetry from
untrusted clients: put **Azure API Management** in front of the Application
Insights ingestion endpoint instead of letting clients post to it directly.
APIM becomes the controlled entry point, authenticates to Azure Monitor with
managed identity, and forwards telemetry to Application Insights.

The sample app uses React and Vite, but the pattern is framework-agnostic.

It includes two variants:

- **Default proxy flow**: the browser uses the normal Application Insights
  JavaScript SDK and sends telemetry to APIM at `/v2/track`.
- **Placeholder-ikey flow**: the browser sends a placeholder ikey to a
  separate APIM endpoint, and APIM injects the real ikey from a secret named
  value before forwarding the payload.

This matters because a publicly reachable ingestion endpoint can be abused to
send fake or excessive telemetry, which can pollute dashboards, trigger
misleading alerts, and increase ingestion costs. The goal of this repo is to
move that ingestion path behind controls you own.

> **Important caveat.** The Application Insights JavaScript SDK still needs an
> instrumentation key in the browser. Microsoft documents the ikey as a
> non‑secret identifier, not a security token. In the default flow, the
> browser still carries the real ikey because it is the resource identifier
> the SDK sends in the telemetry payload.
>
> What this design hides is the *ingestion endpoint*, not the resource
> identity: APIM authenticates to Azure Monitor with its managed identity, and
> Application Insights local authentication is disabled, so the public
> ingestion endpoint will reject direct telemetry. APIM + managed identity
> replaces the authentication part, not the resource identification part. If
> you put in a random value, the SDK may initialize, but the telemetry will
> not be routed or accepted correctly.
>
> If you also want to keep the real ikey out of the frontend, use the optional
> placeholder-ikey variant. In that mode, the browser sends a placeholder
> value and APIM rewrites the payload with the real ikey from a secret named
> value before forwarding it. That is a separate configuration from the
> default `/v2/track` flow.

## Hardening with APIM

Putting APIM in front of the ingestion endpoint gives you a policy enforcement
point that does not exist when the browser talks to App Insights directly.
Beyond proxying telemetry, APIM lets you add controls around who can send
traffic, how much they can send, and what kinds of requests are accepted.
Consider layering some or all of the following into the
`appinsights-proxy` API policy:

- **Rate limiting / quotas** (`rate-limit-by-key`, `quota-by-key`) keyed on
  caller IP, subscription, or a user claim, to blunt floods and accidental
  client loops.
- **JWT validation** (`validate-jwt`) for authenticated users, so only
  tokens issued by your identity provider (e.g. Entra ID) can post
  telemetry, and unauthenticated traffic is rejected at the edge.
- **Strict CORS** restricted to your app's exact origin(s) instead of `*`.
- **Request size and content-type checks** (`check-header`,
  `validate-content`) to reject oversized or malformed payloads before they
  reach App Insights.
- **IP allow/deny lists** (`ip-filter`) when telemetry should only come
  from known networks.
- **Bot / abuse protection** by fronting APIM with Azure Front Door or
  Application Gateway + WAF.
- **Named values + Key Vault** for any secrets referenced by policies, so
  they are never exposed to the browser.
- **Private ingestion with Azure Monitor Private Link (AMPLS)** if you also
  want the Application Insights ingestion endpoint reachable only over private
  networking. That requires APIM to have private network reachability to Azure
  Monitor; this Basic v2 demo does not configure that.
- **Diagnostic logging** to App Insights/Log Analytics on the APIM API
  itself, so you can see who is calling the proxy and how.

Even if you already rate-limit at APIM, keep an ingestion-volume alert in
place. APIM helps control traffic through the proxy, but an ingestion alert
gives you a second signal for direct telemetry spikes, noisy clients, or buggy
instrumentation before they turn into unexpected cost or excessive noise in
Application Insights. In this demo, Terraform creates an Azure Monitor
scheduled query alert against the shared Log Analytics workspace, filtered to
this specific Application Insights resource.

## Architecture

The default browser flow looks like this:

```
Browser (React + Application Insights JS SDK)
   │  POST https://<apim>.azure-api.net/v2/track
   ▼
Azure API Management (Basic v2, system-assigned managed identity)
  │  + inbound policy, CORS, authentication-managed-identity
  │  + resource=https://monitor.azure.com
   ▼
https://<region>.in.applicationinsights.azure.com/v2.1/track
  │  local authentication disabled
   ▼
Application Insights (workspace-based) → Log Analytics
```

The optional placeholder-ikey variant uses the same backend destination and
managed-identity hop, but the browser posts to
`/v2-secure/v2/track` and APIM rewrites the telemetry before forwarding it.

All resources live in a single resource group, in the configured Azure region
(default: **East US 2**):

- Log Analytics workspace
- Application Insights (workspace-based, local auth disabled)
- App Service plan (Linux B1) + Linux Web App (Node 20)
- API Management (Basic v2) with system-assigned managed identity and two APIs:
  `appinsights-proxy` exposing `POST /v2/track`, and
  `appinsights-proxy-ikey` exposing `POST /v2-secure/v2/track`
- Azure Monitor action group + scheduled query alert for high billable
  ingestion from this App Insights resource

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

To test the placeholder-ikey variant instead, set
`VITE_APPINSIGHTS_CONNECTION_STRING` to
`browser_connection_string_placeholder_ikey`; the browser will then post to
`https://<apim>.azure-api.net/v2-secure/v2/track`.

The extra `/v2-secure` base path is only needed in this demo because both the
original proxy and the placeholder-ikey variant are configured side by side in
the same APIM instance. If you deployed only the placeholder-ikey variant, you
would typically keep the usual `/v2/track` browser-facing path.

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
>
> Terraform also creates an ingestion alert that emails `publisher_email` when
> billable data volume for this App Insights resource exceeds
> `appinsights_ingestion_alert_threshold_mb` in 1 hour (default: 1024 MB).

After apply, capture the outputs:

```bash
terraform output -raw browser_connection_string
terraform output -raw browser_connection_string_placeholder_ikey
terraform output -raw web_app_url
terraform output -raw apim_proxy_base_url
terraform output -raw apim_proxy_ikey_base_url
```

## 3. Optional placeholder-ikey mode

Use `browser_connection_string_placeholder_ikey` if you want the browser
bundle to avoid carrying the real ikey. In that mode, the browser sends the
placeholder value `00000000-0000-0000-0000-000000000000`, and APIM replaces it
server-side before forwarding telemetry to Application Insights.

In this mode APIM:

- accepts browser telemetry at `POST /v2-secure/v2/track`
- uses a different browser-facing base path only so it can coexist with the
  original `POST /v2/track` API in this demo; if you deployed only this
  variant, you would typically keep the normal `/v2/track` browser-facing path
- rewrites the backend URI to `/v2.1/track`
- loads the real ikey from the secret named value
  `appinsights-proxy-real-ikey`
- rewrites each telemetry envelope's `iKey` and `name`
- authenticates to Application Insights with its managed identity before
  forwarding the request

## 4. Build and deploy the React app

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

## 5. Verify telemetry

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
| [src/main.tsx](src/main.tsx) | Bootstraps React and initializes Application Insights |
| [terraform/main.tf](terraform/main.tf) | Core Azure resources: APIM, App Insights, Web App, named value, and ingestion alert |
| [terraform/variables.tf](terraform/variables.tf) | Configurable inputs such as region, allowed origins, publisher email, and alert threshold |
| [terraform/terraform.tfvars.example](terraform/terraform.tfvars.example) | Example Terraform values to copy into `terraform.tfvars` |
| [terraform/apim-policy.xml.tftpl](terraform/apim-policy.xml.tftpl) | Default APIM policy with CORS, managed-identity auth, and client IP stamping |
| [terraform/apim-policy-ikey.xml.tftpl](terraform/apim-policy-ikey.xml.tftpl) | Placeholder-ikey variant that injects the real ikey from an APIM named value |
| [terraform/outputs.tf](terraform/outputs.tf) | Web app URL, APIM URLs, browser connection strings |

## Cleanup

```bash
cd terraform
terraform destroy
```
