/// <reference types="vite/client" />

interface ImportMetaEnv {
  /**
   * Application Insights connection string whose `IngestionEndpoint` (and
   * optionally `LiveEndpoint`) point at the APIM proxy URL. The instrumentation
   * key portion is a non-secret identifier; ingestion is gated by APIM + MI.
   */
  readonly VITE_APPINSIGHTS_CONNECTION_STRING: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
