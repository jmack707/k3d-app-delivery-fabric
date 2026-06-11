#!/usr/bin/env bash
# scripts/test-endpoints.sh
# Curl smoke tests against every deployed app's NodePort endpoints.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"; lab_bootstrap

PASS=0
FAIL=0

banner "Endpoint Smoke Tests" "Host: ${LAB_HOST_IP}"
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

for app in ${LAB_APPS}; do
  name=$(app_display_name "${app}")

  # ClusterIP apps aren't reachable on the host IP — skip with a note.
  if [ "$(app_service_type "${app}")" = "ClusterIP" ]; then
    info "${name}  →  ClusterIP, not exposed on host (skipped)"
    continue
  fi

  http="http://${LAB_HOST_IP}:$(app_http_port "${app}")"
  https="https://${LAB_HOST_IP}:$(app_https_port "${app}")"

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

  # HTTPS endpoint, only when the app is in HTTPS_APPS
  if app_in_list "${app}" "${HTTPS_APPS}"; then
    smoke "${name} HTTPS" "${https}/"
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
