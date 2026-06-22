#!/usr/bin/env bash
# scripts/create-cluster.sh
# Create the k3d cluster with no Klipper LoadBalancer.
# Binds the NodePort range to LAB_HOST_IP so external clients can reach apps.
# CNI installation is handled separately by install-cni.sh.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"; lab_bootstrap

CLUSTER_NAME="${CLUSTER_NAME:-cni-net-lab}"
LAB_HOST_IP="${LAB_HOST_IP:?LAB_HOST_IP not set in lab.env}"
REGISTRY_PORT="${REGISTRY_PORT:-5000}"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Create Cluster: ${CLUSTER_NAME}"
echo "  CNI:            ${CNI:-cilium} (installed post-cluster)"
echo "  Host IP:        ${LAB_HOST_IP}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── Pre-flight: host IP ───────────────────────────────────────────────────────
if ! ip addr show | grep -q "${LAB_HOST_IP}"; then
  err "LAB_HOST_IP ${LAB_HOST_IP} is not assigned to any local interface"
  err "Update lab.env: ip route get 1.1.1.1 | grep -oP 'src \\K[\\d.]+'"
  exit 1
fi

# ── Pre-flight: detect NIC interface name from LAB_HOST_IP ───────────────────
# Avoids hardcoding ens18 — works with eth0, enp3s0, ens3, etc.
LAB_IFACE=$(ip -o addr show | awk -v ip="${LAB_HOST_IP}" '$4 ~ ip {print $2; exit}')
if [ -z "${LAB_IFACE}" ]; then
  err "Could not determine network interface for ${LAB_HOST_IP}"
  exit 1
fi
info "Host interface: ${LAB_IFACE}"

# ── NodePort range bindings ───────────────────────────────────────────────────
# Publish a band of NodePorts to the host once, instead of per-app ports. Any
# app NodePort (assigned in argocd/lab-apps/values.yaml) that falls within these
# ranges is reachable on LAB_HOST_IP with no cluster rebuild — so adding or
# repointing an app no longer needs 'task reset'. The app→port mapping lives in
# Gitea (lab-apps), not here.
NODEPORT_RANGES="${NODEPORT_RANGES:-30080-30099 30440-30459}"

# port_in_ranges <port> "<lo-hi> <lo-hi> ..."  → 0 if port falls in any range.
port_in_ranges() {
  local port="$1" ranges="$2" r lo hi
  for r in ${ranges}; do
    lo="${r%-*}"; hi="${r#*-}"
    if [ "${port}" -ge "${lo}" ] && [ "${port}" -le "${hi}" ]; then
      return 0
    fi
  done
  return 1
}

NODEPORT_ARGS=()
for range in ${NODEPORT_RANGES}; do
  NODEPORT_ARGS+=(--port "${LAB_HOST_IP}:${range}:${range}@loadbalancer")
done
info "Publishing NodePort ranges: ${NODEPORT_RANGES}"

# The Argo CD UI NodePort must fall within the published ranges to be reachable.
ARGOCD_HTTP_PORT="${ARGOCD_HTTP_PORT:-30090}"
if ! port_in_ranges "${ARGOCD_HTTP_PORT}" "${NODEPORT_RANGES}"; then
  err "ARGOCD_HTTP_PORT ${ARGOCD_HTTP_PORT} is outside NODEPORT_RANGES (${NODEPORT_RANGES})"
  err "Widen NODEPORT_RANGES in lab.env, or move ARGOCD_HTTP_PORT into a range."
  exit 1
fi

# ── Registry check (advisory only) ───────────────────────────────────────────
# Registry is independent — cluster creation does not require it.
if ! curl -sf "http://127.0.0.1:${REGISTRY_PORT}/v2/" &>/dev/null; then
  warn "Registry not running — pods will pull images from the public internet"
  info "Run 'task registry:setup' then 'task registry:cache' to enable local pulls"
fi

# ── Registry mirror config for k3d nodes ─────────────────────────────────────
REGISTRY_CONFIG_FILE=$(mktemp /tmp/k3d-registry-XXXXXX.yaml)
trap "rm -f ${REGISTRY_CONFIG_FILE}" EXIT

cat > "${REGISTRY_CONFIG_FILE}" <<REGEOF
mirrors:
  "127.0.0.1:${REGISTRY_PORT}":
    endpoint:
      - "http://host.k3d.internal:${REGISTRY_PORT}"
  "${LAB_HOST_IP}:${REGISTRY_PORT}":
    endpoint:
      - "http://host.k3d.internal:${REGISTRY_PORT}"
REGEOF

# ── Create cluster ────────────────────────────────────────────────────────────
info "Creating k3d cluster (k3d proxy LB, no k3s ServiceLB/Traefik, no default CNI)..."

k3d cluster create "${CLUSTER_NAME}" \
  --servers 1 \
  --agents "${LAB_AGENTS:-2}" \
  --k3s-arg "--disable=traefik@server:0" \
  --k3s-arg "--disable=servicelb@server:0" \
  --k3s-arg "--flannel-backend=none@server:0" \
  --k3s-arg "--disable-network-policy@server:0" \
  "${NODEPORT_ARGS[@]}" \
  --registry-config "${REGISTRY_CONFIG_FILE}" \
  --wait \
  --timeout 120s

# ── Verify ────────────────────────────────────────────────────────────────────
info "Verifying cluster nodes..."
kubectl get nodes

# ── iptables DOCKER-USER rule ─────────────────────────────────────────────────
# Allows traffic entering on the LAN interface to be forwarded to cluster
# containers. Uses the detected interface name — not a hardcoded value.
info "Adding iptables DOCKER-USER FORWARD rule for ${LAB_IFACE}..."
if ! sudo iptables -C DOCKER-USER -i "${LAB_IFACE}" -j ACCEPT 2>/dev/null; then
  sudo iptables -I DOCKER-USER -i "${LAB_IFACE}" -j ACCEPT
  ok "iptables rule added (interface: ${LAB_IFACE})"
else
  ok "iptables rule already present (interface: ${LAB_IFACE})"
fi

echo ""
ok "Cluster '${CLUSTER_NAME}' created — ${LAB_AGENTS:-2} agents"
echo ""
echo "  Next: task cni:install"
echo ""
