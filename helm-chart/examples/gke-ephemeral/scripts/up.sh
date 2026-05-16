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

log "tofu init"
( cd "${TF_APP_DIR}" && tofu init -input=false -upgrade=false )

log "tofu apply"
( cd "${TF_APP_DIR}" && tofu apply -input=false -auto-approve )

log "configure kubectl context"
kube_ctx_for_cluster

log "done. helm releases:"
helm list -A
