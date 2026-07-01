#!/usr/bin/env bash
# scripts/check-prereqs.sh
# Verify all required tools are installed and print their versions.
# Run before 'task up' to confirm the environment is ready.
# Does not require sudo.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

PASS=0
FAIL=0

check_tool() {
  local name="$1"
  local version_cmd="$2"

  if command -v "${name}" &>/dev/null; then
    VERSION=$(eval "${version_cmd}" 2>/dev/null | head -1 || echo "version unknown")
    ok "${name}  —  ${VERSION}"
    PASS=$((PASS + 1))
  else
    err "${name}  —  NOT FOUND"
    FAIL=$((FAIL + 1))
  fi
}

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Prerequisite Check"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

check_tool "docker"    "docker --version"
check_tool "kubectl"   "kubectl version --client --short 2>/dev/null || kubectl version --client"
check_tool "k3d"       "k3d version | head -1"
check_tool "helm"      "helm version --short"
check_tool "helmfile"  "helmfile version 2>/dev/null | head -1"
check_tool "task"      "task --version"
check_tool "curl"      "curl --version | head -1"
check_tool "python3"   "python3 --version"
check_tool "envsubst"  "envsubst --version | head -1"
check_tool "openssl"   "openssl version"

echo ""
echo "── Hardware ─────────────────────────────────────"
# Minimums to bring the FULL stack up: crAPI alone is ~10 services (Postgres,
# MongoDB, ChromaDB, identity, community, workshop, chatbot, web, gateway,
# MailHog) on top of the platform (Cilium, cert-manager, Argo CD) plus the
# host-side registry and Gitea. Below these the lab may still start, but pods
# can stay Pending or get OOM-killed — hence warnings, not hard failures.
MIN_CPU=4;    REC_CPU=8
MIN_MEM_GB=8; REC_MEM_GB=16
MIN_DISK_GB=40

CPU_CORES=$(nproc 2>/dev/null || echo 0)
if [ "${CPU_CORES}" -ge "${REC_CPU}" ]; then
  ok "CPU  —  ${CPU_CORES} cores  (min ${MIN_CPU}, recommended ${REC_CPU})"
  PASS=$((PASS + 1))
elif [ "${CPU_CORES}" -ge "${MIN_CPU}" ]; then
  warn "CPU  —  ${CPU_CORES} cores  (meets min ${MIN_CPU}, recommended ${REC_CPU})"
  PASS=$((PASS + 1))
else
  warn "CPU  —  ${CPU_CORES} cores  (below minimum ${MIN_CPU}; crAPI may not schedule)"
fi

# MemTotal is in kB and reads a little under nominal RAM; +0.5 rounds to nearest GB.
MEM_GB=$(awk '/^MemTotal:/ {printf "%d", ($2/1024/1024)+0.5}' /proc/meminfo 2>/dev/null || echo 0)
if [ "${MEM_GB}" -ge "${REC_MEM_GB}" ]; then
  ok "Memory  —  ${MEM_GB} GB  (min ${MIN_MEM_GB}, recommended ${REC_MEM_GB})"
  PASS=$((PASS + 1))
elif [ "${MEM_GB}" -ge "${MIN_MEM_GB}" ]; then
  warn "Memory  —  ${MEM_GB} GB  (meets min ${MIN_MEM_GB}, recommended ${REC_MEM_GB})"
  PASS=$((PASS + 1))
else
  warn "Memory  —  ${MEM_GB} GB  (below minimum ${MIN_MEM_GB} GB; expect OOM-kills)"
fi

# Free space on the filesystem backing Docker (images + volumes live here).
DISK_TARGET=/var/lib/docker; [ -d "${DISK_TARGET}" ] || DISK_TARGET=/
DISK_GB=$(df -Pk "${DISK_TARGET}" 2>/dev/null | awk 'NR==2 {printf "%d", $4/1024/1024}')
DISK_GB=${DISK_GB:-0}
if [ "${DISK_GB}" -ge "${MIN_DISK_GB}" ]; then
  ok "Disk  —  ${DISK_GB} GB free on ${DISK_TARGET}  (min ${MIN_DISK_GB})"
  PASS=$((PASS + 1))
else
  warn "Disk  —  ${DISK_GB} GB free on ${DISK_TARGET}  (below minimum ${MIN_DISK_GB} GB)"
fi

echo ""
echo "── Docker daemon ────────────────────────────────"
if docker info &>/dev/null; then
  ok "Docker daemon is running"
  PASS=$((PASS + 1))
else
  err "Docker daemon is not running (try: sudo systemctl start docker)"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "── helm-diff plugin ─────────────────────────────"
if helm plugin list 2>/dev/null | grep -q diff; then
  ok "helm-diff installed"
  PASS=$((PASS + 1))
else
  err "helm-diff NOT installed  (run: helm plugin install https://github.com/databus23/helm-diff)"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "── lab.env ──────────────────────────────────────"
REPO_DIR="$(dirname "${SCRIPT_DIR}")"
if [ -f "${REPO_DIR}/lab.env" ]; then
  ok "lab.env exists"
  PASS=$((PASS + 1))
else
  err "lab.env not found  (run: cp lab.env.example lab.env)"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "── lab.secrets ──────────────────────────────────"
if [ -f "${REPO_DIR}/lab.secrets" ]; then
  ok "lab.secrets exists"
  PASS=$((PASS + 1))
else
  warn "lab.secrets not found  (run: cp lab.secrets.example lab.secrets)"
  warn "  Required before adding NGINX Plus or BIG-IP credentials"
  # Not a hard failure — secrets are optional until those modules are used
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ "${FAIL}" -eq 0 ]; then
  ok "All ${PASS} checks passed — environment is ready"
  echo ""
  echo "  Next: task registry:setup && task up"
else
  err "${FAIL} check(s) failed"
  echo ""
  echo "  Run: sudo bash scripts/install-prereqs.sh"
fi
echo ""
