#!/usr/bin/env bash
# scripts/install-calico.sh
# Install Calico CNI via the Tigera operator (recommended path for k3d).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

CALICO_VERSION="v3.27.3"
OPERATOR_MANIFEST="https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/tigera-operator.yaml"

info "Installing Calico ${CALICO_VERSION} via Tigera operator..."

# Install the operator. Use apply so re-runs are idempotent.
kubectl apply -f "${OPERATOR_MANIFEST}"

# Wait for Tigera CRDs — the Installation CR can't be applied until they exist
info "Waiting for Tigera operator CRDs..."
if ! wait_for_url "" 0 ""; then true; fi  # ensure wait_for_url is available
elapsed=0
until kubectl get crd installations.operator.tigera.io &>/dev/null; do
  sleep 2
  elapsed=$((elapsed + 2))
  if [ "${elapsed}" -ge 60 ]; then
    err "Tigera CRDs not ready after 60s"
    kubectl get pods -n tigera-operator 2>/dev/null || true
    exit 1
  fi
done
ok "Tigera CRDs ready"

# Apply the Installation CR.
# Sets the pod CIDR to 10.42.0.0/16 to match k3d's default cluster CIDR.
# VXLANCrossSubnet encapsulation works across the k3d Docker bridge.
cat <<'MANIFEST' | kubectl apply -f -
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    ipPools:
    - blockSize: 26
      cidr: 10.42.0.0/16
      encapsulation: VXLANCrossSubnet
      natOutgoing: Enabled
      nodeSelector: all()
MANIFEST

# Wait for all nodes to become Ready
info "Waiting for all nodes to be Ready (this takes ~90s for Calico)..."
kubectl wait --for=condition=Ready nodes --all --timeout=180s

ok "Calico ${CALICO_VERSION} installed and nodes Ready"
echo ""
echo "  Verify:"
echo "    kubectl get pods -n calico-system"
echo "    kubectl get nodes"
echo ""
