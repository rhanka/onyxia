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

if [ "${ENABLE_POLARIS:-false}" = "true" ]; then
  log "prepare Polaris namespace for secret bootstrap"
  "${SCRIPT_DIR}/_tofu.sh" app apply -input=false -auto-approve \
    -target='kubernetes_namespace.polaris[0]'
  "${SCRIPT_DIR}/ensure-polaris-db-secret.sh"
fi

log "tofu apply"
"${SCRIPT_DIR}/_tofu.sh" app apply -input=false -auto-approve

log "configure kubectl context"
kube_ctx_for_cluster

if [ -n "${KC_ADMIN_PASSWORD:-}" ] && [ -n "${GOOGLE_CLIENT_SECRET:-}" ]; then
  log "run keycloak-init"
  KC_ADMIN_PASSWORD="${KC_ADMIN_PASSWORD}" \
  GOOGLE_CLIENT_ID="${GOOGLE_OAUTH_CLIENT_ID}" \
  GOOGLE_CLIENT_SECRET="${GOOGLE_CLIENT_SECRET}" \
  ONYXIA_HOSTNAME="${PUBLIC_HOSTNAME}" \
  KEYCLOAK_HOSTNAME="${KEYCLOAK_HOSTNAME}" \
  ENABLE_POLARIS="${ENABLE_POLARIS:-false}" \
    "${SCRIPT_DIR}/keycloak-init.sh"
else
  warn "Skipping keycloak-init automation; export KC_ADMIN_PASSWORD and GOOGLE_CLIENT_SECRET to enable it."
fi

if [ "${ENABLE_POLARIS:-false}" = "true" ]; then
  log "run polaris-init"
  ENABLE_POLARIS_STORAGE="${ENABLE_POLARIS_STORAGE:-false}" \
  POLARIS_HOSTNAME="${POLARIS_HOSTNAME}" \
  KEYCLOAK_HOSTNAME="${KEYCLOAK_HOSTNAME}" \
  POLARIS_WAREHOUSE_BUCKET="${POLARIS_WAREHOUSE_BUCKET:-${GCS_POLARIS_WAREHOUSE_BUCKET}}" \
  POLARIS_WAREHOUSE_GSA_EMAIL="${POLARIS_WAREHOUSE_GSA_EMAIL:-polaris-warehouse@${PROJECT_ID}.iam.gserviceaccount.com}" \
    "${SCRIPT_DIR}/polaris-init.sh"
fi

log "done. helm releases:"
if ! helm list -A; then
  warn "helm list failed; if kubectl reports gke-gcloud-auth-plugin missing, run ./scripts/bootstrap.sh or install google-cloud-sdk-gke-gcloud-auth-plugin locally."
fi
