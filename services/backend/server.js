// Backend service: owns the "product catalog". No OpenTelemetry code here —
// the OTel Operator injects the Node.js auto-instrumentation at pod startup.
const express = require('express');

const app = express();
const PORT = process.env.PORT || 8081;

const PRODUCTS = [
  { id: 1, name: 'Keyboard', price: 49.9 },
  { id: 2, name: 'Mouse', price: 19.9 },
  { id: 3, name: 'Monitor', price: 199.0 },
  { id: 4, name: 'Laptop stand', price: 39.0 },
];

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

app.get('/healthz', (_req, res) => res.json({ status: 'ok' }));

app.get('/api/products', async (_req, res) => {
  // simulate a database lookup
  await sleep(20 + Math.random() * 80);
  res.json(PRODUCTS);
});

app.get('/api/products/:id', async (req, res) => {
  await sleep(10 + Math.random() * 50);
  const product = PRODUCTS.find((p) => p.id === Number(req.params.id));
  if (!product) {
    return res.status(404).json({ error: 'product not found' });
  }
  res.json(product);
});

// occasionally fails, useful to see error traces in Elastic
app.get('/api/flaky', async (_req, res) => {
  await sleep(30);
  if (Math.random() < 0.3) {
    return res.status(500).json({ error: 'simulated backend failure' });
  }
  res.json({ ok: true });
});

app.listen(PORT, () => {
  console.log(`backend listening on :${PORT}`);
});
