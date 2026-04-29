import { useState } from 'react';
import {
  flush,
  trackCustomEvent,
  trackException,
  trackMetric,
  trackPageView,
  trackTrace
} from './appInsights';

interface LogEntry {
  ts: string;
  message: string;
}

export function App() {
  const [log, setLog] = useState<LogEntry[]>([]);

  function append(message: string): void {
    setLog((prev) => [
      { ts: new Date().toLocaleTimeString(), message },
      ...prev
    ].slice(0, 25));
  }

  function onPageView() {
    trackPageView('demo-button-page-view');
    append('trackPageView → demo-button-page-view');
  }

  function onCustomEvent() {
    trackCustomEvent('demo-button-clicked', { source: 'demo-ui', button: 'custom-event' });
    append('trackEvent → demo-button-clicked');
  }

  function onTrace() {
    trackTrace('Demo trace emitted from APIM-proxied browser SDK.');
    append('trackTrace → information');
  }

  function onMetric() {
    const value = Math.round(Math.random() * 100);
    trackMetric('demo-button-metric', value);
    append(`trackMetric → demo-button-metric=${value}`);
  }

  function onException() {
    try {
      throw new Error('Demo exception triggered by button click.');
    } catch (err) {
      trackException(err as Error);
      append('trackException → Demo exception');
    }
  }

  function onFlush() {
    flush();
    append('flush() called');
  }

  const ingestion = readIngestionEndpoint();

  return (
    <main style={styles.main}>
      <h1 style={styles.h1}>Application Insights via APIM</h1>
      <p style={styles.lede}>
        This demo sends browser telemetry through Azure API Management. APIM
        authenticates to Application Insights with its managed identity, so the
        ingestion endpoint stays gated even though the browser still carries
        the (non-secret) instrumentation key identifier.
      </p>

      <section style={styles.card}>
        <h2 style={styles.h2}>Telemetry endpoint</h2>
        <code style={styles.code}>{ingestion ?? '(connection string not set)'}</code>
        <p style={styles.note}>
          Open DevTools → Network and confirm POSTs target this URL, not the
          public Azure Monitor ingestion endpoint.
        </p>
      </section>

      <section style={styles.card}>
        <h2 style={styles.h2}>Emit telemetry</h2>
        <div style={styles.buttons}>
          <button style={styles.button} onClick={onPageView}>Page view</button>
          <button style={styles.button} onClick={onCustomEvent}>Custom event</button>
          <button style={styles.button} onClick={onTrace}>Trace</button>
          <button style={styles.button} onClick={onMetric}>Metric</button>
          <button style={styles.button} onClick={onException}>Exception</button>
          <button style={styles.button} onClick={onFlush}>Flush</button>
        </div>
      </section>

      <section style={styles.card}>
        <h2 style={styles.h2}>Activity log</h2>
        {log.length === 0 ? (
          <p style={styles.note}>Click a button to emit telemetry.</p>
        ) : (
          <ul style={styles.list}>
            {log.map((entry, idx) => (
              <li key={idx} style={styles.listItem}>
                <span style={styles.ts}>{entry.ts}</span> {entry.message}
              </li>
            ))}
          </ul>
        )}
      </section>
    </main>
  );
}

function readIngestionEndpoint(): string | undefined {
  const cs = import.meta.env.VITE_APPINSIGHTS_CONNECTION_STRING;
  if (!cs) return undefined;
  const match = cs.split(';').find((part) => part.trim().toLowerCase().startsWith('ingestionendpoint='));
  return match?.split('=').slice(1).join('=').trim();
}

const styles: Record<string, React.CSSProperties> = {
  main: {
    fontFamily: 'system-ui, -apple-system, Segoe UI, Roboto, sans-serif',
    maxWidth: 760,
    margin: '40px auto',
    padding: '0 20px',
    color: '#1f2937'
  },
  h1: { fontSize: 28, marginBottom: 8 },
  h2: { fontSize: 18, margin: '0 0 12px 0' },
  lede: { fontSize: 15, lineHeight: 1.5, color: '#374151' },
  card: {
    background: '#f9fafb',
    border: '1px solid #e5e7eb',
    borderRadius: 8,
    padding: 16,
    margin: '16px 0'
  },
  code: {
    display: 'block',
    background: '#0f172a',
    color: '#e2e8f0',
    padding: '8px 12px',
    borderRadius: 6,
    fontSize: 13,
    overflowX: 'auto'
  },
  note: { fontSize: 13, color: '#6b7280', marginTop: 8 },
  buttons: { display: 'flex', flexWrap: 'wrap', gap: 8 },
  button: {
    background: '#2563eb',
    color: 'white',
    border: 'none',
    padding: '8px 14px',
    borderRadius: 6,
    cursor: 'pointer',
    fontSize: 14
  },
  list: { listStyle: 'none', padding: 0, margin: 0 },
  listItem: {
    fontSize: 13,
    padding: '4px 0',
    borderBottom: '1px solid #e5e7eb',
    fontFamily: 'ui-monospace, SFMono-Regular, Menlo, monospace'
  },
  ts: { color: '#6b7280', marginRight: 8 }
};
