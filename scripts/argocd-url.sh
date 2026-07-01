#!/usr/bin/env bash
# scripts/argocd-url.sh
# Print the Argo CD UI URL and login hint from lab.env.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"; lab_bootstrap

echo ""
echo "  Argo CD UI → http://$(app_access_host):${ARGOCD_HTTP_PORT:-30090}"
echo "  Username:   admin"
echo "  Password:   task argocd:password"
echo ""
