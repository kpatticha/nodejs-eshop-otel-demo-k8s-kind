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
 
## Choosing where telemetry goes (local vs remote Elasticsearch)

`scripts/install-edot.sh` installs the EDOT collectors and points them at one of two profiles.
Each needs three values from the Kibana onboarding page
(`/app/observabilityOnboarding/kubernetes`): `elastic_endpoint`, `elastic_api_key`, and the
`onboarding.id`.

```bash
cp .env.edot.local.example .env.edot.local     # ES + Kibana on this Mac
cp .env.edot.remote.example .env.edot.remote   # remote cluster (oblt-cli, Cloud, ...)
# fill in the values, then:
./scripts/install-edot.sh local     # or: remote
./scripts/setup.sh                  # restart apps so instrumentation is injected
```

Re-run with the other profile to switch; the secret is replaced and the collectors restarted.
`localhost` endpoints are rewritten to `host.docker.internal` because collector pods can't see the Mac's
localhost. The `.env.edot.*` files are gitignored.

## Layout

- `kind.yaml` — cluster config with a pinned Kubernetes node image
- `scripts/setup.sh` — create cluster + build/load images + deploy (idempotent)
- `scripts/install-edot.sh` — install EDOT collectors against the `local` or `remote` profile
- `scripts/traffic.sh` — port-forward the frontend and send demo traffic
- `scripts/scenarios.sh` — apply/remove the optional metric scenarios
- `scripts/churn.sh` — scale a deployment up and down to produce pod churn
- `scripts/kill-pod.sh` — delete a pod and let its controller replace it
- `scripts/many-deployments.sh` — create/remove 10,000+ zero-replica deployments (SCENARIOS.md)
- `scripts/multus.sh` — install/remove Multus, for pods with a second interface
- `scripts/collector-interfaces.sh` — make kubeletstats report every pod interface
- `services/frontend` — entry service (port 8080), calls the backend over HTTP
- `services/backend` — product API (port 8081), includes a deliberately flaky
  endpoint to produce error traces and a CPU-bound one to move utilization
- `services/loadgen` — steady traffic generator used by the `network` and
  `pod-multi-interface` scenarios
- `k8s/` — namespace + deployments/services, with the
  `instrumentation.opentelemetry.io/inject-nodejs` annotation already in place
- `k8s/scenarios/` — optional workloads, one per metric shape (see
  [SCENARIOS.md](SCENARIOS.md))

Neither service contains any OpenTelemetry code — instrumentation is injected at
pod creation by the operator.
