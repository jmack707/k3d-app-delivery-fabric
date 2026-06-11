#!/usr/bin/env bash
# scripts/registry-stop.sh
# Stop the registry container without removing it or its data volume.
# Restart it later with: task registry:setup
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"; lab_bootstrap

NAME="${REGISTRY_NAME:-cni-lab-registry}"

if docker ps --format '{{.Names}}' | grep -q "^${NAME}$"; then
  docker stop "${NAME}"
  ok "Registry '${NAME}' stopped (data preserved)"
  echo "  Restart with: task registry:setup"
else
  warn "Registry '${NAME}' is not running"
fi
echo ""
