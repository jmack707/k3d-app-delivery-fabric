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
# One row per app. Fields are pipe-separated:
#
#   namespace | http_port_var:default | https_port_var:default | deploy_name | display_name | ready_timeout | extra_test_paths
#
# extra_test_paths is a comma-separated list of additional URL paths to smoke
# test (beyond "/"). Empty if none.
declare -A APP_META=(
  [crapi]="crapi|CRAPI_HTTP_PORT:30080|CRAPI_HTTPS_PORT:30443|crapi-web|crAPI|240|"
  [juiceshop]="juice-shop|JUICESHOP_HTTP_PORT:30081|JUICESHOP_HTTPS_PORT:30444|juice-shop|Juice Shop|120|"
  [dvga]="dvga|DVGA_HTTP_PORT:30082|DVGA_HTTPS_PORT:30445|dvga|DVGA|120|"
  [vampi]="vampi|VAMPI_HTTP_PORT:30083|VAMPI_HTTPS_PORT:30446|vampi|VAmPI|60|/ui/"
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

# _resolve_port "VAR:default"  — internal: echo $VAR if set, else the default.
_resolve_port() {
  local spec="$1" var="${1%%:*}" def="${1##*:}"
  echo "${!var:-$def}"
}

app_namespace()   { _app_field "$1" 1; }
app_http_port()   { _resolve_port "$(_app_field "$1" 2)"; }
app_https_port()  { _resolve_port "$(_app_field "$1" 3)"; }
app_deploy_name() { _app_field "$1" 4; }
app_display_name(){ _app_field "$1" 5; }
app_ready_timeout(){ _app_field "$1" 6; }
app_test_paths()  { _app_field "$1" 7; }   # may be empty

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

  # Common defaults so callers don't each repeat the fallback
  export LAB_APPS="${LAB_APPS:-${VALID_APPS}}"
  export HTTPS_APPS="${HTTPS_APPS:-}"
  export CLUSTERIP_APPS="${CLUSTERIP_APPS:-}"
}

# Resolve an app's Service type from CLUSTERIP_APPS.
# Apps listed in CLUSTERIP_APPS get ClusterIP; everything else gets NodePort.
# Echoes "ClusterIP" or "NodePort".
app_service_type() {
  if app_in_list "$1" "${CLUSTERIP_APPS:-}"; then
    echo "ClusterIP"
  else
    echo "NodePort"
  fi
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
