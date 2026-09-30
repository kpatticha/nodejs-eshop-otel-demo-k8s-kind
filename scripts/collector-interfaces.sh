#!/usr/bin/env bash
# Turns per-interface pod network metrics on or off in the running EDOT
# collectors, by patching the OpenTelemetryCollector custom resource the
# opentelemetry-kube-stack chart created.
#
# Why this exists: kubeletstats reports only the pod's *default* network
# interface unless collect_all_network_interfaces.pod is set, so a multi-homed
# pod still produces a single attributes.interface value. The option was added
# in collector-contrib v0.125.0 (April 2025) and is off by default:
#   https://github.com/open-telemetry/opentelemetry-collector-contrib/pull/38737
#
# The chart is installed from a values URL that Kibana generates, so there is
# no values file in this repo to edit. Patching the live CR works whichever way
# the chart was installed; the operator rolls the collectors itself. A later
# `helm upgrade` of opentelemetry-kube-stack reverts it — just run this again.
#
# Usage:
#   ./scripts/collector-interfaces.sh enable    collect metrics for every pod interface
#   ./scripts/collector-interfaces.sh disable   back to the default interface only
#   ./scripts/collector-interfaces.sh status    show the current setting
#
# Env:
#   COLLECTOR_NS   namespace holding the collectors (default opentelemetry-operator-system)
set -euo pipefail

COLLECTOR_NS=${COLLECTOR_NS:-opentelemetry-operator-system}
CRD=opentelemetrycollectors.opentelemetry.io
OPTION=collect_all_network_interfaces

cd "$(dirname "$0")/.."

for bin in kubectl python3; do
  command -v "$bin" >/dev/null || { echo "missing required command: $bin" >&2; exit 1; }
done

kubectl get crd "$CRD" >/dev/null 2>&1 || {
  echo "no $CRD in this cluster — install the EDOT collectors first (MANUAL.md)" >&2
  exit 1
}

# One "name<TAB>receiver-key<TAB>mode<TAB>image<TAB>current-setting" line per
# collector that has a kubeletstats receiver. The receiver key is discovered
# rather than assumed: a config may name it kubeletstats, kubelet_stats, or
# kubeletstats/something.
collectors() {
  kubectl -n "$COLLECTOR_NS" get "$CRD" -o json | python3 -c '
import json, sys

data = json.load(sys.stdin)
for item in data.get("items", []):
    spec = item.get("spec", {})
    config = spec.get("config")
    if not isinstance(config, dict):
        # v1alpha1 kept spec.config as a YAML string. Report it so the caller
        # can say something useful instead of patching a path that is not there.
        if isinstance(config, str) and "kubeletstats" in config:
            print("\t".join([item["metadata"]["name"], "", "STRING_CONFIG", "", ""]))
        continue
    receivers = config.get("receivers") or {}
    for key, value in receivers.items():
        if key.split("/")[0] not in ("kubeletstats", "kubelet_stats"):
            continue
        current = ""
        if isinstance(value, dict):
            current = json.dumps(value.get("collect_all_network_interfaces", ""))
        print("\t".join([
            item["metadata"]["name"], key, spec.get("mode", ""),
            spec.get("image", ""), current,
        ]))
'
}

# JSON Pointer escaping: a receiver named kubeletstats/foo is one key, not two.
pointer() {
  printf '%s' "$1" | sed -e 's/~/~0/g' -e 's|/|~1|g'
}

# The option is younger than the receiver, so an old collector rejects it and
# crashloops on the new config. Only a plain upstream version tag can be
# checked; EDOT images carry a stack version instead, and every stack release
# since 9.0 is new enough.
warn_if_old() {
  local image=$1 minor
  minor=$(printf '%s' "$image" | sed -n 's/.*:v\{0,1\}0\.\([0-9]\{1,\}\)\..*/\1/p')
  [ -n "$minor" ] || return 0
  [ "$minor" -ge 125 ] || {
    echo "    warning: $image looks older than v0.125.0, which is where" >&2
    echo "    $OPTION was added. The collector will reject the config." >&2
  }
}

wait_for() {
  local name=$1 mode=$2 kind
  case "$mode" in
    daemonset|"") kind=daemonset ;;
    statefulset)  kind=statefulset ;;
    *)            kind=deployment ;;
  esac
  kubectl -n "$COLLECTOR_NS" rollout status "$kind/$name-collector" --timeout=180s || {
    echo "    the collector did not come back. Its config was rejected; check:" >&2
    echo "      kubectl -n $COLLECTOR_NS logs $kind/$name-collector --tail=30" >&2
    echo "    and undo with: $0 disable" >&2
    return 1
  }
}

ACTION=${1:-}
case "$ACTION" in
  enable|disable|status) ;;
  *) echo "Usage: $0 enable|disable|status" >&2; exit 1 ;;
esac

FOUND=0
while IFS=$'\t' read -r name key mode image current; do
  [ -n "${name:-}" ] || continue
  FOUND=1

  if [ "$mode" = "STRING_CONFIG" ]; then
    echo "$name: spec.config is a YAML string (v1alpha1 collector), which this" >&2
    echo "  script cannot patch safely. Edit it by hand and add, under the" >&2
    echo "  kubeletstats receiver:  $OPTION: {pod: true}" >&2
    echo "    kubectl -n $COLLECTOR_NS edit $CRD $name" >&2
    continue
  fi

  case "$ACTION" in
    status)
      echo "$name: receiver $key, $OPTION = ${current:-\"\"}"
      ;;
    enable)
      echo "==> $name: enabling $OPTION on receiver $key"
      warn_if_old "$image"
      kubectl -n "$COLLECTOR_NS" patch "$CRD" "$name" --type=json -p "$(cat <<JSON
[{"op": "add",
  "path": "/spec/config/receivers/$(pointer "$key")/$OPTION",
  "value": {"pod": true, "node": true}}]
JSON
)"
      wait_for "$name" "$mode"
      ;;
    disable)
      if [ -z "$current" ] || [ "$current" = '""' ]; then
        echo "==> $name: $OPTION is not set, nothing to do"
        continue
      fi
      echo "==> $name: removing $OPTION from receiver $key"
      kubectl -n "$COLLECTOR_NS" patch "$CRD" "$name" --type=json \
        -p "[{\"op\": \"remove\", \"path\": \"/spec/config/receivers/$(pointer "$key")/$OPTION\"}]"
      wait_for "$name" "$mode"
      ;;
  esac
done < <(collectors)

if [ "$FOUND" = 0 ]; then
  echo "no collector in $COLLECTOR_NS has a kubeletstats receiver." >&2
  echo "Collectors found:" >&2
  kubectl -n "$COLLECTOR_NS" get "$CRD" >&2
  exit 1
fi

case "$ACTION" in
  enable)
    echo
    echo "k8s.[pod|node].network.* now carry one series per interface. This raises"
    echo "cardinality, which is why it is off by default. A helm upgrade of"
    echo "opentelemetry-kube-stack reverts this; re-run to reapply."
    echo
    echo "Next: ./scripts/scenarios.sh apply pod-multi-interface"
    ;;
esac
