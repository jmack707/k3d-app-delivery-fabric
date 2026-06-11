#!/usr/bin/env bash
# scripts/crapi-chart-update.sh
# Download the OWASP crAPI Helm chart from upstream and vendor it into
# apps/crapi/chart/. Review the diff with `git diff apps/crapi/chart/`
# before committing.
#
# Usage:
#   bash scripts/crapi-chart-update.sh           # fetches main (default)
#   CRAPI_REF=develop bash scripts/crapi-chart-update.sh
#   CRAPI_REF=v1.4.0  bash scripts/crapi-chart-update.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "${SCRIPT_DIR}")"
source "${SCRIPT_DIR}/lib.sh"

CRAPI_REF="${CRAPI_REF:-main}"
CHART_DIR="${REPO_DIR}/apps/crapi/chart"
VERSION_FILE="${REPO_DIR}/apps/crapi/CHART_VERSION"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  crAPI Chart Update"
echo "  Source: github.com/OWASP/crAPI@${CRAPI_REF}"
echo "  Target: apps/crapi/chart/"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

TMP_DIR=$(mktemp -d /tmp/crapi-chart-XXXXXX)
trap "rm -rf ${TMP_DIR}" EXIT

info "Downloading source archive..."
curl -fsSL \
  "https://github.com/OWASP/crAPI/archive/refs/heads/${CRAPI_REF}.tar.gz" \
  -o "${TMP_DIR}/crapi.tar.gz" 2>/dev/null \
  || curl -fsSL \
      "https://github.com/OWASP/crAPI/archive/refs/tags/${CRAPI_REF}.tar.gz" \
      -o "${TMP_DIR}/crapi.tar.gz"

info "Extracting..."
tar -xzf "${TMP_DIR}/crapi.tar.gz" -C "${TMP_DIR}"

# Locate the extracted directory (named crAPI-<ref>)
EXTRACTED=$(find "${TMP_DIR}" -maxdepth 1 -type d -name 'crAPI-*' | head -1)
if [ -z "${EXTRACTED}" ] || [ ! -d "${EXTRACTED}/deploy/helm" ]; then
  err "Could not find deploy/helm in the downloaded archive"
  exit 1
fi

# Capture the commit SHA for the version pin
COMMIT_SHA=$(curl -fsSL \
  "https://api.github.com/repos/OWASP/crAPI/commits/${CRAPI_REF}" \
  | python3 -c "import sys, json; print(json.load(sys.stdin)['sha'][:12])" \
  2>/dev/null || echo "unknown")

# Replace the vendored chart
info "Replacing ${CHART_DIR}..."
rm -rf "${CHART_DIR}"
mkdir -p "${CHART_DIR}"
cp -r "${EXTRACTED}/deploy/helm/." "${CHART_DIR}/"

# Record what we pulled
cat > "${VERSION_FILE}" <<EOF
# crAPI chart version pin — vendored from upstream
# Updated: $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Source:  github.com/OWASP/crAPI
# Ref:     ${CRAPI_REF}
# SHA:     ${COMMIT_SHA}
EOF

ok "Chart vendored: ${CHART_DIR}"
ok "Version pin:   ${VERSION_FILE}"
echo ""
echo "  Next: review the diff and commit"
echo "    git status apps/crapi/"
echo "    git diff apps/crapi/CHART_VERSION"
echo "    git diff --stat apps/crapi/chart/"
echo ""
echo "  Then redeploy:"
echo "    APP=crapi task apps:down"
echo "    APP=crapi task apps:up"
echo ""
