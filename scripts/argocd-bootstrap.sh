#!/usr/bin/env bash
# scripts/argocd-bootstrap.sh
# Render and apply the root "app of apps" Application. Argo CD then takes over
# and deploys every workload from git (argocd/lab-apps → per-app charts).
#
# Resolves the repo URL and target revision in this order:
#   1. ARGOCD_REPO_URL / ARGOCD_TARGET_REVISION from lab.env (explicit override)
#   2. the current git remote 'origin' and checked-out branch
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"; lab_bootstrap
require_cluster

ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"

# ── Resolve repo URL ──────────────────────────────────────────────────────────
ARGOCD_REPO_URL="${ARGOCD_REPO_URL:-}"
if [ -z "${ARGOCD_REPO_URL}" ]; then
  ARGOCD_REPO_URL="$(git -C "${REPO_DIR}" remote get-url origin 2>/dev/null || true)"
fi
if [ -z "${ARGOCD_REPO_URL}" ]; then
  err "Could not determine repo URL. Set ARGOCD_REPO_URL in lab.env."
  err "  e.g. ARGOCD_REPO_URL=https://github.com/<you>/cni-net-lab.git"
  exit 1
fi

# ── Resolve target revision ───────────────────────────────────────────────────
ARGOCD_TARGET_REVISION="${ARGOCD_TARGET_REVISION:-}"
if [ -z "${ARGOCD_TARGET_REVISION}" ]; then
  ARGOCD_TARGET_REVISION="$(git -C "${REPO_DIR}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Argo CD bootstrap (app of apps)"
echo "  Repo:     ${ARGOCD_REPO_URL}"
echo "  Revision: ${ARGOCD_TARGET_REVISION}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Verify Argo CD is present before registering the app.
if ! kubectl get ns "${ARGOCD_NAMESPACE}" &>/dev/null \
   || ! kubectl get deploy argocd-server -n "${ARGOCD_NAMESPACE}" &>/dev/null; then
  err "Argo CD not installed. Run 'task argocd:install' first."
  exit 1
fi

# ── Repository credentials (private repos) ────────────────────────────────────
# Argo CD's repo-server clones the repo anonymously by default, which fails for
# a PRIVATE repo (the Application stays Sync=Unknown and never creates children).
# If ARGOCD_REPO_PASSWORD is set in lab.secrets, register a repository Secret so
# Argo can authenticate. For GitHub, use a Personal Access Token with read
# access to the repo as the password (the username is ignored for PAT auth).
ARGOCD_REPO_USERNAME="${ARGOCD_REPO_USERNAME:-git}"
ARGOCD_REPO_PASSWORD="${ARGOCD_REPO_PASSWORD:-}"

if [ -n "${ARGOCD_REPO_PASSWORD}" ]; then
  info "Registering repository credential for ${ARGOCD_REPO_URL}..."
  kubectl apply -n "${ARGOCD_NAMESPACE}" -f - <<SECRET
apiVersion: v1
kind: Secret
metadata:
  name: repo-cni-net-lab
  namespace: ${ARGOCD_NAMESPACE}
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: ${ARGOCD_REPO_URL}
  username: ${ARGOCD_REPO_USERNAME}
  password: ${ARGOCD_REPO_PASSWORD}
SECRET
  ok "Repository credential registered"
elif [[ "${ARGOCD_REPO_URL}" == https://* ]]; then
  warn "No ARGOCD_REPO_PASSWORD set — Argo CD will clone anonymously."
  warn "If ${ARGOCD_REPO_URL} is PRIVATE, the root app will stay Sync=Unknown."
  warn "Set ARGOCD_REPO_USERNAME / ARGOCD_REPO_PASSWORD (a GitHub PAT with read"
  warn "access) in lab.secrets, then re-run 'task argocd:bootstrap'."
fi

export ARGOCD_REPO_URL ARGOCD_TARGET_REVISION LAB_HOST_IP LAB_DOMAIN
envsubst '${ARGOCD_REPO_URL} ${ARGOCD_TARGET_REVISION} ${LAB_HOST_IP} ${LAB_DOMAIN}' \
  < "${REPO_DIR}/argocd/root-app.yaml" \
  | kubectl apply -n "${ARGOCD_NAMESPACE}" -f -

ok "Root Application applied — Argo CD will now reconcile all workloads"
echo ""
echo "  Watch progress:"
echo "    task argocd:apps      # list Application sync/health"
echo "    task argocd:wait      # block until everything is Healthy"
echo ""
