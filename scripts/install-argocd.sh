#!/usr/bin/env bash
# scripts/install-argocd.sh
# Install Argo CD via Helm into the 'argocd' namespace.
#
# The lab has no ingress controller, so the API/UI server is exposed as a
# NodePort on ARGOCD_HTTP_PORT (bound at cluster-create time, see
# create-cluster.sh) and runs in --insecure mode (plain HTTP behind the
# NodePort). Fine for a local lab; do not copy this to anything internet-facing.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"; lab_bootstrap
require_cluster

ARGOCD_VERSION="${ARGOCD_CHART_VERSION:-7.7.5}"   # argo-helm chart version (Argo CD v2.13.x)
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
ARGOCD_HTTP_PORT="${ARGOCD_HTTP_PORT:-30090}"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Argo CD install (chart ${ARGOCD_VERSION})"
echo "  Namespace:  ${ARGOCD_NAMESPACE}"
echo "  UI NodePort: ${ARGOCD_HTTP_PORT}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if ! helm repo list 2>/dev/null | grep -q "argo-helm\|argoproj.github.io"; then
  helm repo add argo https://argoproj.github.io/argo-helm
fi
helm repo update argo

info "Installing/upgrading Argo CD..."
helm upgrade --install argocd argo/argo-cd \
  --version "${ARGOCD_VERSION}" \
  --namespace "${ARGOCD_NAMESPACE}" \
  --create-namespace \
  --set configs.params."server\.insecure"=true \
  --set server.service.type=NodePort \
  --set server.service.nodePortHttp="${ARGOCD_HTTP_PORT}" \
  --wait \
  --timeout 600s

info "Waiting for Argo CD components to be Ready..."
kubectl rollout status deploy/argocd-server -n "${ARGOCD_NAMESPACE}" --timeout=300s
kubectl rollout status deploy/argocd-repo-server -n "${ARGOCD_NAMESPACE}" --timeout=300s

ok "Argo CD installed"
echo ""
echo "  UI:        http://${LAB_HOST_IP}:${ARGOCD_HTTP_PORT}"
echo "  Username:  admin"
echo "  Password:  task argocd:password"
echo ""
echo "  Next: task argocd:bootstrap   (registers the app-of-apps)"
echo ""
