#!/usr/bin/env bash
# scripts/gitea-rm.sh
# Remove the Gitea container AND its data volume.
# Irreversible — all repos/history in Gitea are lost (your local git repo and
# GitHub are unaffected). Use 'task gitea:stop' to just pause it.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"; lab_bootstrap

NAME="${GITEA_NAME:-k3d-app-delivery-fabric-gitea}"

echo ""
warn "This will remove the Gitea container AND all data (repos, users)."
echo ""

if [ "${FORCE:-0}" != "1" ]; then
  read -rp "  Type 'yes' to confirm: " CONFIRM
  if [ "${CONFIRM}" != "yes" ]; then
    info "Aborted"
    exit 0
  fi
fi

docker rm -f "${NAME}" 2>/dev/null && ok "Container '${NAME}' removed" || true
docker volume rm "${NAME}-data" 2>/dev/null && ok "Volume '${NAME}-data' removed" || true
echo ""
echo "  Recreate with: task gitea:setup"
echo ""
