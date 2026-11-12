#!/usr/bin/env bash
# Installs EDOT (opentelemetry-kube-stack) — the commands the Kibana Kubernetes
# onboarding page generates, parameterised so no credentials live in the repo.
# Safe to re-run: the secret is re-applied and the chart is upgraded in place.
#
# Usage:
#   ./scripts/install-edot.sh local     # Elasticsearch/Kibana running on this Mac
#   ./scripts/install-edot.sh remote    # remote cluster (oblt-cli, Elastic Cloud, ...)
#   ./scripts/install-edot.sh           # legacy: reads ./.env.edot
#
# Config comes from the environment, or from ./.env.edot.<profile> (gitignored;
# copy the matching .example file). Each profile needs:
#   ELASTIC_ENDPOINT   Elasticsearch URL (localhost is rewritten for in-cluster use)
#   ELASTIC_API_KEY    base64 API key from the Kibana onboarding page
#   ONBOARDING_ID      onboarding id from the same page (differs per Kibana/cluster)
# Re-run with the other profile to switch where the data goes.
set -euo pipefail

PROFILE=${1:-}
case "$PROFILE" in
  ""|local|remote) ;;
  *) echo "usage: $0 [local|remote]" >&2; exit 1 ;;
esac

NAMESPACE=opentelemetry-operator-system
CHART_VERSION=${CHART_VERSION:-0.16.0}
EDOT_VERSION=${EDOT_VERSION:-v9.5.6}
VALUES_URL="https://raw.githubusercontent.com/elastic/elastic-agent/refs/tags/${EDOT_VERSION}/deploy/helm/edot-collector/kube-stack/values.yaml"

cd "$(dirname "$0")/.."

ENV_FILE=.env.edot${PROFILE:+.$PROFILE}
if [ -f "$ENV_FILE" ]; then
  . "./$ENV_FILE"
elif [ -n "$PROFILE" ]; then
  echo "missing $ENV_FILE — copy $ENV_FILE.example to $ENV_FILE and fill it in" >&2
  exit 1
fi

for bin in kubectl helm; do
  command -v "$bin" >/dev/null || { echo "missing required command: $bin" >&2; exit 1; }
done

: "${ELASTIC_ENDPOINT:?set ELASTIC_ENDPOINT (see scripts/install-edot.sh header)}"
: "${ELASTIC_API_KEY:?set ELASTIC_API_KEY (see scripts/install-edot.sh header)}"
: "${ONBOARDING_ID:?set ONBOARDING_ID (see scripts/install-edot.sh header)}"

# The onboarding page prints the endpoint as your browser sees it. Collector pods
# have their own localhost, so an Elasticsearch running on the Mac is only
# reachable at host.docker.internal.
case "$ELASTIC_ENDPOINT" in
  *//localhost:*|*//127.0.0.1:*)
    rewritten=$(echo "$ELASTIC_ENDPOINT" | sed -E 's#//(localhost|127\.0\.0\.1):#//host.docker.internal:#')
    echo "==> Endpoint $ELASTIC_ENDPOINT is not reachable from inside the cluster"
    echo "    using $rewritten instead"
    ELASTIC_ENDPOINT=$rewritten
    ;;
esac

echo "==> Profile: ${PROFILE:-default} ($ENV_FILE)"

echo "==> Namespace"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

echo "==> Secret elastic-secret-otel ($ELASTIC_ENDPOINT)"
kubectl create secret generic elastic-secret-otel \
  --namespace "$NAMESPACE" \
  --from-literal=elastic_endpoint="$ELASTIC_ENDPOINT" \
  --from-literal=elastic_api_key="$ELASTIC_API_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> Helm repo"
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts >/dev/null
helm repo update open-telemetry >/dev/null

# max_recv_msg_size_mib: the cluster-stats collector sends every k8s.* metric in one
# gRPC message. With thousands of workloads (scenario many-deployments) that exceeds
# the gateway's 4 MiB default, and the whole batch is dropped as ResourceExhausted.
echo "==> helm upgrade --install opentelemetry-kube-stack"
helm upgrade --install opentelemetry-kube-stack open-telemetry/opentelemetry-kube-stack \
  --namespace "$NAMESPACE" \
  --values "$VALUES_URL" \
  --version "$CHART_VERSION" \
  --set 'collectors.daemon.config.processors.resource\/onboarding_id.attributes[0].action=upsert' \
  --set 'collectors.daemon.config.processors.resource\/onboarding_id.attributes[0].key=onboarding.id' \
  --set "collectors.daemon.config.processors.resource\\/onboarding_id.attributes[0].value=$ONBOARDING_ID" \
  --set 'collectors.daemon.config.service.pipelines.logs\/node.processors[9]=resource/onboarding_id' \
  --set 'collectors.daemon.config.service.pipelines.metrics\/node\/otel.processors[9]=resource/onboarding_id' \
  --set 'collectors.daemon.config.processors.resourcedetection\/system.system.resource_attributes.host\.ip.enabled=true' \
  --set 'collectors.gateway.config.receivers.otlp.protocols.grpc.max_recv_msg_size_mib=64'

# The collectors read the endpoint/API key as env vars via secretKeyRef, so a
# changed secret only takes effect once their pods restart. Helm won't do it when
# the chart values are unchanged.
echo "==> Restart collectors to pick up the secret"
kubectl -n "$NAMESPACE" rollout restart \
  deployment/opentelemetry-kube-stack-gateway-collector \
  deployment/opentelemetry-kube-stack-cluster-stats-collector \
  daemonset/opentelemetry-kube-stack-daemon-collector
kubectl -n "$NAMESPACE" rollout status deployment/opentelemetry-kube-stack-gateway-collector --timeout=180s

echo
kubectl -n "$NAMESPACE" get pods
echo
echo "Watch them come up:  kubectl -n $NAMESPACE get pods -w"
echo "Then re-run ./scripts/setup.sh so the app pods get instrumentation injected."
