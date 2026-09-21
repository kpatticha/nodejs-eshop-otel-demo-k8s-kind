#!/usr/bin/env bash
# Generates demo traffic against the frontend (runbook step 7).
# Handles the port-forward itself, so you only need one terminal.
# Usage: ./scripts/traffic.sh [requests]   (default 50)
set -euo pipefail

NAMESPACE=nodejs-eshop-otel-demo
PORT=${PORT:-18080}
REQUESTS=${1:-50}

command -v kubectl >/dev/null || { echo "missing required command: kubectl" >&2; exit 1; }

kubectl -n "$NAMESPACE" rollout status deployment/frontend --timeout=120s

kubectl -n "$NAMESPACE" port-forward "svc/frontend" "$PORT:8080" >/dev/null 2>&1 &
PF_PID=$!
trap 'kill "$PF_PID" 2>/dev/null || true' EXIT

# Wait for the tunnel to accept connections before hammering it.
for _ in $(seq 1 30); do
  if curl -sf -o /dev/null "localhost:$PORT/"; then break; fi
  sleep 1
done
curl -sf -o /dev/null "localhost:$PORT/" || { echo "port-forward on :$PORT never became ready" >&2; exit 1; }

echo "==> Sending $REQUESTS request pairs to localhost:$PORT"
for _ in $(seq 1 "$REQUESTS"); do
  curl -s -o /dev/null "localhost:$PORT/"
  curl -s -o /dev/null "localhost:$PORT/checkout"
done

echo "Done. Each / request is one distributed trace; /checkout fails ~30% by design."
