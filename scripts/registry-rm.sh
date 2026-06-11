#!/usr/bin/env bash
# scripts/registry-rm.sh
# Remove the registry container AND its data volume.
# This is irreversible — all cached images will be lost.
# Use 'task registry:stop' if you just want to pause the registry.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"; lab_bootstrap

NAME="${REGISTRY_NAME:-cni-lab-registry}"

echo ""
warn "This will remove the registry container AND all cached image data."
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
echo "  Recreate with: task registry:setup"
echo ""
