# nodejs-eshop-otel-demo-k8s-kind: local Kubernetes + EDOT observability demo

Two Node.js services (`frontend` → `backend`) on a local kind cluster, auto-instrumented with
OpenTelemetry by the OTel Operator (zero code changes), exporting traces/metrics/logs
to Elastic via the EDOT collectors installed with the `opentelemetry-kube-stack`
Helm chart.

**Start here → [RUN_DEMO_SERVICES.md](RUN_DEMO_SERVICES.md)** — five steps, ~10 minutes
(`./scripts/setup.sh` → Kibana onboarding flow → `./scripts/traffic.sh` → verify).
[MANUAL.md](MANUAL.md) is the same thing expanded into every individual
`kind` / `docker` / `kubectl` / `helm` command, for when you want to run them
yourself or debug a step.

**Developing against a remote cluster →
[REMOTE_ES_ELASTIC_AGENT_LOCAL_KIBANA.md](REMOTE_ES_ELASTIC_AGENT_LOCAL_KIBANA.md)**:
create an `oblt-cli` cross-cluster-search cluster, run Kibana locally against it,
and ingest this demo's data into it.

## Layout

- `kind.yaml` — cluster config with a pinned Kubernetes node image
- `scripts/setup.sh` — create cluster + build/load images + deploy (idempotent)
- `scripts/traffic.sh` — port-forward the frontend and send demo traffic
- `services/frontend` — entry service (port 8080), calls the backend over HTTP
- `services/backend` — product API (port 8081), includes a deliberately flaky
  endpoint to produce error traces
- `k8s/` — namespace + deployments/services, with the
  `instrumentation.opentelemetry.io/inject-nodejs` annotation already in place

Neither service contains any OpenTelemetry code — instrumentation is injected at
pod creation by the operator.
