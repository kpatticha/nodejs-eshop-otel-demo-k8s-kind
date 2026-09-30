#!/usr/bin/env bash
# Installs or removes Multus CNI, which is what lets a pod have a second
# network interface. Only the `pod-multi-interface` scenario needs it, and
# ./scripts/scenarios.sh installs it for you before applying that scenario.
#
# Multus runs as a meta-plugin: it takes over /etc/cni/net.d, keeps delegating
# the pod's primary interface to kindnet, and adds whatever extra networks a
# pod asks for with the k8s.v1.cni.cncf.io/networks annotation. Pods that do
# not carry that annotation are unaffected.
#
# It also installs the `bridge` and `static` CNI plugins on the nodes. The kind
# node image ships only host-local, loopback, portmap and ptp, and a secondary
# network needs a plugin that can make one.
#
# Usage:
#   ./scripts/multus.sh install   install Multus and wait for it (idempotent)
#   ./scripts/multus.sh delete    remove Multus again
#   ./scripts/multus.sh status    show the daemonset and any attached networks
#
# Env:
#   MULTUS_VERSION   multus-cni release tag to install (default v4.1.0)
#   CNI_VERSION      containernetworking/plugins release tag (default v1.6.2)
set -euo pipefail

CLUSTER=nodejs-eshop-otel-demo
NAMESPACE=kube-system
MULTUS_VERSION=${MULTUS_VERSION:-v4.1.0}
CNI_VERSION=${CNI_VERSION:-v1.6.2}
CNI_PLUGINS="bridge static"
MANIFEST="https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/$MULTUS_VERSION/deployments/multus-daemonset.yml"
CRD=network-attachment-definitions.k8s.cni.cncf.io
DAEMONSET=kube-multus-ds

cd "$(dirname "$0")/.."

for bin in kubectl docker kind curl tar; do
  command -v "$bin" >/dev/null || { echo "missing required command: $bin" >&2; exit 1; }
done

installed() {
  kubectl get crd "$CRD" >/dev/null 2>&1
}

# A NetworkAttachmentDefinition is only as good as the plugin binary it names,
# and the kind node image ships a minimal set (host-local, loopback, portmap,
# ptp). Fetch the missing ones from the upstream release and drop them on every
# node. Idempotent: does nothing once they are there.
ensure_cni_plugins() {
  local node arch missing plugin tmp
  for node in $(kind get nodes --name "$CLUSTER"); do
    missing=""
    for plugin in $CNI_PLUGINS; do
      docker exec "$node" test -x "/opt/cni/bin/$plugin" 2>/dev/null || missing="$missing $plugin"
    done
    [ -n "$missing" ] || continue

    case "$(docker exec "$node" uname -m)" in
      aarch64) arch=arm64 ;;
      x86_64)  arch=amd64 ;;
      *) echo "unsupported node architecture on $node" >&2; exit 1 ;;
    esac

    echo "==> Installing CNI plugins$missing on $node ($arch)"
    tmp=$(mktemp -d)
    # shellcheck disable=SC2046 # the plugin list is a deliberate word split
    curl -fsSL "https://github.com/containernetworking/plugins/releases/download/$CNI_VERSION/cni-plugins-linux-$arch-$CNI_VERSION.tgz" \
      | tar -xz -C "$tmp" $(for plugin in $missing; do echo "./$plugin"; done)
    for plugin in $missing; do
      docker cp "$tmp/$plugin" "$node:/opt/cni/bin/$plugin"
      docker exec "$node" chmod 0755 "/opt/cni/bin/$plugin"
    done
    rm -rf "$tmp"
  done
}

ACTION=${1:-}

case "$ACTION" in
  install)
    ensure_cni_plugins

    if installed; then
      echo "==> Multus is already installed ($CRD exists)"
    else
      echo "==> Installing Multus $MULTUS_VERSION"
      kubectl apply -f "$MANIFEST"
    fi

    echo "==> Waiting for the Multus daemonset"
    kubectl -n "$NAMESPACE" rollout status "daemonset/$DAEMONSET" --timeout=180s

    echo
    echo "Multus is ready. Pods still get their primary interface from kindnet;"
    echo "only pods annotated with k8s.v1.cni.cncf.io/networks get an extra one."
    echo
    echo "Next: ./scripts/scenarios.sh apply pod-multi-interface"
    ;;
  delete)
    if ! installed; then
      echo "==> Multus is not installed, nothing to do"
      exit 0
    fi
    echo "==> Removing Multus $MULTUS_VERSION"
    # Deleting the CRD takes every NetworkAttachmentDefinition with it, so drop
    # the scenario first if it is still applied.
    kubectl delete --ignore-not-found -f "$MANIFEST"
    echo
    echo "Pods that were using a secondary interface keep it until they are"
    echo "recreated, and then fail to start. Delete the scenario too:"
    echo "  ./scripts/scenarios.sh delete pod-multi-interface"
    ;;
  status)
    if ! installed; then
      echo "Multus is not installed. Install it with: ./scripts/multus.sh install"
      exit 0
    fi
    kubectl -n "$NAMESPACE" get daemonset "$DAEMONSET" -o wide
    echo
    kubectl get network-attachment-definitions --all-namespaces
    ;;
  *)
    echo "Usage: $0 install|delete|status" >&2
    exit 1
    ;;
esac
