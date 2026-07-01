#!/usr/bin/env bash
# scripts/create-cluster.sh
# Create the k3d cluster with no Klipper LoadBalancer.
# Binds the NodePort range to LAB_HOST_IP so external clients can reach apps.
# CNI installation is handled separately by install-cni.sh.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"; lab_bootstrap

CLUSTER_NAME="${CLUSTER_NAME:-k3d-app-delivery-fabric}"
LAB_HOST_IP="${LAB_HOST_IP:?LAB_HOST_IP not set in lab.env}"
REGISTRY_PORT="${REGISTRY_PORT:-5000}"

# ── Idempotency: skip creation if the cluster already exists ──────────────────
# Makes 'task up' re-runnable / converging — the later steps (CNI, cert-manager,
# Argo CD) are all idempotent. Rebuild from scratch with 'task reset'.
if k3d cluster list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "${CLUSTER_NAME}"; then
  ok "Cluster '${CLUSTER_NAME}' already exists — skipping creation"
  echo "  Rebuild from scratch:  task reset   (or 'task down' first)"
  exit 0
fi

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

# ── Network mode: bridge (default) vs ipvlan (nodes on the LAN) ───────────────
LAB_NET_MODE="${LAB_NET_MODE:-bridge}"
NODEPORT_ARGS=()

if [ "${LAB_NET_MODE}" = "bridge" ]; then
  # NodePort range bindings — publish a band of NodePorts to LAB_HOST_IP once,
  # instead of per-app ports. Any app NodePort (assigned in lab-apps/values.yaml)
  # in these ranges is reachable on LAB_HOST_IP with no rebuild.
  NODEPORT_RANGES="${NODEPORT_RANGES:-30080-30099 30440-30459}"
  port_in_ranges() {
    local port="$1" ranges="$2" r lo hi
    for r in ${ranges}; do
      lo="${r%-*}"; hi="${r#*-}"
      [ "${port}" -ge "${lo}" ] && [ "${port}" -le "${hi}" ] && return 0
    done
    return 1
  }
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
elif [ "${LAB_NET_MODE}" = "ipvlan" ]; then
  : "${LAB_NET_RANGE:?set LAB_NET_RANGE in lab.env for ipvlan mode}"
  info "Network mode: ipvlan — nodes get LAN IPs from ${LAB_NET_RANGE} (no host port-publish)"
else
  err "Invalid LAB_NET_MODE '${LAB_NET_MODE}'. Valid: bridge | ipvlan"
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

# How nodes reach the host registry: host.k3d.internal on bridge, shim IP on ipvlan.
HOST_INTERNAL="$(cluster_host_addr)"
cat > "${REGISTRY_CONFIG_FILE}" <<REGEOF
mirrors:
  "127.0.0.1:${REGISTRY_PORT}":
    endpoint:
      - "http://${HOST_INTERNAL}:${REGISTRY_PORT}"
  "${LAB_HOST_IP}:${REGISTRY_PORT}":
    endpoint:
      - "http://${HOST_INTERNAL}:${REGISTRY_PORT}"
REGEOF

# ── ipvlan network + host shim (ipvlan mode only) ─────────────────────────────
LAB_NET_NAME="${CLUSTER_NAME}-lan"
SHIM_IF="k3dshim0"
if [ "${LAB_NET_MODE}" = "ipvlan" ]; then
  PARENT="${LAB_NET_PARENT:-${LAB_IFACE}}"
  : "${LAB_NET_SUBNET:?set LAB_NET_SUBNET in lab.env}"
  : "${LAB_NET_GATEWAY:?set LAB_NET_GATEWAY in lab.env}"
  : "${LAB_NET_SHIM_IP:?set LAB_NET_SHIM_IP in lab.env}"

  if ! docker network inspect "${LAB_NET_NAME}" >/dev/null 2>&1; then
    info "Creating ipvlan L2 network '${LAB_NET_NAME}' on parent ${PARENT}..."
    docker network create -d ipvlan \
      -o ipvlan_mode=l2 -o parent="${PARENT}" \
      --subnet "${LAB_NET_SUBNET}" \
      --gateway "${LAB_NET_GATEWAY}" \
      --ip-range "${LAB_NET_RANGE}" \
      "${LAB_NET_NAME}"
    ok "ipvlan network created"
  else
    ok "ipvlan network '${LAB_NET_NAME}' already exists"
  fi

  # Host shim so the parent host can talk to its own ipvlan children (kubectl, the
  # registry mirror, Gitea). NOT persistent across reboots — see
  # docs/troubleshooting.md to make it survive a reboot.
  if ! ip link show "${SHIM_IF}" >/dev/null 2>&1; then
    info "Creating host shim ${SHIM_IF} (${LAB_NET_SHIM_IP}) for node↔host traffic..."
    sudo ip link add "${SHIM_IF}" link "${PARENT}" type ipvlan mode l2
    sudo ip addr add "${LAB_NET_SHIM_IP}/32" dev "${SHIM_IF}"
    sudo ip link set "${SHIM_IF}" up
  else
    ok "Host shim ${SHIM_IF} already present"
  fi
  sudo ip route replace "${LAB_NET_RANGE}" dev "${SHIM_IF}"
fi

# ── Create cluster ────────────────────────────────────────────────────────────
info "Creating k3d cluster (no k3s ServiceLB/Traefik, no default CNI)..."

K3D_COMMON=(
  --servers 1
  --agents "${LAB_AGENTS:-2}"
  --k3s-arg "--disable=traefik@server:0"
  --k3s-arg "--disable=servicelb@server:0"
  --k3s-arg "--flannel-backend=none@server:0"
  --k3s-arg "--disable-network-policy@server:0"
  --registry-config "${REGISTRY_CONFIG_FILE}"
  --wait
  --timeout 120s
)

if [ "${LAB_NET_MODE}" = "ipvlan" ]; then
  # Nodes join the LAN network; no k3d LB and no host port-publish (unsupported on
  # ipvlan). Each node's only IP is its LAN IP, so k3s advertises that as the node
  # InternalIP — exactly what an external CIS/BIG-IP needs.
  k3d cluster create "${CLUSTER_NAME}" \
    "${K3D_COMMON[@]}" \
    --network "${LAB_NET_NAME}" \
    --no-lb
else
  k3d cluster create "${CLUSTER_NAME}" \
    "${K3D_COMMON[@]}" \
    "${NODEPORT_ARGS[@]}"
fi

# ── ipvlan: point kubeconfig at the server's LAN IP (reachable via the shim) ───
# On ipvlan, Docker can't publish the API port to the host, so fix the kubeconfig
# server to the server node's LAN IP. k3s cert SANs include the node IP so TLS
# still validates, and the shim route makes it reachable.
if [ "${LAB_NET_MODE}" = "ipvlan" ]; then
  SERVER_IP="$(docker inspect -f \
    "{{(index .NetworkSettings.Networks \"${LAB_NET_NAME}\").IPAddress}}" \
    "k3d-${CLUSTER_NAME}-server-0" 2>/dev/null)"
  if [ -n "${SERVER_IP}" ]; then
    info "Pointing kubeconfig at server LAN IP ${SERVER_IP}:6443 (via shim)..."
    kubectl config set-cluster "k3d-${CLUSTER_NAME}" \
      --server="https://${SERVER_IP}:6443" >/dev/null
  else
    warn "Could not read server LAN IP — kubectl may not reach the API."
  fi
fi

# ── Verify ────────────────────────────────────────────────────────────────────
info "Verifying cluster nodes..."
kubectl get nodes

# ── iptables DOCKER-USER rule (bridge only) ───────────────────────────────────
# Lets traffic entering on the LAN interface be forwarded to bridge-network
# containers, so an external device can route to the node IPs. Not needed on
# ipvlan, where the nodes already sit on the LAN.
if [ "${LAB_NET_MODE}" = "bridge" ]; then
  info "Adding iptables DOCKER-USER FORWARD rule for ${LAB_IFACE}..."
  if ! sudo iptables -C DOCKER-USER -i "${LAB_IFACE}" -j ACCEPT 2>/dev/null; then
    sudo iptables -I DOCKER-USER -i "${LAB_IFACE}" -j ACCEPT
    ok "iptables rule added (interface: ${LAB_IFACE})"
  else
    ok "iptables rule already present (interface: ${LAB_IFACE})"
  fi
fi

echo ""
ok "Cluster '${CLUSTER_NAME}' created — ${LAB_AGENTS:-2} agents"
echo ""
echo "  Next: task cni:install"
echo ""
