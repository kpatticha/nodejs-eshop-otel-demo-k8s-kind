# nodejs-eshop-otel-demo-k8s-kind: local Kubernetes + EDOT observability demo

Two Node.js services (`frontend` → `backend`) on a local kind cluster, auto-instrumented with
OpenTelemetry by the OTel Operator (zero code changes), exporting traces/metrics/logs
to Elastic via the EDOT collectors installed with the `opentelemetry-kube-stack`
Helm chart.

## Steps

**1. Set up remote Elasticsearch and Local Kibana
[REMOTE_ES_ELASTIC_AGENT_LOCAL_KIBANA.md](REMOTE_ES_ELASTIC_AGENT_LOCAL_KIBANA.md)**

**2. Run frontend and backend service on k8s kind cluster:
[RUN_DEMO_SERVICES.md](RUN_DEMO_SERVICES.md)**

**3. Optional — apply extra workload scenarios to shape the kubeletstats metrics:
[SCENARIOS.md](SCENARIOS.md)**

**4. Optional: Run demo services integrating with Elastic APM and Elastic Agent [repo](https://github.com/kpatticha/nodejs-eshop-ecs-demo-k8s-kind)** 
  - Using the two demos to report to the same Elasticsearch instance would allow us to have both schemas. 
 
## Layout

- `kind.yaml` — cluster config with a pinned Kubernetes node image
- `scripts/setup.sh` — create cluster + build/load images + deploy (idempotent)
- `scripts/traffic.sh` — port-forward the frontend and send demo traffic
- `scripts/scenarios.sh` — apply/remove the optional metric scenarios
- `scripts/churn.sh` — scale a deployment up and down to produce pod churn
- `scripts/kill-pod.sh` — delete a pod and let its controller replace it
- `services/frontend` — entry service (port 8080), calls the backend over HTTP
- `services/backend` — product API (port 8081), includes a deliberately flaky
  endpoint to produce error traces and a CPU-bound one to move utilization
- `services/loadgen` — steady traffic generator used by the `network` scenario
- `k8s/` — namespace + deployments/services, with the
  `instrumentation.opentelemetry.io/inject-nodejs` annotation already in place
- `k8s/scenarios/` — optional workloads, one per metric shape (see
  [SCENARIOS.md](SCENARIOS.md))

Neither service contains any OpenTelemetry code — instrumentation is injected at
pod creation by the operator.
