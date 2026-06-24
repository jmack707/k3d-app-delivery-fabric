#!/usr/bin/env bash
# scripts/gitea-push.sh
# Push the current branch to the Gitea lab repo (Argo CD's source of truth when
# using self-hosted Gitea). Run this after committing changes, then let Argo CD
# sync (it auto-refreshes, or force it with 'task argocd:sync').
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"; lab_bootstrap

GITEA_NAME="${GITEA_NAME:-k3d-app-delivery-fabric-gitea}"
GITEA_HTTP_PORT="${GITEA_HTTP_PORT:-3000}"
GITEA_ADMIN_USER="${GITEA_ADMIN_USER:-giteaadmin}"
GITEA_ADMIN_PASSWORD="${GITEA_ADMIN_PASSWORD:-gitea-admin-lab}"
GITEA_REPO="${GITEA_REPO:-k3d-app-delivery-fabric}"

validate_gitea_admin_user

if ! docker ps --format '{{.Names}}' | grep -q "^${GITEA_NAME}$"; then
  err "Gitea is not running. Start it with: task gitea:setup"
  exit 1
fi

BRANCH="$(git -C "${REPO_DIR}" rev-parse --abbrev-ref HEAD)"

# URL-encode the password so special characters survive in the push URL, and
# mask it from any git output. The credential is only used for this one push —
# it is never saved as a git remote.
ENC_PASS="$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "${GITEA_ADMIN_PASSWORD}")"
PUSH_URL="http://${GITEA_ADMIN_USER}:${ENC_PASS}@127.0.0.1:${GITEA_HTTP_PORT}/${GITEA_ADMIN_USER}/${GITEA_REPO}.git"

info "Pushing '${BRANCH}' → Gitea (${GITEA_ADMIN_USER}/${GITEA_REPO})..."
git -C "${REPO_DIR}" push "${PUSH_URL}" "HEAD:refs/heads/${BRANCH}" 2>&1 \
  | sed "s|${ENC_PASS}|***|g"

ok "Pushed '${BRANCH}' to Gitea"
echo ""
echo "  Trigger an immediate Argo CD sync:  task argocd:sync"
echo ""
