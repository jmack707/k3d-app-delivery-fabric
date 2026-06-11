#!/usr/bin/env bash
# scripts/app-up.sh
# Deploy one or more apps and wait until they're actually serving traffic.
#   APP=crapi bash app-up.sh    # single app
#   bash app-up.sh              # all apps in LAB_APPS
#
# Helm-managed apps (those with apps/<app>/USES_HELM) rely on Helm's own
# --wait when HELM_WAIT=true. Raw-manifest apps get an explicit pod-readiness
# wait followed by a NodePort probe, because pod-Ready can precede the app
# actually answering on its port.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"; lab_bootstrap
require_cluster

# Deploy a single app if APP= is set, otherwise everything in LAB_APPS.
DEPLOY_LIST="${APP:-${LAB_APPS}}"

banner "App Up: ${DEPLOY_LIST}"

for app in ${DEPLOY_LIST}; do
  require_valid_app "${app}"

  ns=$(app_namespace "${app}")
  app_dir="${REPO_DIR}/apps/${app}"
  uses_helm=false
  [ -f "${app_dir}/USES_HELM" ] && uses_helm=true

  tls=false
  app_in_list "${app}" "${HTTPS_APPS}" && tls=true

  echo ""
  if [ "${uses_helm}" = true ]; then
    info "Deploying ${app} via Helm (namespace: ${ns}, TLS: ${tls})"
  else
    info "Deploying ${app} (namespace: ${ns}, TLS: ${tls})"
  fi

  APP="${app}" NS="${ns}" TLS="${tls}" \
  REGISTRY="${REGISTRY}" LAB_HOST_IP="${LAB_HOST_IP}" \
    bash "${SCRIPT_DIR}/render-app.sh"

  # Helm with --wait already blocked until pods were Ready — nothing to do.
  if [ "${uses_helm}" = true ] && [ "${HELM_WAIT:-true}" = "true" ]; then
    ok "${app} ready"
    continue
  fi

  # Raw-manifest apps (and Helm apps with HELM_WAIT=false): wait for pods.
  timeout=$(app_ready_timeout "${app}")
  info "Waiting for ${app} pods to be Ready (timeout: ${timeout}s)..."
  if ! kubectl wait --for=condition=Ready pod --all -n "${ns}" --timeout="${timeout}s" 2>/dev/null; then
    warn "${app}: some pods not Ready after ${timeout}s"
    kubectl get pods -n "${ns}" --no-headers 2>/dev/null \
      | awk '$3 != "Running" && $3 != "Completed" {printf "    %-45s  %s\n", $1, $3}' || true
    continue
  fi

  # Pod-Ready can precede the app actually answering (kube-proxy endpoint
  # refresh, TLS socket bind, app warmup). Probe the NodePort to be sure.
  # ClusterIP apps aren't reachable on the host, so skip the probe for them.
  if [ "$(app_service_type "${app}")" = "ClusterIP" ]; then
    ok "${app} ready (ClusterIP — not exposed on host)"
    continue
  fi

  http_url="http://${LAB_HOST_IP}:$(app_http_port "${app}")/"
  info "Probing ${app} NodePort ${http_url} ..."
  if wait_for_url "${http_url}" 60 "${app} NodePort"; then
    ok "${app} ready and serving"
  else
    warn "${app}: pods Ready but NodePort not yet answering — may need more time"
  fi
done

banner ""
ok "All requested apps deployed"
echo ""
echo "  Check status:   task apps:status"
echo "  Run smoke test: task test"
echo ""
