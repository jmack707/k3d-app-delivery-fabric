#!/usr/bin/env bash
# scripts/argocd-wait.sh
# Block until every Argo CD Application is Synced and Healthy (or timeout).
# Used by 'task up' so 'task health' runs only after Argo finishes reconciling.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"; lab_bootstrap
require_cluster

ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
TIMEOUT="${ARGOCD_WAIT_TIMEOUT:-900}"
INTERVAL=10
elapsed=0

banner "Waiting for Argo CD Applications (timeout: ${TIMEOUT}s)"

while [ "${elapsed}" -lt "${TIMEOUT}" ]; do
  apps="$(kubectl get applications -n "${ARGOCD_NAMESPACE}" \
            -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.sync.status}{" "}{.status.health.status}{"\n"}{end}' \
            2>/dev/null || true)"

  if [ -z "${apps}" ]; then
    info "No Applications registered yet..."
  else
    pending=0
    while IFS=' ' read -r name sync health; do
      [ -z "${name}" ] && continue
      if [ "${sync}" = "Synced" ] && [ "${health}" = "Healthy" ]; then
        ok "${name}: ${sync}/${health}"
      else
        warn "${name}: ${sync:-?}/${health:-?}"
        pending=$((pending + 1))
      fi
    done <<< "${apps}"

    if [ "${pending}" -eq 0 ]; then
      echo ""
      ok "All Applications Synced and Healthy"
      exit 0
    fi
  fi

  sleep "${INTERVAL}"
  elapsed=$((elapsed + INTERVAL))
  echo "  … ${elapsed}s elapsed"
done

err "Timed out after ${TIMEOUT}s waiting for Applications to become Healthy"
kubectl get applications -n "${ARGOCD_NAMESPACE}" 2>/dev/null || true
echo ""
echo "  Inspect a stuck app:  kubectl describe application <name> -n ${ARGOCD_NAMESPACE}"
exit 1
