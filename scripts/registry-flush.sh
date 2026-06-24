#!/usr/bin/env bash
# scripts/registry-flush.sh
# Delete ALL images from the local registry, then run garbage collection
# to reclaim the blob storage.
#
# Requires REGISTRY_STORAGE_DELETE_ENABLED=true on the registry container,
# which registry-setup.sh sets automatically.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"; lab_bootstrap

REGISTRY_PORT="${REGISTRY_PORT:-5000}"
REGISTRY_NAME="${REGISTRY_NAME:-k3d-app-delivery-fabric-registry}"
BASE="http://127.0.0.1:${REGISTRY_PORT}"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Registry Flush"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
warn "This will delete ALL images from the registry."
echo ""

# Skip confirmation if FORCE=1
if [ "${FORCE:-0}" != "1" ]; then
  read -rp "  Type 'yes' to confirm: " CONFIRM
  if [ "${CONFIRM}" != "yes" ]; then
    info "Aborted"
    exit 0
  fi
fi

# Check registry is running
if ! curl -sf "${BASE}/v2/" &>/dev/null; then
  err "Registry not reachable at ${BASE}. Run: task registry:setup"
  exit 1
fi

# Get all repos
REPOS=$(curl -sf "${BASE}/v2/_catalog" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for r in data.get('repositories', []):
    print(r)
" 2>/dev/null)

if [ -z "${REPOS}" ]; then
  info "Registry is already empty"
  exit 0
fi

DELETED=0
while IFS= read -r repo; do
  [ -z "$repo" ] && continue

  # Get all tags for this repo
  TAGS=$(curl -sf "${BASE}/v2/${repo}/tags/list" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for t in (data.get('tags') or []):
    print(t)
" 2>/dev/null)

  while IFS= read -r tag; do
    [ -z "$tag" ] && continue

    # Fetch the content-addressable digest for this tag.
    # The Accept header is required — without it the registry returns a
    # schema v1 manifest whose digest does not match the stored blob.
    DIGEST=$(curl -sI \
      -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
      "${BASE}/v2/${repo}/manifests/${tag}" \
      | grep -i "^Docker-Content-Digest:" \
      | tr -d '\r' \
      | awk '{print $2}')

    if [ -z "${DIGEST}" ]; then
      warn "Could not get digest for ${repo}:${tag} — skipping"
      continue
    fi

    HTTP=$(curl -so /dev/null -w "%{http_code}" -X DELETE \
      "${BASE}/v2/${repo}/manifests/${DIGEST}")

    case "${HTTP}" in
      202)
        info "Deleted ${repo}:${tag}"
        DELETED=$((DELETED + 1))
        ;;
      405)
        err "DELETE not allowed for ${repo}:${tag} (HTTP 405)"
        err "Registry was not started with REGISTRY_STORAGE_DELETE_ENABLED=true"
        err "Run: task registry:rm && task registry:setup"
        exit 1
        ;;
      *)
        warn "DELETE returned HTTP ${HTTP} for ${repo}:${tag}"
        ;;
    esac
  done <<< "${TAGS}"
done <<< "${REPOS}"

# Run garbage collection inside the container to reclaim blob storage.
# A simple restart does NOT trigger GC — the registry daemon does not
# re-scan storage on startup.
info "Running garbage collection..."
docker exec "${REGISTRY_NAME}" \
  registry garbage-collect /etc/docker/registry/config.yml --delete-untagged

# Restart so the in-memory repository index is cleared
info "Restarting registry..."
docker restart "${REGISTRY_NAME}" >/dev/null

if wait_for_url "${BASE}/v2/" 15 "Registry"; then
  ok "Registry ready"
else
  err "Registry did not come back after restart"
  exit 1
fi

echo ""
ok "Flush complete — deleted ${DELETED} tag(s), blobs garbage-collected"
echo ""
