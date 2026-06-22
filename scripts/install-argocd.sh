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
# The chart defaults the HTTPS NodePort to 30443, which collides with crAPI's
# HTTPS NodePort. We serve the UI over HTTP (insecure), so this port is unused —
# park it on a non-conflicting value to free 30443 for the apps.
ARGOCD_HTTPS_NODEPORT="${ARGOCD_HTTPS_NODEPORT:-30091}"
ARGOCD_ADMIN_PASSWORD="${ARGOCD_ADMIN_PASSWORD:-}"   # plaintext, from lab.secrets

# Produce a bcrypt hash of $1 for the chart's argocdServerAdminPassword value.
# Prefers htpasswd (apache2-utils); falls back to python3-bcrypt.
argocd_bcrypt() {
  local pw="$1" hash=""
  if command -v htpasswd &>/dev/null; then
    # htpasswd -nbBC 10 "" pw  →  ":$2y$10$...", strip the empty-username colon
    hash="$(htpasswd -nbBC 10 "" "${pw}" 2>/dev/null | tr -d ':\n')"
  fi
  if [ -z "${hash}" ] && command -v python3 &>/dev/null; then
    hash="$(python3 -c 'import bcrypt,sys; print(bcrypt.hashpw(sys.argv[1].encode(), bcrypt.gensalt(rounds=10)).decode())' "${pw}" 2>/dev/null || true)"
  fi
  [ -n "${hash}" ] && printf '%s' "${hash}"
}

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Argo CD install (chart ${ARGOCD_VERSION})"
echo "  Namespace:  ${ARGOCD_NAMESPACE}"
echo "  UI NodePort: ${ARGOCD_HTTP_PORT}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── Optional: custom admin password from lab.secrets ──────────────────────────
ADMIN_PW_SET=()
CUSTOM_ADMIN_PW=false
if [ -n "${ARGOCD_ADMIN_PASSWORD}" ]; then
  info "Setting admin password from lab.secrets (ARGOCD_ADMIN_PASSWORD)..."
  BCRYPT_HASH="$(argocd_bcrypt "${ARGOCD_ADMIN_PASSWORD}")"
  if [ -z "${BCRYPT_HASH}" ]; then
    err "Could not generate a bcrypt hash. Install apache2-utils (htpasswd)"
    err "or the python3 'bcrypt' module, then re-run."
    exit 1
  fi
  # Mtime must change for Argo CD to adopt a new password on upgrade.
  PW_MTIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  ADMIN_PW_SET+=(--set-string "configs.secret.argocdServerAdminPassword=${BCRYPT_HASH}")
  ADMIN_PW_SET+=(--set-string "configs.secret.argocdServerAdminPasswordMtime=${PW_MTIME}")
  CUSTOM_ADMIN_PW=true
fi

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
  --set server.service.nodePortHttps="${ARGOCD_HTTPS_NODEPORT}" \
  "${ADMIN_PW_SET[@]}" \
  --wait \
  --timeout 600s

info "Waiting for Argo CD components to be Ready..."
kubectl rollout status deploy/argocd-server -n "${ARGOCD_NAMESPACE}" --timeout=300s
kubectl rollout status deploy/argocd-repo-server -n "${ARGOCD_NAMESPACE}" --timeout=300s

ok "Argo CD installed"
echo ""
echo "  UI:        http://${LAB_HOST_IP}:${ARGOCD_HTTP_PORT}"
echo "  Username:  admin"
if [ "${CUSTOM_ADMIN_PW}" = true ]; then
  echo "  Password:  (from ARGOCD_ADMIN_PASSWORD in lab.secrets)"
else
  echo "  Password:  task argocd:password"
fi
echo ""
echo "  Next: task argocd:bootstrap   (registers the app-of-apps)"
echo ""
