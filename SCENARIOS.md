# Scenarios — shaping what lands in `metrics-kubeletstatsreceiver.otel-*`

The base demo ([RUN_DEMO_SERVICES.md](RUN_DEMO_SERVICES.md)) gives you two pods with
one container each. That is not enough to exercise a monitoring UI: every pod looks
the same, and half the kubeletstats fields are never populated.

These scenarios are extra workloads you apply on top. Each one exists to make a
specific shape of document appear, so you can check how it is ingested and rendered.
They are independent: apply one, some, or all.

## Prerequisites

The cluster and the EDOT collectors, from [RUN_DEMO_SERVICES.md](RUN_DEMO_SERVICES.md)
steps 3 and 4. The scenario script builds and loads any images it needs.

## Commands

```bash
# What is available
./scripts/scenarios.sh list

# Apply everything
./scripts/scenarios.sh apply

# Apply one, or a few
./scripts/scenarios.sh apply pod-with-limits
./scripts/scenarios.sh apply pod-with-limits network

# What is running right now
./scripts/scenarios.sh status

# Remove one, or a few
./scripts/scenarios.sh delete pod-multi-container
./scripts/scenarios.sh delete pod-with-limits pod-without-limits

# Remove all of them, leaving the base demo untouched
./scripts/scenarios.sh delete
```

Scenario names are the file names in [k8s/scenarios/](k8s/scenarios/) without the
`.yaml` suffix, so `ls k8s/scenarios` tells you the same thing as `list`. Applying is
idempotent and re-applying restarts the workload, which is how you pick up a rebuilt
image. Deleting removes only that scenario's own objects. The `frontend` and `backend`
deployments are never touched by this script.

To wipe everything including the base demo, delete the cluster instead:

```bash
kind delete cluster --name nodejs-eshop-otel-demo
```

## The scenarios

| Name | Shape it produces |
| --- | --- |
| `pod-with-limits` | CPU and memory, requests and limits, all set |
| `pod-without-limits` | No resources block at all |
| `pod-multi-container` | Two containers in one pod, app plus proxy sidecar |
| `network` | Steady, non-zero, asymmetric pod network counters |

### `pod-with-limits`

A fully specified workload. The kubelet only reports a utilization figure when it has
a denominator, so this is the only scenario that populates the limit and request
utilization fields at both container and pod level.

### `pod-without-limits`

The workload nobody sized. No requests, no limits. Usage metrics still arrive, but
every `*_limit_utilization` and `*_request_utilization` field is absent. That absence
is the thing worth testing: a chart bound to those fields has nothing to draw.

### `pod-multi-container`

An application container behind an nginx reverse proxy in the same pod, which is the
ambassador sidecar pattern. One pod name, two container names, two sets of container
documents. Both containers carry requests and limits, as a production pod normally
would.

Proxy-to-app traffic crosses the pod loopback interface, so it does **not** show up in
the pod network counters. Use `network` for those.

### `network`

A load generator service, the same role the upstream OpenTelemetry demo gives its own
load generator. It calls every other demo service once per second.

Every pod already emits `k8s.pod.network.io` and `k8s.pod.network.errors` with a
direction attribute, whether or not you apply this scenario. What this adds is
movement: counters that climb steadily and differ between the two directions, rather
than sitting still.

Apply it alongside the others. It is also what drives CPU into the limited pod, so
`pod-with-limits` shows utilization at a visible fraction of its limit rather than
flat zero.

## Verifying in Kibana

Give the receiver about a minute, which is its collection interval, then query in
Discover or ES|QL.

Field paths below assume OTel mapping mode. If a query returns nothing, run the first
one to see the real field names before assuming the scenario failed.

Two things to keep in mind when writing your own:

- **One document does not hold every metric.** The exporter writes a separate document
  per set of attributes, so a pod's network documents carry no CPU fields and vice
  versa. Testing a field for null tells you about that document, not about the pod.
  Aggregate per pod first.
- **Network counters are cumulative.** `k8s.pod.network.io` is a running total since
  pod start, not a per-interval figure. Summing it across documents adds up repeated
  readings of the same total. Take the latest value, or a rate, instead. The
  `TO_DOUBLE` casts below exist because counter-typed fields reject most aggregations
  directly.

**What is being reported at all**

```esql
FROM metrics-kubeletstatsreceiver.otel-*
| WHERE resource.attributes.k8s.namespace.name == "nodejs-eshop-otel-demo"
| KEEP resource.attributes.k8s.pod.name, resource.attributes.k8s.container.name
| LIMIT 20
```

**Pods with limits versus pods without**

Count the non-null readings per pod first, then classify. Classifying document by
document would put a limited pod in both buckets, because its network documents carry
no CPU fields.

```esql
FROM metrics-kubeletstatsreceiver.otel-*
| WHERE resource.attributes.k8s.namespace.name == "nodejs-eshop-otel-demo"
| STATS
    cpu_limit_readings = COUNT(k8s.container.cpu_limit_utilization),
    mem_limit_readings = COUNT(k8s.container.memory_limit_utilization)
  BY resource.attributes.k8s.pod.name
| EVAL has_limits = CASE(
    cpu_limit_readings > 0 OR mem_limit_readings > 0, "with limits",
    "without limits")
| SORT has_limits, resource.attributes.k8s.pod.name
```

`pod-with-limits` should appear as "with limits", `pod-without-limits` as "without
limits".

**Network, one row per direction**

```esql
FROM metrics-kubeletstatsreceiver.otel-*
| WHERE resource.attributes.k8s.namespace.name == "nodejs-eshop-otel-demo"
| EVAL network_direction = CASE(
    attributes.direction == "receive", "Network In",
    attributes.direction == "transmit", "Network Out",
    attributes.direction)
| WHERE network_direction IS NOT NULL
| STATS total_bytes = MAX(TO_DOUBLE(k8s.pod.network.io))
  BY network_direction, resource.attributes.k8s.pod.name
| SORT resource.attributes.k8s.pod.name, network_direction
```

Two rows per pod, and the two values should differ. The asymmetry also inverts by
role: the `network` pod receives far more than it sends, while the pods it calls send
far more than they receive. A view that mislabels the directions shows the same shape
for both.

**Pods with more than one container**

```esql
FROM metrics-kubeletstatsreceiver.otel-*
| WHERE resource.attributes.k8s.namespace.name == "nodejs-eshop-otel-demo"
  AND resource.attributes.k8s.container.name IS NOT NULL
| STATS containers = COUNT_DISTINCT(resource.attributes.k8s.container.name)
    BY resource.attributes.k8s.pod.name
| WHERE containers >= 2
```

`pod-multi-container` should be the row that comes back, with a count of two.

## Adding a scenario

Drop a manifest in [k8s/scenarios/](k8s/scenarios/). The script picks it up with no
changes, because it discovers scenarios by listing that directory. Two conventions
make that work:

1. The file name, the Deployment name, and the `app` label must all match, since the
   script waits on `deployment/<name>`.
2. Label the pod template with `scenario: <name>` so `status` and the `-l scenario`
   selector find it.

If the scenario needs an image that is neither already in the repo nor pullable from a
registry, add a case to `ensure_images_for` in [scripts/scenarios.sh](scripts/scenarios.sh).

## Sending extra traffic by hand

The traffic script can target any scenario service exposing port 8080:

```bash
TARGET=pod-multi-container ./scripts/traffic.sh 200
```

## Reading the load generator

Every thirty seconds it logs a cumulative line per target:

```bash
kubectl -n nodejs-eshop-otel-demo logs deploy/network --tail=2
```

A non-zero `failed` count is normal and does not mean something is broken. Two causes
are expected:

- **Startup.** The generator begins calling before the other pods are ready, so each
  target accumulates failures once and then stops. If `failed` is frozen while `ok`
  climbs between two log lines, everything is healthy.
- **`/checkout`.** That endpoint fails about thirty percent of the time by design, so
  its failure count keeps rising. This is what produces error traces.

A target whose `ok` count is not increasing is the real warning sign. Check that the
scenario is applied and its pod is ready:

```bash
./scripts/scenarios.sh status
```
