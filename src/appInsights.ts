import { ApplicationInsights, SeverityLevel } from '@microsoft/applicationinsights-web';

let _appInsights: ApplicationInsights | undefined;

/**
 * Initialize the Application Insights JavaScript SDK once.
 *
 * The connection string is read from VITE_APPINSIGHTS_CONNECTION_STRING and is
 * expected to point its IngestionEndpoint at the APIM proxy URL, e.g.:
 *
 *   InstrumentationKey=<ikey>;IngestionEndpoint=https://<apim>.azure-api.net/
 *
 * APIM forwards telemetry to the regional Application Insights ingestion
 * endpoint and authenticates via its system-assigned managed identity.
 */
export function initAppInsights(): ApplicationInsights | undefined {
  if (_appInsights) {
    return _appInsights;
  }

  const connectionString = import.meta.env.VITE_APPINSIGHTS_CONNECTION_STRING;
  if (!connectionString) {
    console.warn(
      '[appInsights] VITE_APPINSIGHTS_CONNECTION_STRING is not set; telemetry disabled.'
    );
    return undefined;
  }

  _appInsights = new ApplicationInsights({
    config: {
      connectionString,
      enableAutoRouteTracking: false,
      disableFetchTracking: false,
      disableAjaxTracking: false,
      loggingLevelConsole: 1
    }
  });

  _appInsights.loadAppInsights();
  _appInsights.trackPageView({ name: 'demo-initial-load' });
  return _appInsights;
}

function client(): ApplicationInsights | undefined {
  return _appInsights;
}

export function trackPageView(name: string): void {
  client()?.trackPageView({ name });
}

export function trackCustomEvent(name: string, properties?: Record<string, string>): void {
  client()?.trackEvent({ name }, properties);
}

export function trackTrace(message: string): void {
  client()?.trackTrace({ message, severityLevel: SeverityLevel.Information });
}

export function trackMetric(name: string, average: number): void {
  client()?.trackMetric({ name, average });
}

export function trackException(error: Error): void {
  client()?.trackException({ exception: error, severityLevel: SeverityLevel.Error });
}

export function flush(): void {
  client()?.flush();
}
