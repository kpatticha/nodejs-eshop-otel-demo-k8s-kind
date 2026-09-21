#!/usr/bin/env bash
# Scales a deployment up and down repeatedly, to produce pod churn and move the
# desired/available replica counts.
#
# Usage: ./scripts/churn.sh [cycles]        (default 5 cycles)
# Env:
#   DEPLOYMENT  which deployment to scale (default pod-churn)
#   MIN         replica count at the bottom of each cycle (default 1)
#   MAX         replica count at the top of each cycle (default 4)
#   HOLD        seconds to stay at each level (default 45)
#
# The original replica count is restored when the script exits, including on
# Ctrl-C, so this leaves the cluster as it found it.
set -euo pipefail

NAMESPACE=nodejs-eshop-otel-demo
DEPLOYMENT=${DEPLOYMENT:-pod-churn}
MIN=${MIN:-1}
MAX=${MAX:-4}
HOLD=${HOLD:-45}
CYCLES=${1:-5}

command -v kubectl >/dev/null || { echo "missing required command: kubectl" >&2; exit 1; }

if ! kubectl -n "$NAMESPACE" get "deployment/$DEPLOYMENT" >/dev/null 2>&1; then
  echo "deployment '$DEPLOYMENT' not found in namespace '$NAMESPACE'" >&2
  echo "apply the scenario first: ./scripts/scenarios.sh apply pod-churn" >&2
  exit 1
fi

ORIGINAL=$(kubectl -n "$NAMESPACE" get "deployment/$DEPLOYMENT" -o jsonpath='{.spec.replicas}')
echo "==> $DEPLOYMENT is at $ORIGINAL replica(s); will restore that on exit"

restore() {
  echo
  echo "==> Restoring $DEPLOYMENT to $ORIGINAL replica(s)"
  kubectl -n "$NAMESPACE" scale "deployment/$DEPLOYMENT" --replicas="$ORIGINAL" >/dev/null 2>&1 || true
}
trap restore EXIT

scale_to() {
  local replicas=$1
  echo "==> Scaling $DEPLOYMENT to $replicas, holding ${HOLD}s"
  kubectl -n "$NAMESPACE" scale "deployment/$DEPLOYMENT" --replicas="$replicas" >/dev/null
  # Wait for the change to actually land before starting the hold, so the hold
  # is time spent *at* the level rather than time spent getting there.
  kubectl -n "$NAMESPACE" rollout status "deployment/$DEPLOYMENT" --timeout=120s >/dev/null
  kubectl -n "$NAMESPACE" get pods -l "app=$DEPLOYMENT" --no-headers | wc -l | xargs echo "    pods now:"
  sleep "$HOLD"
}

for cycle in $(seq 1 "$CYCLES"); do
  echo
  echo "===== cycle $cycle of $CYCLES ====="
  scale_to "$MAX"
  scale_to "$MIN"
done

echo
echo "Done. Replica counts land in metrics-k8sclusterreceiver.otel-*;"
echo "the pods themselves land in metrics-kubeletstatsreceiver.otel-*."
echo "Queries: SCENARIOS.md"
