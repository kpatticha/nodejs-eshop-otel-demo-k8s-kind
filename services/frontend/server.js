// Frontend service: public entry point. Calls the backend service over HTTP,
// so every request produces a distributed trace spanning both services.
// No OpenTelemetry code here — the OTel Operator injects the Node.js
// auto-instrumentation at pod startup and propagates trace context (W3C
// traceparent header) on outgoing HTTP calls automatically.
const express = require('express');

const app = express();
const PORT = process.env.PORT || 8080;
const BACKEND_URL = process.env.BACKEND_URL || 'http://backend:8081';

app.get('/healthz', (_req, res) => res.json({ status: 'ok' }));

// Full flow: fetch product list, then fetch one product detail -> 2 downstream calls
app.get('/', async (_req, res) => {
  try {
    const listRes = await fetch(`${BACKEND_URL}/api/products`);
    const products = await listRes.json();

    const pick = products[Math.floor(Math.random() * products.length)];
    const detailRes = await fetch(`${BACKEND_URL}/api/products/${pick.id}`);
    const detail = await detailRes.json();

    res.json({ service: 'frontend', productCount: products.length, featured: detail });
  } catch (err) {
    console.error('error calling backend:', err.message);
    res.status(502).json({ error: 'backend unavailable', detail: err.message });
  }
});

// Proxies the flaky backend endpoint -> produces error traces sometimes
app.get('/checkout', async (_req, res) => {
  try {
    const r = await fetch(`${BACKEND_URL}/api/flaky`);
    if (!r.ok) {
      return res.status(500).json({ error: 'checkout failed downstream' });
    }
    res.json({ service: 'frontend', checkout: 'success' });
  } catch (err) {
    res.status(502).json({ error: 'backend unavailable', detail: err.message });
  }
});

app.listen(PORT, () => {
  console.log(`frontend listening on :${PORT}, backend at ${BACKEND_URL}`);
});
