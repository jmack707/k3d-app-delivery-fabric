#!/usr/bin/env bash
# scripts/pre-deploy.sh
# Cluster-bootstrap prerequisites that Argo CD does NOT manage: cert-manager,
# the local CA secret, and the ClusterIssuer. App namespaces are created by
# Argo CD itself (CreateNamespace=true), so they are not handled here.
# Idempotent — safe to run multiple times.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"; lab_bootstrap

HTTPS_APPS="${HTTPS_APPS:-}"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Pre-deploy (cert-manager bootstrap)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

require_cluster

# ── cert-manager ──────────────────────────────────────────────────────────────
# Only install if at least one app needs HTTPS (HTTPS_APPS in lab.env). The
# nginx TLS sidecar in each app chart consumes the cert-manager-issued secret;
# the local-ca ClusterIssuer below signs them.
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
