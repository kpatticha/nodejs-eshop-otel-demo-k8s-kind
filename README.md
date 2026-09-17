# nodejs-eshop-otel-demo-k8s-kind
 — local Kubernetes + EDOT observability demo

Two Node.js services (`frontend` → `backend`) on a local kind cluster, auto-instrumented with
OpenTelemetry by the OTel Operator (zero code changes), exporting traces/metrics/logs
to Elastic via the EDOT collectors installed with the `opentelemetry-kube-stack`
Helm chart.

**Start here → [ONBOARDING.md](ONBOARDING.md)** — the step-by-step runbook
(kind → deploy apps → Kibana onboarding flow → verify). No custom scripts;
every step is a plain `kind` / `docker` / `kubectl` / `helm` command.

## Layout

- `kind.yaml` — cluster config with a pinned Kubernetes node image
- `services/frontend` — entry service (port 8080), calls the backend over HTTP
- `services/backend` — product API (port 8081), includes a deliberately flaky
  endpoint to produce error traces
- `k8s/` — namespace + deployments/services, with the
  `instrumentation.opentelemetry.io/inject-nodejs` annotation already in place

Neither service contains any OpenTelemetry code — instrumentation is injected at
pod creation by the operator.
