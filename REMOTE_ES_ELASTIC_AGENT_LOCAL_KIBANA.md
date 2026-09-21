# Runbook: remote CCS cluster + local Kibana + real ingested data

Goal: a realistic development setup where **Elasticsearch runs remotely** (with
cross-cluster search configured against `release-oblt`), **Kibana runs locally**
from your Kibana checkout, and **real OTel data** is ingested into the remote
cluster by the demo app in this repo.

```
        Remote (oblt-cli)                          Locally
 ┌──────────────────────────────┐        ┌──────────────────────────────┐
 │  Elasticsearch  ◀────────────┼────────┤  nodejs-eshop-otel-demo      │
 │       ▲  │                   │        │  (kind cluster + EDOT)       │
 │       │  ▼                   │        │                              │
 │  Elastic Agent               │        │  Kibana (pnpm start)         │
 └──────────────────────────────┘        └──────────────────────────────┘
              ▲                                        │
              └────────────────────────────────────────┘
                        local Kibana reads remote ES
```

Three phases:

1. [Create the remote cluster (with CCS)](#phase-1-create-the-remote-cluster-with-cross-cluster-search), ~10 min, mostly waiting
2. [Point your local Kibana at it](#phase-2-point-local-kibana-at-the-remote-cluster)
3. [Ingest data from this repo](#phase-3-ingest-data-from-this-repo)

## Prerequisites

- [`oblt-cli`](https://github.com/elastic/observability-test-environments) installed and logged in
- A local `elastic/kibana` checkout you can run with `pnpm start`
- Docker Desktop with **≥ 6 GB** memory, plus `kind`, `kubectl`, `helm`
  (`brew install kind kubectl helm`)

## Phase 1: Create the remote cluster with cross-cluster search

This creates an Elasticsearch cluster **without Kibana** (you'll run Kibana
locally) that has `release-oblt` configured as a remote cluster for CCS:

```bash
oblt-cli cluster create ccs \
  --remote-cluster release-oblt \
  --cluster-name-prefix my-local-kibana
```

Provisioning is asynchronous. **You get progress updates on Slack**, so wait for
the success message, which contains the generated `CLUSTER_NAME`
(something like `my-local-kibana-abc123`).

> Clusters are ephemeral. If yours expires or gets into a bad state, delete it and
> recreate it rather than debugging:
> `oblt-cli cluster destroy --cluster-name=<CLUSTER_NAME>`

## Phase 2: Point local Kibana at the remote cluster

### 2.1 Fetch the Kibana config

From your **Kibana checkout root**, with the `CLUSTER_NAME` from Slack:

```bash
oblt-cli cluster secrets kibana-config \
  --cluster-name=<CLUSTER_NAME> \
  --output-file ${PWD}/kibana.yml
```

### 2.2 Merge it into `config/kibana.dev.yml`

Copy the contents of the generated `kibana.yml` into your
`config/kibana.dev.yml`. It carries the `elasticsearch.hosts`, credentials, and
TLS settings for the remote cluster.

> **Remove the `remote_cluster:` prefix from any index patterns in the generated
> `kibana.yml`.** The file may contain patterns like `remote_cluster:logs-*` that
> scope queries to the CCS remote cluster only. Strip the `remote_cluster:` prefix
> so that data views cover the indices where your demo app ships data.
> Without this, you will see only data from the remote cluster and nothing from
> the `nodejs-eshop-otel-demo` app.

### 2.3 If login fails, enable basic auth

The generated config assumes Cloud SAML, which doesn't exist on this cluster. If
login fails with:

```
[ERROR][plugins.security.authentication] Authentication attempt failed:
security_exception: Cannot find any matching realm for
[SamlPrepareAuthenticationRequest{realmName=cloud-saml-kibana, ...}]
```

add this to `config/kibana.dev.yml`:

```yaml
xpack.security.authc.providers:
  basic.basic1:
    order: 0
```

### 2.4 Start Kibana

```bash
pnpm start
```

Open http://localhost:5601. The credentials are shown on the login page.

Sanity-check CCS under **Stack Management → Remote Clusters**, where you should
see `release-oblt` connected.

## Phase 3: Ingest data from this repo

Your local Kibana is now talking to the remote Elasticsearch, so the standard
onboarding flow works end to end: the commands Kibana generates will point the
EDOT collectors at the **remote** cluster.

Follow [RUN_DEMO_SERVICES.md](RUN_DEMO_SERVICES.md) in full. In short:

```bash
# 1. local kind cluster
kind create cluster --config kind.yaml --wait 120s

# 2. build + load + deploy the demo services
docker build -t nodejs-eshop-otel-demo-backend:1.0.0 services/backend
docker build -t nodejs-eshop-otel-demo-frontend:1.0.0 services/frontend
kind load docker-image nodejs-eshop-otel-demo-backend:1.0.0 nodejs-eshop-otel-demo-frontend:1.0.0 \
  --name nodejs-eshop-otel-demo
kubectl apply -f k8s/namespace.yaml -f k8s/backend.yaml -f k8s/frontend.yaml
```

Then, in your **local** Kibana, go to **Observability → Add data → Kubernetes →
OpenTelemetry: Full Observability** and run the generated `helm` / `kubectl`
commands ([RUN_DEMO_SERVICES.md §5](RUN_DEMO_SERVICES.md)). They embed your remote cluster's
OTLP endpoint and a freshly minted API key.

Restart the apps so instrumentation is injected, then generate traffic:

```bash
kubectl rollout restart deployment frontend -n nodejs-eshop-otel-demo
kubectl rollout restart deployment backend -n nodejs-eshop-otel-demo
kubectl -n nodejs-eshop-otel-demo port-forward svc/frontend 18080:8080
# in another terminal
for i in $(seq 1 50); do
  curl -s localhost:18080/ > /dev/null
  curl -s localhost:18080/checkout > /dev/null
done
```

Data lands in the remote Elasticsearch and shows up in your local Kibana under
**Applications → Service Inventory** and the Kubernetes dashboards.

## Teardown

```bash
kind delete cluster --name nodejs-eshop-otel-demo
oblt-cli cluster destroy --cluster-name=<CLUSTER_NAME>
```

## Troubleshooting

| Symptom                                                        | Fix                                                                                                                                               |
| -------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Cannot find any matching realm for [...cloud-saml-kibana...]` | Add the `xpack.security.authc.providers` block from [2.3](#23-if-login-fails-enable-basic-auth)                                                   |
| Kibana won't start: version mismatch with ES                   | Your checkout's branch must match the remote cluster's stack version. Check out the matching branch, or recreate the cluster on the right version |
| No Slack message after `cluster create`                        | Check `oblt-cli cluster list`; provisioning can take several minutes                                                                              |
| `release-oblt` not listed in Remote Clusters                   | The cluster wasn't created with `--remote-cluster release-oblt`, so recreate it                                                                   |
| No data in Kibana after ingest                                 | See the troubleshooting table in [RUN_DEMO_SERVICES.md](RUN_DEMO_SERVICES.md). Usually missing traffic, or a stale API key in the `elastic-secret-otel` secret  |
| Data shows only from the remote cluster, not from the demo app | The generated `kibana.yml` has index patterns prefixed with `remote_cluster:` (e.g. `remote_cluster:logs-*`). Remove the prefix so data views cover the indices your demo app writes to |
| Collector export errors                                        | `kubectl -n opentelemetry-operator-system logs deploy/opentelemetry-kube-stack-gateway-collector`                                                 |
