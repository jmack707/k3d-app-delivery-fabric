#!/usr/bin/env bash
# scripts/health-check.sh
# Post-deploy verification: nodes, CNI, app rollouts, NodePort reachability.
# CLUSTER_ONLY=1 skips the app and TLS checks (used by 'task cluster:only').
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"; lab_bootstrap

CNI="${CNI:-cilium}"
CLUSTER_ONLY="${CLUSTER_ONLY:-0}"
PASS=0
FAIL=0

# check <label> <command...>  — run command in a subshell; tally pass/fail.
# The subshell isolates 'eval' so a failing check can't abort the script.
check() {
  local label="$1" cmd="$2"
  if ( eval "${cmd}" &>/dev/null ); then
    ok "${label}"; PASS=$((PASS + 1))
  else
    err "${label}"; FAIL=$((FAIL + 1))
  fi
}

if [ "${CLUSTER_ONLY}" = "1" ]; then
  banner "Health Check (cluster + CNI only)"
else
  banner "Health Check"
fi

echo ""
echo "── Cluster ──────────────────────────────────────"
check "kubectl reachable" "kubectl get nodes"
check "all nodes Ready"   "kubectl wait --for=condition=Ready nodes --all --timeout=10s"

echo ""
echo "── CNI (${CNI}) ──────────────────────────────────"
case "${CNI}" in
  calico)
    check "calico-node DaemonSet running" "kubectl get ds -n calico-system calico-node"
    ;;
  cilium)
    check "cilium DaemonSet running"      "kubectl get ds -n kube-system cilium"
    check "hubble-relay Deployment running" "kubectl get deploy -n kube-system hubble-relay"
    ;;
esac

if [ "${CLUSTER_ONLY}" = "1" ]; then
  echo ""
  info "Cluster-only mode — skipping app and TLS checks"
  echo ""
  echo "  Deploy apps later with:  task argocd:install && task argocd:bootstrap"
  echo "  Full lab with apps:      task up"
else
  echo ""
  echo "── Apps ─────────────────────────────────────────"
  for app in ${LAB_APPS}; do
    ns=$(app_namespace "${app}")
    deploy=$(app_deploy_name "${app}")
    port=$(app_http_port "${app}")

    check "${app}: namespace exists" \
      "kubectl get ns ${ns}"
    check "${app}: deployment rollout complete" \
      "kubectl rollout status deploy/${deploy} -n ${ns} --timeout=30s"

    # NodePort reachability only applies to NodePort services.
    if [ "$(app_service_type "${app}")" = "ClusterIP" ]; then
      info "${app}: ClusterIP — host reachability check skipped"
    else
      check "${app}: NodePort reachable (http://${LAB_HOST_IP}:${port})" \
        "curl -sf --max-time 10 http://${LAB_HOST_IP}:${port} -o /dev/null"
    fi
  done

  if [ -n "${HTTPS_APPS}" ]; then
    echo ""
    echo "── TLS / cert-manager ───────────────────────────"
    check "cert-manager deployment ready" \
      "kubectl rollout status deploy/cert-manager -n cert-manager --timeout=10s"
    check "ClusterIssuer local-ca exists" \
      "kubectl get clusterissuer local-ca"
  fi
fi

banner ""
if [ "${FAIL}" -eq 0 ]; then
  ok "All ${PASS} checks passed"
else
  err "${FAIL} check(s) failed, ${PASS} passed"
  echo ""
  echo "  Troubleshoot:"
  echo "    kubectl get pods -A | grep -v Running"
  echo "    task cni:status"
  exit 1
fi
echo ""
