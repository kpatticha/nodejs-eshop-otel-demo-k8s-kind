#!/usr/bin/env bash
# Applies or removes the kubeletstats test scenarios in k8s/scenarios/.
# Requires the cluster from ./scripts/setup.sh.
#
# Usage:
#   ./scripts/scenarios.sh apply  [name...]   apply all scenarios, or only the named ones
#   ./scripts/scenarios.sh delete [name...]   remove all scenarios, or only the named ones
#   ./scripts/scenarios.sh list               show the available scenario names
#   ./scripts/scenarios.sh status             show the running scenario pods
#
# Scenario names are the file names in k8s/scenarios/ without the .yaml suffix.
# Each scenario is documented, with a verification query, in SCENARIOS.md.
set -euo pipefail

CLUSTER=nodejs-eshop-otel-demo
NAMESPACE=nodejs-eshop-otel-demo
TAG=${TAG:-1.0.0}
PROXY_IMAGE=nginx:1.27-alpine

cd "$(dirname "$0")/.."
SCENARIO_DIR=k8s/scenarios

for bin in docker kind kubectl; do
  command -v "$bin" >/dev/null || { echo "missing required command: $bin" >&2; exit 1; }
done

all_scenarios() {
  for f in "$SCENARIO_DIR"/*.yaml; do
    basename "$f" .yaml
  done
}

usage() {
  echo "Usage: $0 apply|delete|list|status [scenario...]" >&2
  echo "Available scenarios:" >&2
  all_scenarios | sed 's/^/  /' >&2
  exit 1
}

# Scenarios depend on images that plain `kubectl apply` cannot fetch inside
# kind, so make sure each one is present on the node before applying.
ensure_image_loadgen() {
  local image="$CLUSTER-loadgen:$TAG"
  if ! docker image inspect "$image" >/dev/null 2>&1; then
    echo "==> Building $image"
    docker build -t "$image" services/loadgen
  fi
  echo "==> Loading $image into the cluster"
  kind load docker-image "$image" --name "$CLUSTER"
}

# The proxy image comes from a registry rather than this repo. `kind load` chokes
# on multi-platform manifests from Docker's containerd image store, so pull it on
# the node instead. Non-fatal: the kubelet retries the pull on its own.
ensure_image_proxy() {
  echo "==> Pulling $PROXY_IMAGE onto the cluster nodes"
  for node in $(kind get nodes --name "$CLUSTER"); do
    docker exec "$node" crictl pull "$PROXY_IMAGE" >/dev/null 2>&1 \
      || echo "    warning: could not pre-pull on $node; the kubelet will retry" >&2
  done
}

ensure_images_for() {
  case "$1" in
    network) ensure_image_loadgen ;;
    pod-multi-container) ensure_image_proxy ;;
  esac
}

ACTION=${1:-}
shift || true

case "$ACTION" in
  list)
    all_scenarios
    exit 0
    ;;
  status)
    kubectl -n "$NAMESPACE" get pods -l scenario -o wide
    exit 0
    ;;
  apply|delete) ;;
  *) usage ;;
esac

if [ $# -eq 0 ]; then
  SCENARIOS=$(all_scenarios)
else
  SCENARIOS="$*"
fi

FILES=()
for name in $SCENARIOS; do
  file="$SCENARIO_DIR/$name.yaml"
  [ -f "$file" ] || { echo "unknown scenario '$name'" >&2; usage; }
  FILES+=("$file")
done

case "$ACTION" in
  apply)
    echo "==> Scenarios: $(echo "$SCENARIOS" | tr '\n' ' ')"
    for name in $SCENARIOS; do
      ensure_images_for "$name"
    done

    kubectl apply -f k8s/namespace.yaml
    for file in "${FILES[@]}"; do
      kubectl apply -f "$file"
    done

    # Pick up a freshly rebuilt image when the deployment already exists.
    for name in $SCENARIOS; do
      kubectl -n "$NAMESPACE" rollout restart "deployment/$name" >/dev/null
    done
    for name in $SCENARIOS; do
      kubectl -n "$NAMESPACE" rollout status "deployment/$name" --timeout=180s
    done

    echo
    kubectl -n "$NAMESPACE" get pods -l scenario
    echo
    echo "Metrics appear in metrics-kubeletstatsreceiver.otel-* within ~1 minute"
    echo "(the receiver's collection interval). Queries: SCENARIOS.md"
    ;;
  delete)
    echo "==> Deleting scenarios: $(echo "$SCENARIOS" | tr '\n' ' ')"
    for file in "${FILES[@]}"; do
      kubectl delete --ignore-not-found -f "$file"
    done
    ;;
esac
