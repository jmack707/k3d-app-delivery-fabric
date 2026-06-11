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
