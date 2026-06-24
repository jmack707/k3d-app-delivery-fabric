#!/usr/bin/env bash
# scripts/install-prereqs.sh
# Install all prerequisites for k3d-app-delivery-fabric on Ubuntu 22.04 / 24.04.
# Run once with sudo: sudo bash scripts/install-prereqs.sh
#
# Installs: Docker, kubectl, k3d, Helm, Helmfile, helm-diff, Task
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

# Detect the real user (the one who invoked sudo)
REAL_USER="${SUDO_USER:-${USER}}"
REAL_HOME=$(getent passwd "${REAL_USER}" | cut -d: -f6)
ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')

if [ "${EUID}" -ne 0 ]; then
  err "This script must be run with sudo: sudo bash scripts/install-prereqs.sh"
  exit 1
fi

header() { echo ""; echo "━━━  $*  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; }

header "System packages"
apt-get update -qq
apt-get install -y -qq \
  curl wget git jq python3 apache2-utils \
  apt-transport-https ca-certificates gnupg lsb-release \
  iptables net-tools
ok "System packages installed"

# ── Docker ────────────────────────────────────────────────────────────────────
header "Docker"
if command -v docker &>/dev/null; then
  ok "Docker already installed ($(docker --version))"
else
  info "Installing Docker CE via official script..."
  curl -fsSL https://get.docker.com | sh
  # Add the real user to the docker group so sudo isn't needed for docker commands
  usermod -aG docker "${REAL_USER}"
  # Enable and start the daemon
  systemctl enable docker
  systemctl start docker
  ok "Docker installed ($(docker --version))"
  warn "Log out and back in (or run 'newgrp docker') for group membership to take effect"
fi

# ── kubectl ───────────────────────────────────────────────────────────────────
header "kubectl"
if command -v kubectl &>/dev/null; then
  ok "kubectl already installed ($(kubectl version --client --short 2>/dev/null || kubectl version --client))"
else
  info "Installing latest stable kubectl..."
  K8S_VER=$(curl -fsSL https://dl.k8s.io/release/stable.txt)
  curl -fsSLo /usr/local/bin/kubectl \
    "https://dl.k8s.io/release/${K8S_VER}/bin/linux/${ARCH}/kubectl"
  chmod +x /usr/local/bin/kubectl
  ok "kubectl installed ($(kubectl version --client --short 2>/dev/null || kubectl version --client))"
fi

# ── k3d ───────────────────────────────────────────────────────────────────────
header "k3d"
K3D_VERSION="v5.7.4"
if command -v k3d &>/dev/null; then
  ok "k3d already installed ($(k3d version | head -1))"
else
  info "Installing k3d ${K3D_VERSION}..."
  curl -fsSL https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh \
    | TAG="${K3D_VERSION}" bash
  ok "k3d installed ($(k3d version | head -1))"
fi

# ── Helm ──────────────────────────────────────────────────────────────────────
header "Helm"
if command -v helm &>/dev/null; then
  ok "Helm already installed ($(helm version --short))"
else
  info "Installing Helm..."
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  ok "Helm installed ($(helm version --short))"
fi

# ── Helmfile ──────────────────────────────────────────────────────────────────
header "Helmfile"
HELMFILE_VERSION="0.162.0"
if command -v helmfile &>/dev/null; then
  ok "Helmfile already installed ($(helmfile version 2>/dev/null | head -1))"
else
  info "Installing Helmfile ${HELMFILE_VERSION}..."
  curl -fsSLo /tmp/helmfile.tar.gz \
    "https://github.com/helmfile/helmfile/releases/download/v${HELMFILE_VERSION}/helmfile_${HELMFILE_VERSION}_linux_${ARCH}.tar.gz"
  tar -xzf /tmp/helmfile.tar.gz -C /usr/local/bin helmfile
  chmod +x /usr/local/bin/helmfile
  rm /tmp/helmfile.tar.gz
  ok "Helmfile installed ($(helmfile version 2>/dev/null | head -1))"
fi

# ── helm-diff plugin ──────────────────────────────────────────────────────────
header "helm-diff plugin"
# Must be installed as the real user — sudo helm plugin goes into root's directory
if sudo -u "${REAL_USER}" helm plugin list 2>/dev/null | grep -q diff; then
  ok "helm-diff already installed for ${REAL_USER}"
else
  info "Installing helm-diff for ${REAL_USER}..."
  sudo -u "${REAL_USER}" helm plugin install https://github.com/databus23/helm-diff
  ok "helm-diff installed for ${REAL_USER}"
fi

# ── Task ──────────────────────────────────────────────────────────────────────
header "Task (taskfile.dev)"
if command -v task &>/dev/null; then
  ok "Task already installed ($(task --version))"
else
  info "Installing Task..."
  sh -c "$(curl -fsSL https://taskfile.dev/install.sh)" -- -d -b /usr/local/bin
  ok "Task installed ($(task --version))"
fi

# ── kubectl shell completion & alias ─────────────────────────────────────────
header "kubectl completion"
BASHRC="${REAL_HOME}/.bashrc"
MARKER="# >>> k3d-app-delivery-fabric kubectl completion >>>"
if ! grep -qF "${MARKER}" "${BASHRC}" 2>/dev/null; then
  cat >> "${BASHRC}" << 'BASHRC_BLOCK'

# >>> k3d-app-delivery-fabric kubectl completion >>>
source <(kubectl completion bash)
alias k=kubectl
complete -o default -F __start_kubectl k
# <<< k3d-app-delivery-fabric kubectl completion <<<
BASHRC_BLOCK
  chown "${REAL_USER}:${REAL_USER}" "${BASHRC}"
  ok "kubectl completion + 'k' alias added to ${BASHRC}"
else
  ok "kubectl completion already configured"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
ok "All prerequisites installed"
echo ""
echo "  Next steps:"
echo "    1. Log out and back in (docker group + bashrc changes)"
echo "    2. cp lab.env.example lab.env  && edit lab.env"
echo "    3. cp lab.secrets.example lab.secrets  && edit lab.secrets"
echo "    4. task registry:setup"
echo "    5. task up"
echo ""
echo "  Verify tools:  task check"
echo ""
