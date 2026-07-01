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

# Port still held by a *different* container — this is what bit the rename
# cold-boot: the old project's registry (e.g. cni-lab-registry) kept :5000, so
# 'docker run' failed with "port is already allocated". If the holder is a
# previous lab registry, reclaim the port; if it's something unrelated, stop and
# say so rather than clobbering it.
# `|| true`: on a fresh host nothing publishes the port, so grep -v matches no
# lines and exits non-zero — under `set -euo pipefail` that bare assignment would
# otherwise abort the script before the registry is ever started.
port_holder="$(docker ps -a --filter "publish=${REGISTRY_PORT}" --format '{{.Names}}' \
  | grep -v "^${REGISTRY_NAME}$" | head -1 || true)"
if [ -n "${port_holder}" ]; then
  case "${port_holder}" in
    *-registry|registry)
      warn "Port ${REGISTRY_PORT} held by a previous lab registry '${port_holder}' — removing it"
      docker rm -f "${port_holder}"
      ;;
    *)
      err "Port ${REGISTRY_PORT} is already in use by container '${port_holder}' (not a lab registry)."
      err "Free it, or set REGISTRY_PORT to an open port, then re-run 'task registry:setup'."
      exit 1
      ;;
  esac
fi

info "Starting registry container..."
# Port bindings depend on the network mode. Under ipvlan the k3d nodes reach the
# host via a shim IP that may not exist yet (it's created during 'task up'), so
# bind all interfaces rather than a specific address that docker can't yet assign.
if [ "${LAB_NET_MODE:-bridge}" = "ipvlan" ]; then
  REG_PORTS=(-p "${REGISTRY_PORT}:5000")
else
  REG_PORTS=(
    -p "127.0.0.1:${REGISTRY_PORT}:5000"
    -p "${LAB_HOST_IP}:${REGISTRY_PORT}:5000"
  )
fi
docker run -d \
  --name "${REGISTRY_NAME}" \
  --restart always \
  "${REG_PORTS[@]}" \
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
