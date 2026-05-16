#!/usr/bin/env bash
# Shared helpers for up.sh / down.sh / status.sh.
# Sourced, not executed directly.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXAMPLE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TF_APP_DIR="${EXAMPLE_DIR}/terraform/app"

# Values come from .env.local via _load_env.sh sourced beforehand.
PROJECT_ID="${PROJECT_ID:-}"
REGION="${REGION:-us-central1}"
CLUSTER_NAME="${CLUSTER_NAME:-onyxia-test}"

color() { printf '\033[0;%sm%s\033[0m\n' "$1" "$2"; }
log()   { color 36 "[$(basename "$0")] $*"; }
warn()  { color 33 "[$(basename "$0")] WARN: $*" >&2; }
err()   { color 31 "[$(basename "$0")] ERROR: $*" >&2; }

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    err "missing required tool: $1 (run ./scripts/bootstrap.sh first)"
    exit 1
  fi
}

kube_ctx_for_cluster() {
  require_tool gcloud
  require_tool kubectl
  gcloud container clusters get-credentials "${CLUSTER_NAME}" \
    --project "${PROJECT_ID}" \
    --location "${REGION}" >/dev/null 2>&1
}
