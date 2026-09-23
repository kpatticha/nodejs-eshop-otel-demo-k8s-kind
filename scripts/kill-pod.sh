#!/usr/bin/env bash
# Deletes running pods so their replacements come back under a new name. One
# pod name stops reporting and a new one starts: the "disappearing tile" case.
#
# Usage: ./scripts/kill-pod.sh [target] [count]    (default pod-churn, 1)
# Env:
#   GRACE  termination grace period in seconds (default: the pod's own)
#
# `target` is a scenario name (matched on the `scenario` label, so it finds
# pods in any namespace) or any workload's `app` label, which is how the base
# demo's `frontend` and `backend` can be killed too:
#
#   ./scripts/kill-pod.sh pod-churn 2
#   ./scripts/kill-pod.sh frontend
#
# Only pods backed by a controller come back. Deleting the pod of a Deployment
# gets you a new random name; deleting a StatefulSet's pod gets the *same* name
# back, which is its own useful case.
set -euo pipefail

TARGET=${1:-pod-churn}
COUNT=${2:-1}
GRACE=${GRACE:-}

command -v kubectl >/dev/null || { echo "missing required command: kubectl" >&2; exit 1; }

# "namespace name" lines for the pods matching a label selector.
pods_matching() {
  kubectl get pods --all-namespaces -l "$1" \
    --field-selector=status.phase=Running \
    -o jsonpath='{range .items[*]}{.metadata.namespace} {.metadata.name}{"\n"}{end}'
}

# `app` first because it is the narrower of the two: a scenario can own several
# workloads (pod-churn has a Deployment and a CronJob) and killing a pod picked
# arbitrarily from among them is not useful. Fall back to the scenario label for
# a scenario whose workload is not named after it.
SELECTOR="app=$TARGET"
PODS=$(pods_matching "$SELECTOR")
if [ -z "$PODS" ]; then
  SELECTOR="scenario=$TARGET"
  PODS=$(pods_matching "$SELECTOR")
fi

if [ -z "$PODS" ]; then
  echo "no running pods match app=$TARGET or scenario=$TARGET" >&2
  echo "what is running: ./scripts/scenarios.sh status" >&2
  exit 1
fi

echo "==> Running pods for $TARGET ($SELECTOR)"
echo "$PODS" | sed 's/^/    /'

VICTIMS=$(echo "$PODS" | head -n "$COUNT")
VICTIM_COUNT=$(echo "$VICTIMS" | wc -l | tr -d ' ')
if [ "$VICTIM_COUNT" -lt "$COUNT" ]; then
  echo "    (only $VICTIM_COUNT pod(s) to delete, asked for $COUNT)"
fi

echo
while read -r ns pod; do
  [ -n "${pod:-}" ] || continue
  echo "==> Deleting $ns/$pod"
  if [ -n "$GRACE" ]; then
    kubectl -n "$ns" delete pod "$pod" --grace-period="$GRACE"
  else
    kubectl -n "$ns" delete pod "$pod"
  fi
done <<< "$VICTIMS"

echo
echo "==> Pods for $TARGET now"
kubectl get pods --all-namespaces -l "$SELECTOR" -o wide

cat <<'EOF'

The deleted pod names stop appearing in metrics-kubeletstatsreceiver.otel-*
from the next collection interval (~1 minute); the replacement names start
appearing in the one after that. Queries: SCENARIOS.md
EOF
