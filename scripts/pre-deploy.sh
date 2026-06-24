#!/usr/bin/env bash
# scripts/pre-deploy.sh
# Cluster-bootstrap prerequisites that Argo CD does NOT manage: cert-manager,
# the local CA secret, and the ClusterIssuer. App namespaces are created by
# Argo CD itself (CreateNamespace=true), so they are not handled here.
# Idempotent — safe to run multiple times.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"; lab_bootstrap

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Pre-deploy (cert-manager bootstrap)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

require_cluster

# ── cert-manager ──────────────────────────────────────────────────────────────
# Installed unconditionally — which apps use TLS now lives in Gitea (per-app
# tls in argocd/lab-apps), so we can't (and needn't) gate on it here. cert-manager
# is lightweight; the nginx TLS sidecar in each app chart consumes the issued
# secret, and the local-ca ClusterIssuer below signs them.
info "Installing cert-manager..."

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
ok "Pre-deploy complete"
echo ""
