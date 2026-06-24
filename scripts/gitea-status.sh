#!/usr/bin/env bash
# scripts/gitea-status.sh
# Show Gitea container state, API reachability, and whether the lab repo exists.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"; lab_bootstrap

NAME="${GITEA_NAME:-k3d-app-delivery-fabric-gitea}"
PORT="${GITEA_HTTP_PORT:-3000}"
GITEA_ADMIN_USER="${GITEA_ADMIN_USER:-giteaadmin}"
GITEA_REPO="${GITEA_REPO:-k3d-app-delivery-fabric}"
BASE="http://127.0.0.1:${PORT}"

banner "Gitea Status"
echo ""

if docker ps --format '{{.Names}}' | grep -q "^${NAME}$"; then
  STATUS=$(docker inspect --format '{{.State.Status}}' "${NAME}" 2>/dev/null || echo "unknown")
  STARTED=$(docker inspect --format '{{.State.StartedAt}}' "${NAME}" 2>/dev/null || echo "unknown")
  ok "Container: ${NAME}  [${STATUS}]"
  echo "  Started:   ${STARTED}"
elif docker ps -a --format '{{.Names}}' | grep -q "^${NAME}$"; then
  warn "Container '${NAME}' exists but is stopped"
  echo "  Start with: task gitea:setup"
  echo ""
  exit 0
else
  err "Container '${NAME}' does not exist"
  echo "  Create with: task gitea:setup"
  echo ""
  exit 0
fi

echo ""
if curl -sf "${BASE}/api/healthz" &>/dev/null || curl -sf "${BASE}/" &>/dev/null; then
  ok "API reachable at ${BASE}"
  ok "API reachable at http://${LAB_HOST_IP}:${PORT}"
else
  err "API not responding at ${BASE}"
  echo ""
  exit 1
fi

echo ""
REPO_CODE=$(curl -s -o /dev/null -w '%{http_code}' \
  "${BASE}/api/v1/repos/${GITEA_ADMIN_USER}/${GITEA_REPO}" 2>/dev/null || echo "000")
if [ "${REPO_CODE}" = "200" ]; then
  ok "Repo ${GITEA_ADMIN_USER}/${GITEA_REPO} exists (public)"
  echo "  In-cluster URL: http://host.k3d.internal:${PORT}/${GITEA_ADMIN_USER}/${GITEA_REPO}.git"
else
  warn "Repo ${GITEA_ADMIN_USER}/${GITEA_REPO} not found (HTTP ${REPO_CODE})"
  echo "  Create + push with: task gitea:setup"
fi

echo ""
echo "  Web UI:   http://${LAB_HOST_IP}:${PORT}/"
echo "  Push:     task gitea:push"
echo ""
