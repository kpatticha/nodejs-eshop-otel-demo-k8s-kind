#!/usr/bin/env bash
# Creates thousands of Deployments, to test how a UI and the ingest path cope
# with a cluster that has far more workloads than the demo normally has.
#
# Usage:
#   ./scripts/many-deployments.sh apply     create COUNT deployments
#   ./scripts/many-deployments.sh status    how many exist, and how many pods
#   ./scripts/many-deployments.sh delete    remove them all (deletes the namespace)
#
# Env:
#   COUNT     how many deployments (default 10050, i.e. just over 10,000)
#   REPLICAS  replicas per deployment (default 0)
#   BATCH     deployments per kubectl call (default 500)
#   PARALLEL  kubectl calls in flight (default 4)
#
# Why REPLICAS defaults to 0: a kind node runs at most 110 pods, so 10,000
# deployments with running pods cannot exist here. At 0 replicas they are still
# real Deployment objects, and the k8s cluster receiver still reports
# k8s.deployment.desired / .available for each one (metrics-k8sclusterreceiver.otel-*).
# What you get is thousands of deployment entities and no pods.
#
# Deliberately not part of scenarios.sh: `scenarios.sh apply` with no arguments
# applies every scenario, and nobody should get 10,000 objects by accident.
set -euo pipefail

NAMESPACE=many-deployments
COUNT=${COUNT:-10050}
REPLICAS=${REPLICAS:-0}
BATCH=${BATCH:-500}
PARALLEL=${PARALLEL:-4}
POD_LIMIT=100 # of the node's 110, leaving room for the demo and the collectors

command -v kubectl >/dev/null || { echo "missing required command: kubectl" >&2; exit 1; }

# Prints one batch of manifests: deployments FROM..TO inclusive. A real image
# the node does not have is fine at 0 replicas; with replicas it would need a pull.
manifests() {
  awk -v from="$1" -v to="$2" -v ns="$NAMESPACE" -v replicas="$REPLICAS" 'BEGIN {
    for (i = from; i <= to; i++) {
      name = sprintf("bulk-%05d", i)
      printf "apiVersion: apps/v1\nkind: Deployment\nmetadata:\n"
      printf "  name: %s\n  namespace: %s\n  labels:\n    app: %s\n    scenario: many-deployments\n", name, ns, name
      printf "spec:\n  replicas: %d\n  selector:\n    matchLabels:\n      app: %s\n", replicas, name
      printf "  template:\n    metadata:\n      labels:\n        app: %s\n        scenario: many-deployments\n", name
      printf "    spec:\n      containers:\n        - name: app\n          image: registry.k8s.io/pause:3.10\n"
      printf "          resources:\n            requests:\n              cpu: 1m\n              memory: 1Mi\n"
      printf "---\n"
    }
  }'
}

apply_batch() {
  local from=$1 to=$2
  manifests "$from" "$to" | kubectl apply -f - >/dev/null
  echo "    applied bulk-$(printf '%05d' "$from") .. bulk-$(printf '%05d' "$to")"
}

case "${1:-}" in
  apply)
    if [ $((COUNT * REPLICAS)) -gt "$POD_LIMIT" ]; then
      echo "COUNT=$COUNT x REPLICAS=$REPLICAS = $((COUNT * REPLICAS)) pods; a kind node runs at most 110." >&2
      echo "Use REPLICAS=0 (the default), or a smaller COUNT." >&2
      exit 1
    fi
    echo "==> Creating $COUNT deployments (replicas=$REPLICAS) in namespace $NAMESPACE"
    echo "    expect several minutes; the API server and the cluster-stats collector will be busy"
    kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

    # Export what the workers need, then fan the batches out.
    export -f manifests apply_batch
    export NAMESPACE REPLICAS
    for from in $(seq 1 "$BATCH" "$COUNT"); do
      to=$((from + BATCH - 1))
      [ "$to" -le "$COUNT" ] || to=$COUNT
      echo "$from $to"
    done | xargs -P "$PARALLEL" -L 1 bash -c 'apply_batch "$0" "$1"'

    echo
    "$0" status
    echo
    echo "k8s.deployment.* for all of them lands in metrics-k8sclusterreceiver.otel-*"
    echo "within a collection interval or two. Queries: SCENARIOS.md"
    ;;
  status)
    deployments=$(kubectl -n "$NAMESPACE" get deployments --no-headers 2>/dev/null | wc -l | tr -d ' ')
    pods=$(kubectl -n "$NAMESPACE" get pods --no-headers 2>/dev/null | wc -l | tr -d ' ')
    echo "$NAMESPACE: $deployments deployments, $pods pods"
    ;;
  delete)
    echo "==> Deleting namespace $NAMESPACE (this can take a few minutes for thousands of objects)"
    kubectl delete namespace "$NAMESPACE" --ignore-not-found --timeout=600s
    ;;
  *)
    echo "Usage: $0 apply|status|delete" >&2
    exit 1
    ;;
esac
