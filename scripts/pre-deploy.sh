#!/usr/bin/env bash
# scripts/pre-deploy.sh
# Create namespaces, import CA into cert-manager, and apply ClusterIssuer.
# Only creates namespaces for apps in LAB_APPS (plus cert-manager if needed).
# Idempotent — safe to run multiple times.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"; lab_bootstrap

LAB_APPS="${LAB_APPS:-crapi juiceshop dvga vampi}"
HTTPS_APPS="${HTTPS_APPS:-}"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Pre-deploy"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

require_cluster

# ── Namespaces ────────────────────────────────────────────────────────────────
# Only create namespaces for apps that are actually being deployed.
info "Creating namespaces for LAB_APPS: ${LAB_APPS}"
for app in ${LAB_APPS}; do
  ns=$(app_namespace "${app}")
  kubectl create namespace "${ns}" --dry-run=client -o yaml | kubectl apply -f -
  ok "  ns/${ns}"
done

# ── cert-manager ──────────────────────────────────────────────────────────────
# Only install if at least one app needs HTTPS.
if [ -n "${HTTPS_APPS}" ]; then
  info "Installing cert-manager (HTTPS_APPS: ${HTTPS_APPS})..."

  kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -

  kubectl apply -f \
    https://github.com/cert-manager/cert-manager/releases/download/v1.14.7/cert-manager.yaml

  info "Waiting for cert-manager to be Ready..."
  kubectl wait --for=condition=Available deploy/cert-manager \
    -n cert-manager --timeout=120s
  kubectl wait --for=condition=Available deploy/cert-manager-webhook \
    -n cert-manager --timeout=120s

  # Import local CA as a TLS secret
  info "Importing local CA into cert-manager namespace..."
  kubectl create secret tls local-ca \
    --cert "${REPO_DIR}/root_ca.crt" \
    --key  "${REPO_DIR}/root_ca.key" \
    --namespace cert-manager \
    --dry-run=client -o yaml | kubectl apply -f -

  # ClusterIssuer backed by the local CA
  kubectl apply -f - << 'MANIFEST'
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: local-ca
spec:
  ca:
    secretName: local-ca
MANIFEST

  ok "ClusterIssuer 'local-ca' ready"
else
  info "No HTTPS_APPS set — skipping cert-manager install"
fi

ok "Pre-deploy complete"
echo ""
