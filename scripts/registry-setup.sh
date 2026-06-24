#!/usr/bin/env bash
# scripts/registry-setup.sh
# Start the external Docker registry v2 container.
# Binds to both 127.0.0.1:REGISTRY_PORT and LAB_HOST_IP:REGISTRY_PORT.
# REGISTRY_STORAGE_DELETE_ENABLED=true is set so 'task registry:flush' works.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"; lab_bootstrap

REGISTRY_PORT="${REGISTRY_PORT:-5000}"
REGISTRY_NAME="${REGISTRY_NAME:-k3d-app-delivery-fabric-registry}"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Registry Setup"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Already running — nothing to do
if docker ps --format '{{.Names}}' | grep -q "^${REGISTRY_NAME}$"; then
  ok "Registry '${REGISTRY_NAME}' already running"
  echo ""
  echo "  Endpoints:"
  echo "    http://127.0.0.1:${REGISTRY_PORT}"
  echo "    http://${LAB_HOST_IP}:${REGISTRY_PORT}"
  exit 0
fi

# Stopped container with the same name — remove it so docker run succeeds
if docker ps -a --format '{{.Names}}' | grep -q "^${REGISTRY_NAME}$"; then
  info "Removing stopped registry container..."
  docker rm "${REGISTRY_NAME}"
fi

info "Starting registry container..."
docker run -d \
  --name "${REGISTRY_NAME}" \
  --restart always \
  -p "127.0.0.1:${REGISTRY_PORT}:5000" \
  -p "${LAB_HOST_IP}:${REGISTRY_PORT}:5000" \
  -v "${REGISTRY_NAME}-data:/var/lib/registry" \
  -e REGISTRY_STORAGE_DELETE_ENABLED=true \
  registry:2

# Wait for the API to respond
info "Waiting for registry to be ready..."
if wait_for_url "http://127.0.0.1:${REGISTRY_PORT}/v2/" 15 "Registry"; then
  ok "Registry is ready"
else
  err "Registry did not become ready after 15s"
  docker logs "${REGISTRY_NAME}" | tail -10
  exit 1
fi

echo ""
ok "Registry running"
echo ""
echo "  Endpoints:"
echo "    http://127.0.0.1:${REGISTRY_PORT}"
echo "    http://${LAB_HOST_IP}:${REGISTRY_PORT}"
echo ""
echo "  Push an image:"
echo "    docker tag myimage:latest ${LAB_HOST_IP}:${REGISTRY_PORT}/myimage:latest"
echo "    docker push ${LAB_HOST_IP}:${REGISTRY_PORT}/myimage:latest"
echo ""
echo "  View contents:  task registry:ls"
echo "  Flush all:      task registry:flush"
echo ""
