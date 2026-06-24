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
# Priority: explicit ARGOCD_REPO_URL > a running self-hosted Gitea (public lab
# repo) > the git 'origin' remote. Preferring Gitea over origin keeps the GitOps
# source on the self-hosted, no-auth repo even if lab.env was recreated without
# ARGOCD_REPO_URL — instead of silently falling back to a private GitHub remote.
ARGOCD_REPO_URL="${ARGOCD_REPO_URL:-}"

if [ -z "${ARGOCD_REPO_URL}" ]; then
  _gitea_name="${GITEA_NAME:-k3d-app-delivery-fabric-gitea}"
  _gitea_port="${GITEA_HTTP_PORT:-3000}"
  _gitea_user="${GITEA_ADMIN_USER:-giteaadmin}"
  _gitea_repo="${GITEA_REPO:-k3d-app-delivery-fabric}"
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "${_gitea_name}" \
     && curl -sf "http://127.0.0.1:${_gitea_port}/api/v1/repos/${_gitea_user}/${_gitea_repo}" >/dev/null 2>&1; then
    ARGOCD_REPO_URL="http://host.k3d.internal:${_gitea_port}/${_gitea_user}/${_gitea_repo}.git"
    info "Using self-hosted Gitea as the Argo CD source (ARGOCD_REPO_URL unset)"
  fi
fi

if [ -z "${ARGOCD_REPO_URL}" ]; then
  ARGOCD_REPO_URL="$(git -C "${REPO_DIR}" remote get-url origin 2>/dev/null || true)"
fi
if [ -z "${ARGOCD_REPO_URL}" ]; then
  err "Could not determine repo URL. Set ARGOCD_REPO_URL in lab.env."
  err "  e.g. ARGOCD_REPO_URL=https://github.com/<you>/k3d-app-delivery-fabric.git"
  exit 1
fi

# ── Resolve target revision ───────────────────────────────────────────────────
ARGOCD_TARGET_REVISION="${ARGOCD_TARGET_REVISION:-}"
if [ -z "${ARGOCD_TARGET_REVISION}" ]; then
  ARGOCD_TARGET_REVISION="$(git -C "${REPO_DIR}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"
fi

# ── Resolve exposure profile ──────────────────────────────────────────────────
LAB_PROFILE="${LAB_PROFILE:-mixed}"
PROFILE_FILE="${REPO_DIR}/argocd/lab-apps/profiles/${LAB_PROFILE}.yaml"
if [ ! -f "${PROFILE_FILE}" ]; then
  err "Unknown LAB_PROFILE '${LAB_PROFILE}' — no such file: argocd/lab-apps/profiles/${LAB_PROFILE}.yaml"
  err "Valid: mixed | nodeport-http | nodeport-https | clusterip-http | clusterip-https"
  exit 1
fi

# ── Resolve ingress/routing layer ─────────────────────────────────────────────
INGRESS_KIND="${INGRESS_KIND:-none}"
case "${INGRESS_KIND}" in
  none|nginx|cis|gateway) ;;
  *) err "Invalid INGRESS_KIND '${INGRESS_KIND}'. Valid: none | nginx | cis | gateway"; exit 1 ;;
esac

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Argo CD bootstrap (app of apps)"
echo "  Repo:     ${ARGOCD_REPO_URL}"
echo "  Revision: ${ARGOCD_TARGET_REVISION}"
echo "  Profile:  ${LAB_PROFILE}"
echo "  Ingress:  ${INGRESS_KIND}"
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

if [ -n "${ARGOCD_REPO_PASSWORD}" ] && [[ "${ARGOCD_REPO_URL}" != http://* ]]; then
  info "Registering repository credential for ${ARGOCD_REPO_URL}..."
  kubectl apply -n "${ARGOCD_NAMESPACE}" -f - <<SECRET
apiVersion: v1
kind: Secret
metadata:
  name: repo-k3d-app-delivery-fabric
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
else
  # No credential needed (public repo). Remove any stale credential Secret so it
  # can't shadow a now-public or changed repo URL with wrong/old creds.
  kubectl delete secret repo-k3d-app-delivery-fabric -n "${ARGOCD_NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
  if [ -n "${ARGOCD_REPO_PASSWORD}" ]; then
    info "Repo URL is http:// — treating as public; skipping credential registration"
  elif [[ "${ARGOCD_REPO_URL}" == https://* ]]; then
    warn "No ARGOCD_REPO_PASSWORD set — Argo CD will clone anonymously."
    warn "If ${ARGOCD_REPO_URL} is PRIVATE, the root app will stay Sync=Unknown."
    warn "Set ARGOCD_REPO_USERNAME / ARGOCD_REPO_PASSWORD (a GitHub PAT with read"
    warn "access) in lab.secrets, then re-run 'task argocd:bootstrap'."
  fi
fi

export ARGOCD_REPO_URL ARGOCD_TARGET_REVISION LAB_HOST_IP LAB_DOMAIN LAB_PROFILE INGRESS_KIND
envsubst '${ARGOCD_REPO_URL} ${ARGOCD_TARGET_REVISION} ${LAB_HOST_IP} ${LAB_DOMAIN} ${LAB_PROFILE} ${INGRESS_KIND}' \
  < "${REPO_DIR}/argocd/root-app.yaml" \
  | kubectl apply -n "${ARGOCD_NAMESPACE}" -f -

ok "Root Application applied — Argo CD will now reconcile all workloads"
echo ""
echo "  Watch progress:"
echo "    task argocd:apps      # list Application sync/health"
echo "    task argocd:wait      # block until everything is Healthy"
echo ""
