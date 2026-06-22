#!/usr/bin/env bash
# scripts/gitea-setup.sh
# Run Gitea as a host container (independent of the cluster, like the registry),
# create the lab repo, and push the current branch. Argo CD can then use this
# self-hosted Gitea as its source of truth instead of GitHub — keeping the whole
# lab self-contained / air-gappable.
#
# Reachability mirrors the registry: bound to 127.0.0.1 and LAB_HOST_IP on the
# host, reached from inside the cluster via host.k3d.internal:<port>.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"; lab_bootstrap

GITEA_NAME="${GITEA_NAME:-cni-lab-gitea}"
GITEA_HTTP_PORT="${GITEA_HTTP_PORT:-3000}"
GITEA_IMAGE="${GITEA_IMAGE:-gitea/gitea:1.22}"
GITEA_ADMIN_USER="${GITEA_ADMIN_USER:-giteaadmin}"
GITEA_ADMIN_PASSWORD="${GITEA_ADMIN_PASSWORD:-gitea-admin-lab}"
GITEA_REPO="${GITEA_REPO:-cni-net-lab}"
BASE="http://127.0.0.1:${GITEA_HTTP_PORT}"

banner "Gitea Setup"

if [ "${GITEA_ADMIN_PASSWORD}" = "gitea-admin-lab" ]; then
  warn "Using the default GITEA_ADMIN_PASSWORD — set one in lab.secrets to override"
fi

# ── Start container (idempotent) ──────────────────────────────────────────────
if docker ps --format '{{.Names}}' | grep -q "^${GITEA_NAME}$"; then
  ok "Gitea '${GITEA_NAME}' already running"
else
  if docker ps -a --format '{{.Names}}' | grep -q "^${GITEA_NAME}$"; then
    info "Removing stopped Gitea container..."
    docker rm "${GITEA_NAME}"
  fi
  info "Starting Gitea container (${GITEA_IMAGE})..."
  # Publish on 0.0.0.0 (all host interfaces). Argo CD's repo-server is a POD, so
  # it reaches Gitea via the cluster gateway (host.k3d.internal) — that path only
  # works if the port is published on all interfaces, not just 127.0.0.1.
  docker run -d \
    --name "${GITEA_NAME}" \
    --restart always \
    -p "${GITEA_HTTP_PORT}:3000" \
    -v "${GITEA_NAME}-data:/data" \
    -e GITEA__database__DB_TYPE=sqlite3 \
    -e GITEA__database__PATH=/data/gitea/gitea.db \
    -e GITEA__server__ROOT_URL="http://${LAB_HOST_IP}:${GITEA_HTTP_PORT}/" \
    -e GITEA__server__HTTP_PORT=3000 \
    -e GITEA__security__INSTALL_LOCK=true \
    -e GITEA__service__DISABLE_REGISTRATION=true \
    -e GITEA__service__REQUIRE_SIGNIN_VIEW=false \
    "${GITEA_IMAGE}"
fi

# ── Wait for the API ──────────────────────────────────────────────────────────
info "Waiting for Gitea to be ready..."
if ! wait_for_url "${BASE}/api/healthz" 90 "Gitea"; then
  if ! wait_for_url "${BASE}/" 30 "Gitea"; then
    err "Gitea did not become ready"
    docker logs "${GITEA_NAME}" 2>&1 | tail -20
    exit 1
  fi
fi
ok "Gitea is up"

# ── Admin user (idempotent) ───────────────────────────────────────────────────
info "Ensuring admin user '${GITEA_ADMIN_USER}'..."
if docker exec -u git "${GITEA_NAME}" gitea admin user list 2>/dev/null \
     | awk 'NR>1 {print $2}' | grep -qx "${GITEA_ADMIN_USER}"; then
  ok "Admin user already exists"
else
  if docker exec -u git "${GITEA_NAME}" gitea admin user create \
       --admin --username "${GITEA_ADMIN_USER}" --password "${GITEA_ADMIN_PASSWORD}" \
       --email "${GITEA_ADMIN_USER}@lab.local" --must-change-password=false 2>/dev/null; then
    ok "Admin user created"
  else
    warn "Admin user create returned non-zero (continuing — may already exist)"
  fi
fi

# ── Repo (idempotent) ─────────────────────────────────────────────────────────
info "Ensuring repo '${GITEA_ADMIN_USER}/${GITEA_REPO}' (public)..."
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "${BASE}/api/v1/user/repos" \
  -u "${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASSWORD}" \
  -H "Content-Type: application/json" \
  -d "{\"name\":\"${GITEA_REPO}\",\"private\":false,\"auto_init\":false}" || echo "000")
case "${code}" in
  201) ok "Repo created" ;;
  409) ok "Repo already exists" ;;
  *)   warn "Repo create returned HTTP ${code} (continuing)" ;;
esac

# ── Push current branch ───────────────────────────────────────────────────────
bash "${SCRIPT_DIR}/gitea-push.sh"

# ── Argo CD wiring hint ───────────────────────────────────────────────────────
CLUSTER_URL="http://host.k3d.internal:${GITEA_HTTP_PORT}/${GITEA_ADMIN_USER}/${GITEA_REPO}.git"
BRANCH="$(git -C "${REPO_DIR}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"

banner "Gitea ready"
echo "  Web UI:  http://${LAB_HOST_IP}:${GITEA_HTTP_PORT}/   (login: ${GITEA_ADMIN_USER})"
echo ""
echo "  Point Argo CD at Gitea — set these in lab.env, then re-bootstrap:"
echo ""
echo "    ARGOCD_REPO_URL=${CLUSTER_URL}"
echo "    ARGOCD_TARGET_REVISION=${BRANCH}"
echo ""
echo "    task argocd:bootstrap && task argocd:wait"
echo ""
echo "  The repo is public, so no ARGOCD_REPO_PASSWORD is needed."
echo ""
echo "  If Argo can't reach host.k3d.internal, fall back to the host IP:"
echo "    ARGOCD_REPO_URL=http://${LAB_HOST_IP}:${GITEA_HTTP_PORT}/${GITEA_ADMIN_USER}/${GITEA_REPO}.git"
echo ""
echo "  After future commits: task gitea:push && task argocd:sync"
echo ""
