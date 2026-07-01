#!/usr/bin/env bash
# scripts/test-endpoints.sh
# Curl smoke tests against every deployed app's NodePort endpoints.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"; lab_bootstrap

PASS=0
FAIL=0

# LAB_HOST_IP on bridge; a live node LAN IP under ipvlan (ports aren't host-published).
APP_HOST="$(app_access_host)"

banner "Endpoint Smoke Tests" "Host: ${APP_HOST}"
echo ""

# smoke <label> <url> [expected-codes]
smoke() {
  local label="$1" url="$2" expected="${3:-200 301 302 401 403 404}" code
  code=$(curl -sk --max-time 8 -o /dev/null -w "%{http_code}" "${url}" 2>/dev/null || echo "000")
  if echo "${expected}" | grep -wq "${code}"; then
    ok  "${label}  →  ${url}  [${code}]"
    PASS=$((PASS + 1))
  else
    err "${label}  →  ${url}  [${code}] (expected: ${expected})"
    FAIL=$((FAIL + 1))
  fi
}

APPS="$(deployed_apps)"
[ -z "${APPS}" ] && warn "No Argo CD Applications found for known apps"
for app in ${APPS}; do
  name=$(app_display_name "${app}")

  # ClusterIP apps aren't reachable on the host IP — skip with a note.
  if [ "$(app_service_type "${app}")" = "ClusterIP" ]; then
    info "${name}  →  ClusterIP, not exposed on host (skipped)"
    continue
  fi

  http_np=$(app_node_port "${app}" http)
  https_np=$(app_node_port "${app}" https)
  http="http://${APP_HOST}:${http_np}"

  # Root HTTP endpoint
  smoke "${name} HTTP " "${http}/"

  # Any extra HTTP paths declared in the metadata table (e.g. VAmPI /ui/)
  paths=$(app_test_paths "${app}")
  if [ -n "${paths}" ]; then
    IFS=',' read -ra extra <<< "${paths}"
    for p in "${extra[@]}"; do
      smoke "${name} ${p}" "${http}${p}"
    done
  fi

  # HTTPS endpoint, only when the Service actually publishes a TLS NodePort
  if [ -n "${https_np}" ]; then
    smoke "${name} HTTPS" "https://${APP_HOST}:${https_np}/"
  fi
done

banner ""
if [ "${FAIL}" -eq 0 ]; then
  ok "${PASS} tests passed"
else
  err "${FAIL} test(s) failed, ${PASS} passed"
  exit 1
fi
echo ""
