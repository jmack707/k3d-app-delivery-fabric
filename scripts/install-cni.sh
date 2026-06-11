#!/usr/bin/env bash
# scripts/install-cni.sh
# Install the CNI specified by CNI= in lab.env.
# Supported: calico | cilium
# Called automatically by 'task up' after cluster creation.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"; lab_bootstrap

CNI="${CNI:-cilium}"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  CNI Install: ${CNI}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

case "${CNI}" in
  calico)
    bash "${SCRIPT_DIR}/install-calico.sh"
    ;;
  cilium)
    bash "${SCRIPT_DIR}/install-cilium.sh"
    ;;
  *)
    err "Unknown CNI '${CNI}'. Valid values: calico | cilium"
    err "Set CNI= in lab.env and run 'task reset'"
    exit 1
    ;;
esac
