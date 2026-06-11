#!/usr/bin/env bash
# scripts/app-down.sh
# Stop one or more apps. Helm-managed apps are uninstalled first so the
# release record is cleaned up, then the namespace is deleted.
#   APP=crapi bash app-down.sh    # single app
#   bash app-down.sh              # all apps in LAB_APPS
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"; lab_bootstrap
require_cluster

STOP_LIST="${APP:-${LAB_APPS}}"

banner "App Down: ${STOP_LIST}"

for app in ${STOP_LIST}; do
  require_valid_app "${app}"

  ns=$(app_namespace "${app}")
  app_dir="${REPO_DIR}/apps/${app}"

  # Uninstall the Helm release first (if any) so Helm's state stays clean.
  if [ -f "${app_dir}/USES_HELM" ] && helm status "${app}" -n "${ns}" &>/dev/null; then
    info "Uninstalling Helm release ${app}..."
    helm uninstall "${app}" -n "${ns}" --wait --timeout 2m \
      || warn "helm uninstall returned non-zero (continuing)"
  fi

  info "Stopping ${app} (namespace: ${ns})..."
  kubectl delete namespace "${ns}" --ignore-not-found
  ok "${app} stopped"
done

echo ""
ok "Done"
echo ""
