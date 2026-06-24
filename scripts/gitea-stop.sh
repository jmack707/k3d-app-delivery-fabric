#!/usr/bin/env bash
# scripts/gitea-stop.sh
# Stop the Gitea container without removing it or its data volume.
# Restart later with: task gitea:setup
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"; lab_bootstrap

NAME="${GITEA_NAME:-k3d-app-delivery-fabric-gitea}"

if docker ps --format '{{.Names}}' | grep -q "^${NAME}$"; then
  docker stop "${NAME}"
  ok "Gitea '${NAME}' stopped (data preserved)"
  echo "  Restart with: task gitea:setup"
else
  warn "Gitea '${NAME}' is not running"
fi
echo ""
