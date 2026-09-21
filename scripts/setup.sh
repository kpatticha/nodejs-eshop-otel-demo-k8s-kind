#!/usr/bin/env bash
# Creates the kind cluster and builds/deploys the demo services (runbook steps 3 & 4).
# Safe to re-run: reuses an existing cluster, rebuilds and redeploys the apps.
set -euo pipefail

CLUSTER=nodejs-eshop-otel-demo
NAMESPACE=nodejs-eshop-otel-demo
TAG=${TAG:-1.0.0}

cd "$(dirname "$0")/.."

for bin in docker kind kubectl; do
  command -v "$bin" >/dev/null || { echo "missing required command: $bin" >&2; exit 1; }
done

echo "==> Cluster"
if kind get clusters | grep -qx "$CLUSTER"; then
  echo "cluster '$CLUSTER' already exists, reusing it"
else
  kind create cluster --config kind.yaml --wait 120s
fi
kubectl config use-context "kind-$CLUSTER"
kubectl get nodes

echo "==> Build images"
docker build -t "$CLUSTER-backend:$TAG" services/backend
docker build -t "$CLUSTER-frontend:$TAG" services/frontend
kind load docker-image "$CLUSTER-backend:$TAG" "$CLUSTER-frontend:$TAG" --name "$CLUSTER"

echo "==> Deploy"
kubectl apply -f k8s/namespace.yaml -f k8s/backend.yaml -f k8s/frontend.yaml
# Pick up freshly loaded images when the deployments already exist.
kubectl -n "$NAMESPACE" rollout restart deployment frontend backend
kubectl -n "$NAMESPACE" rollout status deployment/backend --timeout=120s
kubectl -n "$NAMESPACE" rollout status deployment/frontend --timeout=120s

kubectl -n "$NAMESPACE" get pods
echo
echo "Done. Next: runbook step 5 (install EDOT from the Kibana onboarding page)."
