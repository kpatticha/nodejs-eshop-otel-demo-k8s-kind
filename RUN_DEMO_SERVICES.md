# Run the demo services — send Kubernetes OTel data to Elastic with EDOT

Run two Node.js demo services on a local Kubernetes cluster (kind), auto-instrument
them with OpenTelemetry (zero code changes), and ingest traces, metrics, and logs
into Elastic using the **Elastic Distribution of the OTel Collector (EDOT)**.

Five steps, ~10 minutes. Only one of them needs anything from you: your own Kibana
onboarding credentials.

```
request → frontend ──HTTP──▶ backend          (distributed trace)
             └── injected OTel Node.js SDK ──▶ EDOT daemon collector
                                                    │
                             node logs + metrics ──▶│
                                                    ▼
                                             EDOT gateway ──▶ Elastic
```

## 1. Prerequisites

Docker Desktop, running, with **≥ 6 GB memory** allocated (Settings → Resources), plus:

```bash
brew install kind kubectl helm
```

## 2. Clone the repo

Run everything from the repo root:

```bash
git clone https://github.com/kpatticha/nodejs-eshop-otel-demo-k8s-kind.git
cd nodejs-eshop-otel-demo-k8s-kind
```

## 3. Create the cluster and deploy the apps

```bash
./scripts/setup.sh
```

Creates the kind cluster `nodejs-eshop-otel-demo`, builds both service images, loads
them into the node, deploys them, and waits for both rollouts. Safe to re-run at any
point. When it finishes, both pods are `Running`.

## 4. Install EDOT from the Kibana onboarding page

This is the one manual step — the commands are generated with **your** endpoint, API
key, and onboarding id, so they can't be committed here or copied from a teammate.

1. Open Kibana → **Observability → Add data** (`<kibana-url>/app/observabilityOnboarding`).
2. Under _What do you want to monitor?_ select **Kubernetes**.
3. Pick the **Set up the OpenTelemetry Collector** quickstart.
4. Run the four commands it gives you (helm repo add, create namespace, create the
   `elastic-secret-otel` secret, helm upgrade --install).

That installs the OpenTelemetry Operator, a per-node **daemon collector** (app OTLP,
container logs, node/kubelet metrics), a **cluster-stats collector**, and a **gateway
collector** that exports to Elastic with your API key.

Wait until all pods are ready (Ctrl-C to stop watching):

```bash
kubectl -n opentelemetry-operator-system get pods -w
```

Then re-run setup so the app pods are recreated _after_ the operator exists — the
webhook only injects instrumentation at pod creation:

```bash
./scripts/setup.sh
```

## 5. Generate traffic and look at it

```bash
./scripts/traffic.sh
```

Opens the port-forward, sends 50 request pairs, and tears the tunnel down. Pass a
number for more: `./scripts/traffic.sh 200`. Every `/` request is one distributed
trace across both services; `/checkout` fails ~30% of the time by design, so you get
error traces too.

In Kibana:

- **Applications → Service Inventory** — `frontend` and `backend` appear as services.
- **Traces / Service map** — one trace spans both services, correlated by the
  auto-propagated `traceparent` header.
- **Infrastructure / Kubernetes dashboards** — node and pod metrics, container logs.
- The onboarding page itself detects your incoming data.

## Troubleshooting

| Symptom                                                                       | Fix                                                                                                                                                                                |
| ----------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Anything wrong with the cluster                                               | Don't debug it — `kind delete cluster --name nodejs-eshop-otel-demo`, then `./scripts/setup.sh` (~30s)                                                                             |
| App pods `ErrImagePull`                                                       | Images weren't loaded into the node — re-run `./scripts/setup.sh`                                                                                                                  |
| No `opentelemetry-auto-instrumentation-nodejs` init container in the app pods | The webhook wasn't ready when the pods were created (it fails silently) — re-run `./scripts/setup.sh`. Check with `kubectl -n nodejs-eshop-otel-demo describe pod -l app=frontend` |
| Collector export errors                                                       | `kubectl -n opentelemetry-operator-system logs deploy/opentelemetry-kube-stack-gateway-collector` — check endpoint/API key in the `elastic-secret-otel` secret                     |
| Using a **local** Elasticsearch on your Mac                                   | Pods can't reach `localhost` — use `http://host.docker.internal:9200` as the endpoint in the secret                                                                                |
| No data in Kibana                                                             | Run `./scripts/traffic.sh` again and widen the time range; check the daemon collector logs                                                                                         |

## Teardown

```bash
kind delete cluster --name nodejs-eshop-otel-demo
```

---

Prefer to run each command yourself, or need to debug a step? [MANUAL.md](MANUAL.md)
has the full step-by-step version — the scripts run exactly those commands.
