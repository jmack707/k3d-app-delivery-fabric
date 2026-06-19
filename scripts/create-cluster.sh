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
LAB_APPS="${LAB_APPS:-crapi juiceshop dvga vampi}"

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

# ── Pre-flight: verify all active app NodePorts are configured ────────────────
NODEPORT_ARGS=()
MISSING_PORTS=()

for app in ${LAB_APPS}; do
  HTTP_PORT=$(app_http_port "${app}")
  HTTPS_PORT=$(app_https_port "${app}")

  if [ -z "${HTTP_PORT}" ]; then
    MISSING_PORTS+=("${app} HTTP port")
  else
    NODEPORT_ARGS+=(--port "${LAB_HOST_IP}:${HTTP_PORT}:${HTTP_PORT}@loadbalancer")
  fi

  if [ -z "${HTTPS_PORT}" ]; then
    MISSING_PORTS+=("${app} HTTPS port")
  else
    NODEPORT_ARGS+=(--port "${LAB_HOST_IP}:${HTTPS_PORT}:${HTTPS_PORT}@loadbalancer")
  fi
done

if [ "${#MISSING_PORTS[@]}" -gt 0 ]; then
  err "Missing NodePort config for: ${MISSING_PORTS[*]}"
  err "Check *_HTTP_PORT and *_HTTPS_PORT entries in lab.env"
  exit 1
fi

# ── Argo CD UI NodePort (GitOps control plane) ────────────────────────────────
# Always bound — Argo CD manages every app, so its UI is part of the lab.
ARGOCD_HTTP_PORT="${ARGOCD_HTTP_PORT:-30090}"
NODEPORT_ARGS+=(--port "${LAB_HOST_IP}:${ARGOCD_HTTP_PORT}:${ARGOCD_HTTP_PORT}@loadbalancer")

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
