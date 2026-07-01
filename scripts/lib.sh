#!/usr/bin/env bash
# scripts/lib.sh
# Shared helpers and the single app-metadata table. Sourced by every script.
#
# To add a new app: add one row to the APP_META table below and create
# apps/<app>/ with its manifests. Nothing else needs touching.

# ── Output helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

ok()   { echo -e "${GREEN}  ✓ $*${NC}"; }
info() { echo -e "${CYAN}  → $*${NC}"; }
warn() { echo -e "${YELLOW}  ⚠ $*${NC}"; }
err()  { echo -e "${RED}  ✗ $*${NC}" >&2; }

# Print a titled banner box. Usage: banner "App Up: crapi"
banner() {
  local line="━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "${line}"
  # Support multi-line titles passed as separate args
  local arg
  for arg in "$@"; do
    echo "  ${arg}"
  done
  echo "${line}"
}

# ── App metadata table ────────────────────────────────────────────────────────
# Static, descriptive metadata the cluster can't tell us. Fields are
# pipe-separated:
#
#   namespace | service_name | display_name | ready_timeout | extra_test_paths
#
# service_name is also the Deployment name in this lab. Ports and Service type
# are NOT here — they're read live from the cluster (Gitea/Argo CD is the source
# of truth for which apps deploy and how they're exposed). extra_test_paths is a
# comma-separated list of extra URL paths to smoke test (beyond "/"); empty if none.
declare -A APP_META=(
  [crapi]="crapi|crapi-web|crAPI|240|"
  [juiceshop]="juice-shop|juice-shop|Juice Shop|120|"
  [dvga]="dvga|dvga|DVGA|120|"
  [vampi]="vampi|vampi|VAmPI|60|/ui/"
)

# Space-separated list of every known app (table keys, in a stable order).
VALID_APPS="crapi juiceshop dvga vampi"

# _app_field <app> <field-index>  — internal: pull one pipe-delimited field.
_app_field() {
  local app="$1" idx="$2" row="${APP_META[$1]:-}"
  if [ -z "${row}" ]; then
    err "_app_field: unknown app '${app}'"
    return 1
  fi
  echo "${row}" | cut -d'|' -f"${idx}"
}

app_namespace()    { _app_field "$1" 1; }
app_service_name() { _app_field "$1" 2; }   # also the Deployment name
app_deploy_name()  { _app_field "$1" 2; }
app_display_name() { _app_field "$1" 3; }
app_ready_timeout(){ _app_field "$1" 4; }
app_test_paths()   { _app_field "$1" 5; }   # may be empty

# ── Cluster-derived app state (Gitea/Argo is the source of truth) ─────────────
# deployed_apps — known apps that Argo CD currently has an Application for.
deployed_apps() {
  local argo a out=""
  argo=$(kubectl get applications -n "${ARGOCD_NAMESPACE:-argocd}" \
           -o jsonpath='{.items[*].metadata.name}' 2>/dev/null) || return 0
  for a in ${argo}; do
    app_in_list "${a}" "${VALID_APPS}" && out="${out} ${a}"
  done
  echo "${out# }"
}

# app_service_type <app> — live Service type (ClusterIP/NodePort); empty if absent.
app_service_type() {
  local ns svc
  ns=$(app_namespace "$1") && svc=$(app_service_name "$1") || return 1
  kubectl get svc "${svc}" -n "${ns}" -o jsonpath='{.spec.type}' 2>/dev/null
}

# app_node_port <app> http|https — the published NodePort for that scheme, or
# empty (ClusterIP, or that scheme not exposed). TLS ports are matched by name
# (https/ssl) or port number (443/8443), so it works for both the raw-app charts
# and crAPI's web Service.
app_node_port() {
  local app="$1" scheme="$2" ns svc
  ns=$(app_namespace "${app}") && svc=$(app_service_name "${app}") || return 1
  kubectl get svc "${svc}" -n "${ns}" -o json 2>/dev/null | python3 -c '
import sys, json
scheme = sys.argv[1]
try:
    ports = json.load(sys.stdin).get("spec", {}).get("ports", [])
except Exception:
    sys.exit(0)
def is_tls(p):
    n = (p.get("name") or "").lower()
    return ("ssl" in n) or ("https" in n) or p.get("port") in (443, 8443)
for p in ports:
    if (scheme == "https") == is_tls(p) and p.get("nodePort"):
        print(p["nodePort"]); break
' "${scheme}"
}

# ── App-list helpers ──────────────────────────────────────────────────────────
# Return 0 if $1 is a whitespace-separated word in list $2.
app_in_list() {
  local needle="$1" item
  for item in $2; do
    [ "${item}" = "${needle}" ] && return 0
  done
  return 1
}

# Validate an app name against the table; exit on error.
require_valid_app() {
  if ! app_in_list "$1" "${VALID_APPS}"; then
    err "Unknown app '$1'. Valid: ${VALID_APPS}"
    exit 1
  fi
}

# ── lab.env / lab.secrets loading ─────────────────────────────────────────────
# Safely parse lab.env (and lab.secrets if present) without shell eval, so
# JWT tokens, passwords, and special characters survive intact.
load_lab_env() {
  local env_file="$1"
  local secrets_file="$(dirname "${env_file}")/lab.secrets"

  if [ ! -f "${env_file}" ]; then
    err "${env_file} not found — copy lab.env.example to lab.env and edit it"
    exit 1
  fi

  _parse_env() {
    local file="$1" line key value
    while IFS= read -r line || [ -n "${line}" ]; do
      [[ "${line}" =~ ^[[:space:]]*# ]] && continue   # comment
      [[ -z "${line// }" ]]            && continue   # blank
      key="${line%%=*}"
      value="${line#*=}"
      value="${value%%#*}"                                  # strip inline comment
      value="${value#"${value%%[![:space:]]*}"}"            # ltrim
      value="${value%"${value##*[![:space:]]}"}"            # rtrim
      [[ "${value}" =~ ^\'(.*)\'$ ]] && value="${BASH_REMATCH[1]}"  # unquote '...'
      [[ "${value}" =~ ^\"(.*)\"$ ]] && value="${BASH_REMATCH[1]}"  # unquote "..."
      export "${key}=${value}" 2>/dev/null || true
    done < "${file}"
  }

  _parse_env "${env_file}"
  [ -f "${secrets_file}" ] && _parse_env "${secrets_file}"

  # Derived hostnames (one per app)
  export CRAPI_HOST="crapi.${LAB_DOMAIN:-lab.local}"
  export JUICESHOP_HOST="juiceshop.${LAB_DOMAIN:-lab.local}"
  export DVGA_HOST="dvga.${LAB_DOMAIN:-lab.local}"
  export VAMPI_HOST="vampi.${LAB_DOMAIN:-lab.local}"

  # Registry address used in image refs
  export REGISTRY="${LAB_HOST_IP:-127.0.0.1}:${REGISTRY_PORT:-5000}"

  # Exposure profile selector (which argocd/lab-apps/profiles/<name>.yaml the
  # root app layers on). The app set and per-app exposure live entirely in Gitea;
  # 'task health'/'test' read the live cluster, so no app lists are needed here.
  export LAB_PROFILE="${LAB_PROFILE:-mixed}"

  # Network mode: bridge (default) or ipvlan (nodes directly on the LAN).
  export LAB_NET_MODE="${LAB_NET_MODE:-bridge}"

  validate_lab_host_ip
}

# ── Network-mode address helpers ──────────────────────────────────────────────
# cluster_host_addr — the address the CLUSTER (nodes/pods) uses to reach host-side
# services (the local registry mirror, Gitea). On the default bridge that is k3d's
# injected host.k3d.internal. Under ipvlan the parent NIC is isolated from its own
# containers, so nodes reach the host via the shim IP instead.
cluster_host_addr() {
  if [ "${LAB_NET_MODE:-bridge}" = "ipvlan" ]; then
    echo "${LAB_NET_SHIM_IP:-172.16.20.250}"
  else
    echo "host.k3d.internal"
  fi
}

# app_access_host — the address the HOST uses to reach app NodePorts. Bridge
# publishes them on LAB_HOST_IP; under ipvlan there is no host publish, so use a
# live node IP (reachable via the shim route). Falls back to LAB_HOST_IP when the
# cluster isn't up yet or no node IP can be read.
app_access_host() {
  if [ "${LAB_NET_MODE:-bridge}" = "ipvlan" ]; then
    local nip
    nip=$(kubectl get nodes \
      -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' \
      2>/dev/null)
    echo "${nip:-${LAB_HOST_IP}}"
  else
    echo "${LAB_HOST_IP}"
  fi
}

# ── LAB_HOST_IP preflight ─────────────────────────────────────────────────────
# Fail fast if LAB_HOST_IP isn't an address this host can actually bind. A stale
# or mistyped value (new DHCP lease, fat-fingered octet) otherwise surfaces as a
# cryptic "cannot assign requested address" from docker/k3d deep into setup.
validate_lab_host_ip() {
  local ip="${LAB_HOST_IP:-}"
  case "${ip}" in
    ""|0.0.0.0|127.0.0.1|localhost) return 0 ;;   # wildcard/loopback/unset: nothing to check
  esac
  [[ "${ip}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 0   # only validate IPv4 literals

  local have
  if command -v ip >/dev/null 2>&1; then
    have="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1)"
  else
    have="$(hostname -I 2>/dev/null | tr ' ' '\n')"
  fi

  if ! printf '%s\n' "${have}" | grep -qx "${ip}"; then
    err "LAB_HOST_IP=${ip} is not assigned to any interface on this host."
    err "Current global IPv4 address(es): ${have//$'\n'/ }"
    err "Update LAB_HOST_IP in lab.env to one of them, then re-run."
    exit 1
  fi
}

# ── Gitea admin-user preflight ────────────────────────────────────────────────
# Gitea reserves a set of names for its own top-level routes (/admin, /api, ...).
# "admin" is the common trap: creating it fails, repo create then 401s, and the
# push hits a repo that never got made. Reject the reserved names up front with
# the fix. Called only by the Gitea scripts, so non-Gitea workflows are unaffected.
validate_gitea_admin_user() {
  local user="${GITEA_ADMIN_USER:-giteaadmin}"
  case "${user}" in
    admin|api|assets|attachments|avatars|user|org|repo|explore|issues|pulls|\
login|new|raw|help|install|ghost|milestones|notifications|stars|search)
      err "GITEA_ADMIN_USER=${user} is reserved by Gitea and cannot be created."
      err "Set GITEA_ADMIN_USER to something else (e.g. giteaadmin) in lab.env."
      exit 1
      ;;
  esac
}

# ── Bootstrap ─────────────────────────────────────────────────────────────────
# Standard preamble for scripts: resolve dirs and load config in one call.
# Sets SCRIPT_DIR and REPO_DIR in the caller's scope.
# Usage (first lines of a script, after sourcing lib.sh is implicit here):
#   source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"; lab_bootstrap
lab_bootstrap() {
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
  REPO_DIR="$(dirname "${SCRIPT_DIR}")"
  load_lab_env "${REPO_DIR}/lab.env"
}

# ── Argo CD GitOps source resolution ──────────────────────────────────────────
# Resolve which repo/revision Argo CD should reconcile from, so 'task config'
# and 'task argocd:bootstrap' always agree (one implementation, no drift). Sets
# and exports:
#   ARGOCD_REPO_URL         the resolved repo URL ("" if it can't be determined)
#   ARGOCD_TARGET_REVISION  the resolved branch/revision
#   ARGOCD_SOURCE_ORIGIN    a human label for WHERE the URL came from
# Priority (matches the original bootstrap logic):
#   1. explicit ARGOCD_REPO_URL in lab.env
#   2. a running self-hosted Gitea container serving the lab repo (no auth)
#   3. the git 'origin' remote of this checkout
# Requires REPO_DIR (set by lab_bootstrap).
resolve_argocd_source() {
  ARGOCD_REPO_URL="${ARGOCD_REPO_URL:-}"
  ARGOCD_SOURCE_ORIGIN=""

  if [ -n "${ARGOCD_REPO_URL}" ]; then
    ARGOCD_SOURCE_ORIGIN="lab.env (ARGOCD_REPO_URL)"
  else
    local _gitea_name="${GITEA_NAME:-k3d-app-delivery-fabric-gitea}"
    local _gitea_port="${GITEA_HTTP_PORT:-3000}"
    local _gitea_user="${GITEA_ADMIN_USER:-giteaadmin}"
    local _gitea_repo="${GITEA_REPO:-k3d-app-delivery-fabric}"
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "${_gitea_name}" \
       && curl -sf "http://127.0.0.1:${_gitea_port}/api/v1/repos/${_gitea_user}/${_gitea_repo}" >/dev/null 2>&1; then
      ARGOCD_REPO_URL="http://$(cluster_host_addr):${_gitea_port}/${_gitea_user}/${_gitea_repo}.git"
      ARGOCD_SOURCE_ORIGIN="auto-detected Gitea container"
    fi
  fi

  if [ -z "${ARGOCD_REPO_URL}" ]; then
    ARGOCD_REPO_URL="$(git -C "${REPO_DIR}" remote get-url origin 2>/dev/null || true)"
    [ -n "${ARGOCD_REPO_URL}" ] && ARGOCD_SOURCE_ORIGIN="git remote 'origin'"
  fi

  ARGOCD_TARGET_REVISION="${ARGOCD_TARGET_REVISION:-}"
  if [ -z "${ARGOCD_TARGET_REVISION}" ]; then
    ARGOCD_TARGET_REVISION="$(git -C "${REPO_DIR}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"
  fi

  export ARGOCD_REPO_URL ARGOCD_TARGET_REVISION ARGOCD_SOURCE_ORIGIN
}

# Classify a repo URL into a short, human label (Gitea / GitHub / other) so the
# config view can say what auth, if any, is expected.
argocd_source_kind() {
  case "$1" in
    http://host.k3d.internal:*|http://*:[0-9]*/*) echo "self-hosted Gitea (public HTTP, no auth needed)" ;;
    https://github.com/*)                         echo "GitHub (needs ARGOCD_REPO_PASSWORD if the repo is private)" ;;
    http://*|https://*)                           echo "other Git host" ;;
    "")                                           echo "unresolved" ;;
    *)                                            echo "other" ;;
  esac
}

# ── Cluster helpers ───────────────────────────────────────────────────────────
# Exit with a clear message if the cluster isn't reachable.
require_cluster() {
  if ! kubectl get nodes &>/dev/null; then
    err "Cluster not reachable. Run: task up"
    exit 1
  fi
}

# Poll a URL until it answers or <timeout> seconds elapse.
# Usage: wait_for_url <url> [timeout=30] [label]
wait_for_url() {
  local url="$1" timeout="${2:-30}" label="${3:-$1}" elapsed=0
  while [ "${elapsed}" -lt "${timeout}" ]; do
    curl -sf --max-time 2 "${url}" &>/dev/null && return 0
    sleep 1
    elapsed=$((elapsed + 1))
  done
  err "${label} did not become ready after ${timeout}s"
  return 1
}
