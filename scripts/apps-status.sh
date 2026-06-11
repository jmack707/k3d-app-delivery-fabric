#!/usr/bin/env bash
# scripts/apps-status.sh
# Show pod + service status and access URLs for every app in LAB_APPS.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"; lab_bootstrap

banner "App Status"

for app in ${LAB_APPS}; do
  ns=$(app_namespace "${app}")
  tls=false
  app_in_list "${app}" "${HTTPS_APPS}" && tls=true

  echo ""
  echo "── ${app} (${ns}) ──"

  if ! kubectl get ns "${ns}" &>/dev/null; then
    warn "  namespace not found — app not deployed"
    continue
  fi

  kubectl get pods -n "${ns}" --no-headers 2>/dev/null \
    | awk '{printf "  %-45s  %s/%s  %s\n", $1, $2, $3, $4}' || true

  echo ""
  kubectl get svc -n "${ns}" --no-headers 2>/dev/null \
    | awk '{printf "  svc/%-40s  %s\n", $1, $5}' || true

  echo ""
  if [ "$(app_service_type "${app}")" = "ClusterIP" ]; then
    echo "  ClusterIP — not exposed on host. Use kubectl port-forward."
  else
    echo "  HTTP:  http://${LAB_HOST_IP}:$(app_http_port "${app}")"
    [ "${tls}" = true ] && echo "  HTTPS: https://${LAB_HOST_IP}:$(app_https_port "${app}")"
  fi
done

echo ""
