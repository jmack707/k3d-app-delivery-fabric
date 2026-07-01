#!/usr/bin/env bash
# scripts/install-prereqs.sh
# Install all prerequisites for k3d-app-delivery-fabric.
# Supports Debian/Ubuntu (apt) and RHEL-family (Rocky, AlmaLinux, RHEL, CentOS
# Stream, Fedora — dnf/yum). Run once with sudo:
#   sudo bash scripts/install-prereqs.sh
#
# Installs: Docker, kubectl, k3d, Helm, Helmfile, helm-diff, Task
set -euo pipefail

# Ensure /usr/local/bin is on PATH. We install kubectl, k3d, Helm, Helmfile and
# Task there, but RHEL-family sudo uses a restrictive secure_path
# (/sbin:/bin:/usr/sbin:/usr/bin) that omits it — so mid-run version checks and
# k3d's own installer ("Is /usr/local/bin on your $PATH?") fail. Debian/Ubuntu
# already include it; prepending is harmless there.
export PATH="/usr/local/sbin:/usr/local/bin:${PATH}"

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

# ── Distro / package-manager detection ────────────────────────────────────────
# Pick the package manager from /etc/os-release. Debian/Ubuntu use apt; the
# RHEL family (Rocky, AlmaLinux, RHEL, CentOS Stream, Fedora) uses dnf (or yum on
# older releases). PKG_MGR drives which install path the System-packages step
# takes below.
PKG_MGR=""
if command -v apt-get &>/dev/null; then
  PKG_MGR="apt"
elif command -v dnf &>/dev/null; then
  PKG_MGR="dnf"
elif command -v yum &>/dev/null; then
  PKG_MGR="yum"
fi

if [ -z "${PKG_MGR}" ]; then
  err "No supported package manager found (need apt-get, dnf, or yum)."
  err "Supported: Debian/Ubuntu and RHEL-family (Rocky, AlmaLinux, RHEL, Fedora)."
  exit 1
fi

install_system_packages() {
  case "${PKG_MGR}" in
    apt)
      # apache2-utils → htpasswd; gettext-base → envsubst
      apt-get update -qq
      apt-get install -y -qq \
        curl wget git jq python3 apache2-utils gettext-base openssl \
        apt-transport-https ca-certificates gnupg lsb-release \
        iptables net-tools
      ;;
    dnf|yum)
      # RHEL-family equivalents: httpd-tools → htpasswd; gettext → envsubst.
      # apt-transport-https / lsb-release have no dnf counterpart and aren't
      # needed here (the tool installers below fetch straight from HTTPS URLs).
      # curl is omitted deliberately: RHEL/Rocky 9 ship curl-minimal, and asking
      # dnf for 'curl' triggers a package conflict — the base curl is enough.
      "${PKG_MGR}" install -y -q \
        wget git jq python3 httpd-tools gettext openssl \
        ca-certificates gnupg2 \
        iptables net-tools
      ;;
  esac
}

header "System packages"
info "Package manager: ${PKG_MGR}"
install_system_packages
ok "System packages installed"

# ── Docker ────────────────────────────────────────────────────────────────────
# Debian/Ubuntu: the get.docker.com convenience script works as-is. RHEL-family:
# do NOT use get.docker.com — on Rocky/AlmaLinux it selects Docker's
# download.docker.com/linux/rocky repo, which currently ships no docker-ce
# package (only ~15 plugin rpms), so the install dies with "Unable to find a
# match: docker-ce". Docker's CentOS repo is the canonical, fully-populated one
# and is API-compatible with the whole RHEL 9 family, so we add that instead.
install_docker_apt() {
  curl -fsSL https://get.docker.com | sh
}

install_docker_dnf() {
  local mgr="${PKG_MGR}"   # dnf or yum
  "${mgr}" install -y -q dnf-plugins-core 2>/dev/null || "${mgr}" install -y -q yum-utils
  # config-manager is a plugin on dnf4 (Rocky 9); --add-repo writes the .repo file.
  if command -v dnf &>/dev/null; then
    dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
  else
    yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
  fi
  "${mgr}" install -y -q \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

header "Docker"
if command -v docker &>/dev/null; then
  ok "Docker already installed ($(docker --version))"
else
  case "${PKG_MGR}" in
    apt)     info "Installing Docker CE via official script..."; install_docker_apt ;;
    dnf|yum) info "Installing Docker CE from Docker's CentOS repo (RHEL-compatible)..."; install_docker_dnf ;;
  esac
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
# Must be installed as the real user — sudo helm plugin goes into root's directory.
# Pass PATH through env: `sudo -u` resets it to the restrictive secure_path, which
# on RHEL omits /usr/local/bin where helm lives (else "helm: command not found").
if sudo -u "${REAL_USER}" env "PATH=${PATH}" helm plugin list 2>/dev/null | grep -q diff; then
  ok "helm-diff already installed for ${REAL_USER}"
else
  info "Installing helm-diff for ${REAL_USER}..."
  sudo -u "${REAL_USER}" env "PATH=${PATH}" helm plugin install https://github.com/databus23/helm-diff
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
