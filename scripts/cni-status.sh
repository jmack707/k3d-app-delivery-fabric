#!/usr/bin/env bash
# scripts/cni-status.sh
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"; lab_bootstrap

CNI="${CNI:-cilium}"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  CNI Status: ${CNI}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo ""
echo "Nodes:"
kubectl get nodes -o wide

echo ""
case "${CNI}" in
  calico)
    echo "Calico pods:"
    kubectl get pods -n calico-system -o wide 2>/dev/null || \
      kubectl get pods -n kube-system -l k8s-app=calico-node -o wide
    ;;
  cilium)
    echo "Cilium pods:"
    kubectl get pods -n kube-system -l k8s-app=cilium -o wide
    echo ""
    echo "Cilium status:"
    kubectl exec -n kube-system ds/cilium -- cilium status --brief 2>/dev/null || \
      warn "cilium CLI not available inside pod — check pod logs instead"
    ;;
esac

echo ""
