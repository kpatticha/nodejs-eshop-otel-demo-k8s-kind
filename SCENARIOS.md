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

Most scenarios are interesting the moment they are running. Two are about *change*
over time, so they come with scripts that cause it:

```bash
# Scale a deployment up and down repeatedly (pod-churn)
./scripts/churn.sh

# Delete a pod and let its controller replace it
./scripts/kill-pod.sh pod-churn
```

One scenario, `duplicate-pod-name`, creates a second namespace
(`nodejs-eshop-otel-demo-2`) and removes it again on delete. That is why `status` and
the summary after `apply` list pods across all namespaces.

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
| `pod-churn` | Pod names that appear and disappear, and moving replica counts |
| `pod-crashloop` | A pod in CrashLoopBackOff: rising restarts, gappy series |
| `duplicate-pod-name` | The same pod name in two different namespaces |

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

### `pod-churn`

Pods that come and go, which is what a static demo never produces. Two sources of
churn, because they exercise different things.

The `pod-churn` Deployment is a normal service, there to be scaled. [scripts/churn.sh](scripts/churn.sh)
scales it up and down on a timer, which moves the desired and available replica counts
in `metrics-k8sclusterreceiver.otel-*` and starts and stops whole sets of kubeletstats
series at once:

```bash
# 5 cycles of 1 → 4 → 1 replicas, 45s at each level
./scripts/churn.sh

# Slower, wider swings, and only two cycles
MIN=1 MAX=8 HOLD=90 ./scripts/churn.sh 2
```

It restores the original replica count when it exits, including on Ctrl-C.

The `pod-churn-reindex` CronJob is the hands-off half. It runs every minute, works for
40 seconds, then completes. Every run is a new pod name that appears, reports for under
a minute, and disappears, with no terminal attached. This is the one to leave running
while you look at something else.

For a single disappearance rather than a stream of them, delete a pod and let its
controller replace it:

```bash
./scripts/kill-pod.sh pod-churn        # one pod
./scripts/kill-pod.sh pod-churn 2      # two
./scripts/kill-pod.sh frontend         # the base demo works too
```

A Deployment's replacement pod comes back under a new random name, so one tile goes
stale and a different one appears. A StatefulSet's replacement comes back under the
*same* name, which is the opposite case and worth comparing: the tile should recover
rather than be replaced. `duplicate-pod-name` is the StatefulSet to try that on.

### `pod-crashloop`

A container that runs for 45 seconds, exits non-zero, and gets restarted. The kubelet
doubles the backoff each time (10s, 20s, 40s, and so on up to a 5 minute cap), so the
pod settles into `CrashLoopBackOff` and stays there. It has no readiness probe, so it
never becomes ready — `scenarios.sh apply` knows not to wait for it.

Two shapes come out of this. In `metrics-k8sclusterreceiver.otel-*`, a restart count
that climbs and a pod that is Running but not Ready. In
`metrics-kubeletstatsreceiver.otel-*`, **gaps**: while the pod sits in the backoff
sleep there is no running container, so the `k8s.container.*` series stop and resume
later, while the `k8s.pod.*` series continue throughout. A chart over the container
series has to draw that as a gap rather than a zero, and the gaps get longer as the
backoff grows.

### `duplicate-pod-name`

The same pod name in two namespaces. This is the scenario that catches anything keyed
on `k8s.pod.name` alone — a pod is identified by namespace *and* name, and a query or a
UI that forgets the namespace merges two unrelated workloads into one.

A Deployment cannot produce this, because its pod names carry a random suffix, so both
copies are StatefulSets: pod `duplicate-pod-name-0` in `nodejs-eshop-otel-demo` and pod
`duplicate-pod-name-0` in `nodejs-eshop-otel-demo-2`. The two are sized differently on
purpose (128Mi against 512Mi memory limit, 200m against 600m CPU) and the `network`
load generator calls them with different amounts of work. Anything that conflates them
produces numbers that are visibly wrong rather than plausibly wrong.

This is also the only scenario that puts workloads outside the demo namespace, so it
doubles as a check that the collectors are not namespace scoped. It creates
`nodejs-eshop-otel-demo-2` on apply and deletes it again on delete.

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

**Pod names that came and went** (`pod-churn`, `kill-pod.sh`)

```esql
FROM metrics-kubeletstatsreceiver.otel-*
| WHERE resource.attributes.k8s.namespace.name == "nodejs-eshop-otel-demo"
| STATS first_seen = MIN(@timestamp), last_seen = MAX(@timestamp)
    BY resource.attributes.k8s.pod.name
| EVAL gone_for = DATE_DIFF("minutes", last_seen, NOW())
| SORT last_seen DESC
```

Long-lived pods have an old `first_seen` and a `gone_for` near zero. Churned pods are
the rows where both ends sit in the past: the `pod-churn-reindex` jobs, the replicas
that `churn.sh` scaled away, and anything `kill-pod.sh` deleted. If every row has a
`gone_for` near zero, no churn has happened yet.

**Restarts and readiness** (`pod-crashloop`)

```esql
FROM metrics-k8sclusterreceiver.otel-*
| WHERE resource.attributes.k8s.namespace.name == "nodejs-eshop-otel-demo"
  AND k8s.container.restarts IS NOT NULL
| STATS restarts = MAX(TO_DOUBLE(k8s.container.restarts))
    BY resource.attributes.k8s.pod.name
| SORT restarts DESC
```

`pod-crashloop`'s pod should be at the top with a count that keeps climbing between
runs of the query; everything else should sit at zero. Note the different index —
restart counts come from the cluster-stats collector, not from kubeletstats.

**The gaps in the crashing pod's container series** (`pod-crashloop`)

```esql
FROM metrics-kubeletstatsreceiver.otel-*
| WHERE resource.attributes.k8s.pod.name LIKE "pod-crashloop-*"
| EVAL level = CASE(
    resource.attributes.k8s.container.name IS NOT NULL, "container", "pod")
| STATS docs = COUNT(*) BY level, bucket = BUCKET(@timestamp, 1 minute)
| SORT bucket ASC, level ASC
```

The `pod` rows should be continuous, one bucket after another. The `container` rows
should be missing from some buckets entirely, and increasingly so as the backoff
grows. That difference is the thing to render as a gap.

**The same pod name in two namespaces** (`duplicate-pod-name`)

```esql
FROM metrics-kubeletstatsreceiver.otel-*
| WHERE resource.attributes.k8s.pod.name == "duplicate-pod-name-0"
| STATS namespaces = COUNT_DISTINCT(resource.attributes.k8s.namespace.name),
        peak_utilization = MAX(k8s.container.memory_limit_utilization)
    BY resource.attributes.k8s.namespace.name
```

Two rows, one per namespace, each with `namespaces = 1`, and two clearly different
utilization figures for what is nominally the same pod name. Drop the `BY` clause and
the single row that comes back reports `namespaces = 2` — that is the merge to watch
out for, and any view showing one tile for `duplicate-pod-name-0` is making it.

## Adding a scenario

Drop a manifest in [k8s/scenarios/](k8s/scenarios/). The script picks it up with no
changes, because it discovers scenarios by listing that directory. Three conventions
make that work:

1. Label the workload **and** its pod template with `scenario: <name>`, matching the
   file name. That label is how the script finds what to restart, wait on, and show
   in `status`, so it works for Deployments and StatefulSets, for a scenario that owns
   several workloads, and for workloads in another namespace.
2. Give the pod template an `app: <name>` label and select on it, as every existing
   scenario does, so [scripts/kill-pod.sh](scripts/kill-pod.sh) and `kubectl logs -l`
   have something to target.
3. If the workload is not supposed to become ready, annotate it with
   `scenario-no-wait: "true"` — otherwise `apply` waits for a rollout that will never
   finish. `pod-crashloop` is the example.

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
