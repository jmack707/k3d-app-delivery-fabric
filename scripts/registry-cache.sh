#!/usr/bin/env bash
# scripts/registry-cache.sh
# Pull all lab images from public registries and push them to the local registry.
# Run once with internet access; afterwards the lab works air-gapped.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"; lab_bootstrap

REGISTRY_PORT="${REGISTRY_PORT:-5000}"
BASE="http://127.0.0.1:${REGISTRY_PORT}"
REG="127.0.0.1:${REGISTRY_PORT}"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Registry Cache — pull & push all lab images"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Check registry is running
if ! curl -sf "${BASE}/v2/" &>/dev/null; then
  err "Registry not reachable at ${BASE}. Run: task registry:setup first"
  exit 1
fi

cache() {
  local src="$1"
  local dst_path="$2"   # path within registry (no host prefix)
  local dst="${REG}/${dst_path}"

  info "Caching ${src}"
  docker pull "${src}" || { warn "SKIP: could not pull ${src}"; return 0; }
  docker tag "${src}" "${dst}"
  docker push "${dst}"
  ok "  → ${dst}"
}

echo ""
echo "DEMO APPS"
cache "crapi/crapi-identity:latest"   "crapi/crapi-identity:latest"
cache "crapi/crapi-community:latest"  "crapi/crapi-community:latest"
cache "crapi/crapi-workshop:latest"   "crapi/crapi-workshop:latest"
cache "crapi/crapi-web:latest"        "crapi/crapi-web:latest"
cache "mailhog/mailhog:latest"        "mailhog/mailhog:latest"
cache "bkimminich/juice-shop:latest"  "bkimminich/juice-shop:latest"
cache "dolevf/dvga:latest"            "dolevf/dvga:latest"
cache "erev0s/vampi:latest"           "erev0s/vampi:latest"

echo ""
echo "DATABASES"
cache "mongo:4.4"           "library/mongo:4.4"
cache "postgres:14-alpine"  "library/postgres:14-alpine"
cache "mariadb:10.6"        "library/mariadb:10.6"

echo ""
echo "UTILITIES"
cache "busybox:1.35"        "library/busybox:1.35"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
ok "Cache complete.  Registry: http://${LAB_HOST_IP}:${REGISTRY_PORT}"
echo "Run 'task registry:ls' to verify."
echo ""
