#!/usr/bin/env bash
# Bring the gke-ephemeral example up.
# Idempotent: re-running it converges to the declared state.
#
# Reads .env.local for everything personal (PROJECT_ID, hostnames, OAuth client,
# passwords). No personal value lives in any tracked file.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_load_env.sh
source "${SCRIPT_DIR}/_load_env.sh"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_tool tofu

log "tofu apply"
"${SCRIPT_DIR}/_tofu.sh" app apply -input=false -auto-approve

log "configure kubectl context"
kube_ctx_for_cluster

log "done. helm releases:"
if ! helm list -A; then
  warn "helm list failed; if kubectl reports gke-gcloud-auth-plugin missing, run ./scripts/bootstrap.sh or install google-cloud-sdk-gke-gcloud-auth-plugin locally."
fi
