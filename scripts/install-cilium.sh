#!/usr/bin/env bash
# scripts/install-cilium.sh
# Install Cilium CNI via Helm.
# Hubble is enabled by default for traffic visibility.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

CILIUM_VERSION="1.15.4"

info "Installing Cilium ${CILIUM_VERSION} via Helm..."

# Add Cilium Helm repo if not present
if ! helm repo list 2>/dev/null | grep -q "cilium"; then
  helm repo add cilium https://helm.cilium.io/
fi
helm repo update cilium

# Get the k3d server node's internal IP for KubeProxyReplacement
K8S_API_SERVER_IP=$(kubectl get nodes \
  -l node-role.kubernetes.io/control-plane=true \
  -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

helm upgrade --install cilium cilium/cilium \
  --version "${CILIUM_VERSION}" \
  --namespace kube-system \
  --set ipam.mode=kubernetes \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost="${K8S_API_SERVER_IP}" \
  --set k8sServicePort="6443" \
  --set hostServices.enabled=false \
  --set externalIPs.enabled=true \
  --set nodePort.enabled=true \
  --set hostPort.enabled=true \
  --set bpf.masquerade=false \
  --set image.pullPolicy=IfNotPresent \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true \
  --wait \
  --timeout 300s

info "Waiting for all nodes to be Ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=180s

ok "Cilium ${CILIUM_VERSION} installed and nodes Ready"
echo ""
echo "  Verify:"
echo "    kubectl get pods -n kube-system -l k8s-app=cilium"
echo "    task cni:status"
echo ""
echo "  Hubble UI (traffic visibility):"
echo "    task cni:hubble   → http://localhost:12000"
echo ""
