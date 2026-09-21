# Manual runbook — every command, one at a time

This is the long form of [RUN_DEMO_SERVICES.md](RUN_DEMO_SERVICES.md). Same result, but you run each
command yourself instead of the scripts. Use it when you want to understand each step,
or when something broke and you need to poke at it.

Every step is a standard `kind` / `docker` / `kubectl` / `helm` command, and the
Elastic-specific commands are copied from your own Kibana onboarding page.

```
request → frontend ──HTTP──▶ backend          (distributed trace)
             └── injected OTel Node.js SDK ──▶ EDOT daemon collector
                                                    │
                             node logs + metrics ──▶│
                                                    ▼
                                             EDOT gateway ──▶ Elastic
```

## 1. Prerequisites

- Docker Desktop, running, with **≥ 6 GB memory** allocated (Settings → Resources)
- kind, kubectl, helm:

```bash
brew install kind kubectl helm
```

## 2. Clone the repo

Run **all remaining commands from the repo root** — every path below is relative
to it:

```bash
git clone https://github.com/kpatticha/nodejs-eshop-otel-demo-k8s-kind.git
cd nodejs-eshop-otel-demo-k8s-kind
```

## 3. Create the cluster

The cluster config is committed as [kind.yaml](kind.yaml) (pins the Kubernetes
node image so everyone gets the same version):

```bash
kind create cluster --config kind.yaml --wait 120s
```

This creates a cluster named `nodejs-eshop-otel-demo` and switches your kubectl context to
`kind-nodejs-eshop-otel-demo`. Verify:

```bash
kubectl get nodes
```

If anything is ever wrong with the cluster, don't debug it — recreate it
(takes ~30 seconds):

```bash
kind delete cluster --name nodejs-eshop-otel-demo
```

## 4. Build and deploy the demo services

Build both images and load them into the kind node (no registry needed):

```bash
docker build -t nodejs-eshop-otel-demo-backend:1.0.0 services/backend
docker build -t nodejs-eshop-otel-demo-frontend:1.0.0 services/frontend
kind load docker-image nodejs-eshop-otel-demo-backend:1.0.0 nodejs-eshop-otel-demo-frontend:1.0.0 --name nodejs-eshop-otel-demo
```

Deploy:

```bash
kubectl apply -f k8s/namespace.yaml -f k8s/backend.yaml -f k8s/frontend.yaml
```

Verify both pods are `Running`:

```bash
kubectl -n nodejs-eshop-otel-demo get pods
```

The deployments already carry the auto-instrumentation annotation in their pod
template (nothing to add later):

```yaml
annotations:
  instrumentation.opentelemetry.io/inject-nodejs: "opentelemetry-operator-system/elastic-instrumentation"
```

## 5. Get the install commands from Kibana onboarding

1. Open Kibana → **Observability → Add data** (`<kibana-url>/app/observabilityOnboarding`).
2. Under *What do you want to monitor?* select **Kubernetes**.
3. Pick the **OpenTelemetry: Full Observability** quickstart
   (`/app/observabilityOnboarding/otel-kubernetes/?category=kubernetes`).
4. The page generates commands **with your deployment's endpoint, API key, and
   onboarding id filled in**. Don't copy them from a teammate — the credentials and
   onboarding id are unique to you.

They will look like this (values redacted — use *your* generated ones):

```
helm repo add open-telemetry 'https://open-telemetry.github.io/opentelemetry-helm-charts' --force-update

kubectl create namespace opentelemetry-operator-system

kubectl create secret generic elastic-secret-otel \
  --namespace opentelemetry-operator-system \
  --from-literal=elastic_otlp_endpoint='<from-kibana>' \
  --from-literal=elastic_api_key='<from-kibana>'

helm upgrade --install opentelemetry-kube-stack open-telemetry/opentelemetry-kube-stack \
  --namespace opentelemetry-operator-system \
  --values '<values-url-from-kibana>' \
  --version '<version-from-kibana>' \
  --set '...onboarding_id settings from kibana...'
```

What this installs: the OpenTelemetry Operator (injects instrumentation into
annotated pods), a per-node **daemon collector** (receives app OTLP, tails container
logs, scrapes node/kubelet metrics), a **cluster-stats collector**, and a **gateway
collector** that authenticates with your API key and exports everything to Elastic.

Wait until all pods are ready (Ctrl-C to stop watching):

```bash
kubectl -n opentelemetry-operator-system get pods -w
```

## 6. Restart the apps so instrumentation gets injected

Instrumentation is injected at **pod creation** by the operator's webhook, so pods
created before the operator existed must be recreated:

```bash
kubectl -n nodejs-eshop-otel-demo rollout restart deployment frontend backend
```

Verify the injection happened (expect an `opentelemetry-auto-instrumentation-nodejs`
init container and `OTEL_*` env vars):

```bash
kubectl -n nodejs-eshop-otel-demo describe pod -l app=frontend
```

> If the init container is missing, the webhook likely wasn't ready yet when the pod
> was created (injection fails silently). Just run the rollout restart again.

## 7. Generate traffic

```bash
kubectl -n nodejs-eshop-otel-demo port-forward svc/frontend 18080:8080
```

In another terminal:

```bash
for i in $(seq 1 50); do curl -s localhost:18080/ > /dev/null; curl -s localhost:18080/checkout > /dev/null; done
```

Every `/` request produces one distributed trace across both services; `/checkout`
fails ~30% of the time by design so you also get error traces.

## 8. See it in Kibana

- **Applications → Service Inventory** — `frontend` and `backend` appear as services.
- **Traces / Service map** — one trace spans frontend + backend spans, correlated by
  the auto-propagated `traceparent` header.
- **Infrastructure / Kubernetes dashboards** — node and pod metrics, container logs.
- The onboarding page itself detects your incoming data (via the `onboarding.id`
  resource attribute the install command configured).

## Troubleshooting

| Symptom | Fix |
|---|---|
| `the path "k8s/..." does not exist` | You're not in the repo root — `cd` into the cloned `nodejs-eshop-otel-demo-k8s-kind` directory |
| Cluster misbehaving, apiserver unreachable | `kind delete cluster --name nodejs-eshop-otel-demo`, then recreate from step 3 |
| App pods `ErrImagePull` | Images weren't loaded into the node — rerun the `kind load docker-image ...` command |
| No init container in app pods | `kubectl -n nodejs-eshop-otel-demo rollout restart deployment frontend backend` (webhook wasn't ready the first time) |
| Collector export errors | `kubectl -n opentelemetry-operator-system logs deploy/opentelemetry-kube-stack-gateway-collector` — check endpoint/API key in the `elastic-secret-otel` secret |
| Using a **local** Elasticsearch on your Mac | Pods can't reach `localhost` — use `http://host.docker.internal:9200` as the endpoint in the secret |
| No data in Kibana | Generate traffic (step 7) and widen the time range; check the daemon collector logs |

## Teardown

```bash
kind delete cluster --name nodejs-eshop-otel-demo
```
