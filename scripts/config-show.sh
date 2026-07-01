#!/usr/bin/env bash
# scripts/config-show.sh
# One place to answer "how is this lab configured, and where is Argo CD actually
# pulling GitOps from?" — surfacing values that otherwise hide in lab.env, the
# bootstrap banner, or `kubectl get application -o yaml`.
#
# It prints three views and flags drift between them:
#   1. lab.env as written (the raw ARGOCD_* values, empty or not)
#   2. the RESOLVED source (what 'task argocd:bootstrap' would use — same logic)
#   3. the LIVE root Application (what Argo CD is really reconciling right now)
# Read-only. Does not require the cluster to be up (the live section is skipped
# with a hint if it isn't).
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"; lab_bootstrap

ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
ROOT_APP="k3d-app-delivery-fabric-root"

# Capture lab.env's raw ARGOCD_* values BEFORE resolution rewrites them.
RAW_REPO_URL="${ARGOCD_REPO_URL:-}"
RAW_REVISION="${ARGOCD_TARGET_REVISION:-}"

banner "Lab Configuration"

echo "  Host / infra (lab.env):"
echo "    LAB_HOST_IP        ${LAB_HOST_IP:-<unset>}"
echo "    LAB_DOMAIN         ${LAB_DOMAIN:-lab.local}"
echo "    CNI                ${CNI:-cilium}"
echo "    LAB_PROFILE        ${LAB_PROFILE:-mixed}"
echo "    INGRESS_KIND       ${INGRESS_KIND:-none}"
echo ""

echo "  GitOps source — lab.env as written:"
echo "    ARGOCD_REPO_URL          ${RAW_REPO_URL:-<empty → auto-resolve>}"
echo "    ARGOCD_TARGET_REVISION   ${RAW_REVISION:-<empty → current git branch>}"
echo ""

# What bootstrap would actually use (explicit > Gitea > origin).
resolve_argocd_source
echo "  GitOps source — resolved (what 'task argocd:bootstrap' will apply):"
echo "    Repo URL     ${ARGOCD_REPO_URL:-<none — set ARGOCD_REPO_URL in lab.env>}"
echo "    Revision     ${ARGOCD_TARGET_REVISION}"
echo "    Comes from   ${ARGOCD_SOURCE_ORIGIN:-<none>}"
echo "    Kind         $(argocd_source_kind "${ARGOCD_REPO_URL}")"
echo ""

# Gitea host container (the recommended, no-auth source).
GITEA_NAME="${GITEA_NAME:-k3d-app-delivery-fabric-gitea}"
GITEA_HTTP_PORT="${GITEA_HTTP_PORT:-3000}"
GITEA_ADMIN_USER="${GITEA_ADMIN_USER:-giteaadmin}"
GITEA_REPO="${GITEA_REPO:-k3d-app-delivery-fabric}"
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "${GITEA_NAME}"; then
  ok "Gitea running → http://${LAB_HOST_IP:-127.0.0.1}:${GITEA_HTTP_PORT}/${GITEA_ADMIN_USER}/${GITEA_REPO}"
else
  warn "Gitea container not running (start it with: task gitea:setup)"
fi
echo ""

# Ground truth: what the live root Application is set to, and whether it matches.
echo "  GitOps source — live Argo CD root Application:"
if ! kubectl get nodes &>/dev/null; then
  warn "Cluster not reachable — skipping live check (run: task up)"
elif kubectl get application "${ROOT_APP}" -n "${ARGOCD_NAMESPACE}" &>/dev/null; then
  live_url=$(kubectl get application "${ROOT_APP}" -n "${ARGOCD_NAMESPACE}" -o jsonpath='{.spec.source.repoURL}' 2>/dev/null)
  live_rev=$(kubectl get application "${ROOT_APP}" -n "${ARGOCD_NAMESPACE}" -o jsonpath='{.spec.source.targetRevision}' 2>/dev/null)
  live_sync=$(kubectl get application "${ROOT_APP}" -n "${ARGOCD_NAMESPACE}" -o jsonpath='{.status.sync.status}' 2>/dev/null)
  echo "    Repo URL     ${live_url}"
  echo "    Revision     ${live_rev}"
  echo "    Sync         ${live_sync:-Unknown}"
  if [ "${live_url}" = "${ARGOCD_REPO_URL}" ] && [ "${live_rev}" = "${ARGOCD_TARGET_REVISION}" ]; then
    ok "Live source matches your resolved lab.env config."
  else
    warn "Live source DIFFERS from resolved lab.env above."
    warn "Re-apply lab.env with:  task argocd:bootstrap && task argocd:wait"
  fi
else
  warn "Root Application '${ROOT_APP}' not found (run: task argocd:bootstrap)"
fi
echo ""
