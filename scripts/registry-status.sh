#!/usr/bin/env bash
# scripts/registry-status.sh
# Show registry container state, uptime, image/tag count, and disk usage.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"; lab_bootstrap

NAME="${REGISTRY_NAME:-cni-lab-registry}"
PORT="${REGISTRY_PORT:-5000}"
BASE="http://127.0.0.1:${PORT}"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Registry Status"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Container state
if docker ps --format '{{.Names}}' | grep -q "^${NAME}$"; then
  UPTIME=$(docker inspect --format '{{.State.StartedAt}}' "${NAME}" 2>/dev/null || echo "unknown")
  STATUS=$(docker inspect --format '{{.State.Status}}' "${NAME}" 2>/dev/null || echo "unknown")
  ok "Container: ${NAME}  [${STATUS}]"
  echo "  Started:   ${UPTIME}"
elif docker ps -a --format '{{.Names}}' | grep -q "^${NAME}$"; then
  warn "Container '${NAME}' exists but is stopped"
  echo "  Start with: task registry:setup"
  echo ""
  exit 0
else
  err "Container '${NAME}' does not exist"
  echo "  Create with: task registry:setup"
  echo ""
  exit 0
fi

echo ""

# API reachability
if curl -sf "${BASE}/v2/" &>/dev/null; then
  ok "API reachable at ${BASE}"
  ok "API reachable at http://${LAB_HOST_IP}:${PORT}"
else
  err "API not responding at ${BASE}"
  echo ""
  exit 1
fi

echo ""

# Image / tag counts
REPO_COUNT=0
TAG_COUNT=0
REPOS=$(curl -sf "${BASE}/v2/_catalog" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for r in data.get('repositories', []):
    print(r)
" 2>/dev/null || true)

if [ -n "${REPOS}" ]; then
  while IFS= read -r repo; do
    [ -z "$repo" ] && continue
    REPO_COUNT=$((REPO_COUNT + 1))
    TAGS=$(curl -sf "${BASE}/v2/${repo}/tags/list" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(len(data.get('tags') or []))
" 2>/dev/null || echo 0)
    TAG_COUNT=$((TAG_COUNT + TAGS))
  done <<< "${REPOS}"
fi

echo "  Repositories: ${REPO_COUNT}"
echo "  Tags:         ${TAG_COUNT}"

# Volume disk usage
VOL_SIZE=$(docker system df -v 2>/dev/null \
  | awk -v name="${NAME}-data" '$0 ~ name {print $4}' || echo "unknown")
echo "  Volume size:  ${VOL_SIZE:-unknown}"

echo ""
echo "  task registry:ls     — full image listing"
echo "  task registry:cache  — pull and cache all lab images"
echo "  task registry:flush  — delete all images"
echo ""
