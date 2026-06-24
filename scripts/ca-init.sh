#!/usr/bin/env bash
# scripts/ca-init.sh
# Create a local root CA (once). Skips if root_ca.crt already exists.
# The CA is used by cert-manager to issue TLS certs for apps with tls enabled.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"; lab_bootstrap

CA_CERT="${REPO_DIR}/root_ca.crt"
CA_KEY="${REPO_DIR}/root_ca.key"

if [ -f "${CA_CERT}" ] && [ -f "${CA_KEY}" ]; then
  ok "Local CA already exists — skipping"
  exit 0
fi

info "Creating local root CA..."
openssl genrsa -out "${CA_KEY}" 4096 2>/dev/null
openssl req -new -x509 -days 3650 \
  -key "${CA_KEY}" \
  -out "${CA_CERT}" \
  -subj "/CN=k3d-app-delivery-fabric Root CA/O=k3d-app-delivery-fabric/C=US"

ok "Local CA created"
echo ""
echo "  ${CA_CERT}"
echo "  ${CA_KEY}"
echo ""
echo "  Install CA on your browser/OS to trust lab HTTPS endpoints."
echo "  macOS: sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ${CA_CERT}"
echo "  Ubuntu: sudo cp ${CA_CERT} /usr/local/share/ca-certificates/k3d-app-delivery-fabric.crt && sudo update-ca-certificates"
echo ""
