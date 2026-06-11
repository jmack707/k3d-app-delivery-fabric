#!/usr/bin/env bash
# scripts/registry-ls.sh
# List all repositories and their tags stored in the local registry.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"; lab_bootstrap

REGISTRY_PORT="${REGISTRY_PORT:-5000}"
REGISTRY_NAME="${REGISTRY_NAME:-cni-lab-registry}"
BASE="http://127.0.0.1:${REGISTRY_PORT}"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Registry Contents — ${LAB_HOST_IP}:${REGISTRY_PORT}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Check registry is running
if ! curl -sf "${BASE}/v2/" &>/dev/null; then
  err "Registry not reachable at ${BASE}. Run: task registry:setup"
  exit 1
fi

# Get catalog
CATALOG=$(curl -sf "${BASE}/v2/_catalog" | python3 -c "
import sys, json
data = json.load(sys.stdin)
repos = data.get('repositories', [])
for r in repos:
    print(r)
")

if [ -z "${CATALOG}" ]; then
  warn "Registry is empty — no images pushed yet"
  echo ""
  echo "  Push images with:  task registry:cache"
  echo ""
  exit 0
fi

TOTAL_REPOS=0
TOTAL_TAGS=0

while IFS= read -r repo; do
  [ -z "$repo" ] && continue
  TOTAL_REPOS=$((TOTAL_REPOS + 1))

  # Get tags for this repo
  TAGS=$(curl -sf "${BASE}/v2/${repo}/tags/list" 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
tags = data.get('tags') or []
print(' '.join(sorted(tags)))
" 2>/dev/null || echo "")

  TAG_COUNT=$(echo "$TAGS" | wc -w)
  TOTAL_TAGS=$((TOTAL_TAGS + TAG_COUNT))

  printf "  %-55s  [%s]\n" "${repo}" "${TAGS}"
done <<< "${CATALOG}"

echo ""
echo "  ${TOTAL_REPOS} repositories, ${TOTAL_TAGS} tags total"
echo ""
