#!/usr/bin/env bash
# scripts/render-app.sh
# Render and apply manifests for a single app.
# Supports two deploy modes:
#   1. Helm chart  — when apps/<APP>/USES_HELM exists (e.g. crAPI)
#   2. Raw manifests — *.yaml in apps/<APP>/ rendered with envsubst
# Called by app-up.sh with APP, NS, TLS, REGISTRY, LAB_HOST_IP set.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"; lab_bootstrap

APP="${APP:?APP not set}"
NS="${NS:?NS not set}"
TLS="${TLS:-false}"
REGISTRY="${REGISTRY:-}"

APP_DIR="${REPO_DIR}/apps/${APP}"

if [ ! -d "${APP_DIR}" ]; then
  err "App directory not found: ${APP_DIR}"
  exit 1
fi

# Resolve NodePort values for this app
HTTP_PORT=$(app_http_port "${APP}")
HTTPS_PORT=$(app_https_port "${APP}")

export APP NS TLS REGISTRY LAB_HOST_IP LAB_DOMAIN
export HTTP_PORT HTTPS_PORT
export CRAPI_HOST JUICESHOP_HOST DVGA_HOST VAMPI_HOST

# Variable list passed to envsubst — only these get expanded, so application
# env vars in manifests/values (e.g. $SMTP_PASS) are left alone.
ENVSUBST_VARS='${NS} ${HTTP_PORT} ${HTTPS_PORT} ${LAB_HOST_IP} ${LAB_DOMAIN} ${CRAPI_HOST} ${JUICESHOP_HOST} ${DVGA_HOST} ${VAMPI_HOST}'

# Ensure namespace exists
kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f -

# ── Helm path ─────────────────────────────────────────────────────────────────
# Activated when apps/<APP>/USES_HELM is present.
# Requires apps/<APP>/chart/ (the vendored chart) and apps/<APP>/values.yaml.
if [ -f "${APP_DIR}/USES_HELM" ]; then
  CHART_DIR="${APP_DIR}/chart"
  VALUES_FILE="${APP_DIR}/values.yaml"

  if [ ! -d "${CHART_DIR}" ] || [ -z "$(ls -A "${CHART_DIR}" 2>/dev/null | grep -v README.md)" ]; then
    warn "Chart directory empty — fetching from upstream..."
    bash "${SCRIPT_DIR}/${APP}-chart-update.sh" 2>/dev/null \
      || bash "${SCRIPT_DIR}/crapi-chart-update.sh"
    if [ ! -f "${CHART_DIR}/Chart.yaml" ]; then
      err "Chart fetch failed — vendor manually with: task ${APP}:chart:update"
      exit 1
    fi
  fi

  if [ ! -f "${VALUES_FILE}" ]; then
    err "Values file not found: ${VALUES_FILE}"
    exit 1
  fi

  # Patch the values file with runtime port substitution.
  # The values file uses __HTTP_PORT__ as a placeholder rather than ${HTTP_PORT}
  # so YAML parses cleanly when checked in. We expand it here.
  RENDERED_VALUES=$(mktemp /tmp/${APP}-values-XXXXXX.yaml)
  trap "rm -f ${RENDERED_VALUES}" EXIT
  sed "s|__HTTP_PORT__|${HTTP_PORT}|g; s|__HTTPS_PORT__|${HTTPS_PORT}|g" \
    "${VALUES_FILE}" > "${RENDERED_VALUES}"

  # Build Helm flags. --wait blocks until pods are Ready; set HELM_WAIT=false
  # in lab.env to skip and let app-up.sh's own pod-readiness check handle it.
  # Default timeout is 15m — enough for crAPI's full cold start (init containers,
  # image pulls, dependency ordering through 6+ pods).
  HELM_FLAGS=(--namespace "${NS}" --values "${RENDERED_VALUES}" --timeout "${HELM_TIMEOUT:-15m}")
  if [ "${HELM_WAIT:-true}" = "true" ]; then
    HELM_FLAGS+=(--wait)
  fi

  # Honor CLUSTERIP_APPS for the chart's front-end service too.
  if [ "$(app_service_type "${APP}")" = "ClusterIP" ]; then
    HELM_FLAGS+=(--set crapiWeb.service.type=ClusterIP)
  fi

  info "Deploying ${APP} via Helm (chart: ${CHART_DIR}, wait: ${HELM_WAIT:-true}, timeout: ${HELM_TIMEOUT:-15m})..."
  helm upgrade --install "${APP}" "${CHART_DIR}" "${HELM_FLAGS[@]}"

  # cert-manager Certificate (separate from chart, applied if TLS enabled
  # and *-tls.yaml file is present)
  if [ "${TLS}" = "true" ] && [ -f "${APP_DIR}/certificate-tls.yaml" ]; then
    envsubst "${ENVSUBST_VARS}" < "${APP_DIR}/certificate-tls.yaml" | kubectl apply -f -
  fi

# ── Raw manifest path ─────────────────────────────────────────────────────────
else
  # Guard against leftover files from previous repo versions that would
  # silently sabotage the new -http/-tls split. If 'deployment.yaml' exists
  # alongside deployment-http.yaml or deployment-tls.yaml, the legacy file
  # would be applied last (alphabetically) and overwrite the new ones.
  if [ -f "${APP_DIR}/deployment.yaml" ] && \
     ( [ -f "${APP_DIR}/deployment-http.yaml" ] || [ -f "${APP_DIR}/deployment-tls.yaml" ] ); then
    err "Stale manifest detected: ${APP_DIR}/deployment.yaml"
    err "This file is from an older repo version and conflicts with"
    err "deployment-http.yaml / deployment-tls.yaml. Remove it:"
    err "  rm ${APP_DIR}/deployment.yaml"
    exit 1
  fi

  # Decide service type for this app (NodePort default, ClusterIP if listed).
  SERVICE_TYPE=$(app_service_type "${APP}")

  # When ClusterIP, strip the NodePort-specific lines from the rendered YAML:
  #   - rewrite 'type: NodePort' → 'type: ClusterIP'
  #   - delete 'nodePort: <n>' lines (invalid on a ClusterIP service)
  # Implemented as a sed filter applied just before kubectl.
  apply_manifest() {
    local file="$1"
    if [ "${SERVICE_TYPE}" = "ClusterIP" ]; then
      envsubst "${ENVSUBST_VARS}" < "${file}" \
        | sed -e 's/type: NodePort/type: ClusterIP/' -e '/^[[:space:]]*nodePort:/d' \
        | kubectl apply -f -
    else
      envsubst "${ENVSUBST_VARS}" < "${file}" | kubectl apply -f -
    fi
  }

  MANIFESTS_APPLIED=0
  for f in "${APP_DIR}"/*.yaml; do
    [ -f "$f" ] || continue
    # *-tls.yaml — only apply when TLS is on
    if [[ "$f" == *"-tls.yaml" ]] && [ "${TLS}" != "true" ]; then
      continue
    fi
    # *-http.yaml — only apply when TLS is off
    if [[ "$f" == *"-http.yaml" ]] && [ "${TLS}" = "true" ]; then
      continue
    fi
    apply_manifest "$f"
    MANIFESTS_APPLIED=$((MANIFESTS_APPLIED + 1))
  done

  if [ "${MANIFESTS_APPLIED}" -eq 0 ]; then
    warn "No manifests found in ${APP_DIR}"
  fi
fi

# Print access info (same for both paths)
echo ""
echo "  Access ${APP}:"
if [ "$(app_service_type "${APP}")" = "ClusterIP" ]; then
  echo "    ClusterIP — not exposed on ${LAB_HOST_IP}."
  echo "    Reach it in-cluster, or port-forward:"
  if [ "${TLS}" = "true" ]; then
    echo "      kubectl port-forward -n ${NS} svc/$(app_deploy_name "${APP}") ${HTTPS_PORT}:8443"
  else
    echo "      kubectl port-forward -n ${NS} svc/$(app_deploy_name "${APP}") ${HTTP_PORT}:<svc-port>"
  fi
elif [ "${TLS}" = "true" ]; then
  echo "    HTTPS: https://${LAB_HOST_IP}:${HTTPS_PORT}"
  echo "    HTTP:  http://${LAB_HOST_IP}:${HTTP_PORT}  (also available)"
else
  echo "    HTTP:  http://${LAB_HOST_IP}:${HTTP_PORT}"
fi
