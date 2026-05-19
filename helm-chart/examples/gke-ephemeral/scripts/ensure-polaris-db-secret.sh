#!/usr/bin/env bash
# Ensure the out-of-band Secret required by the Polaris Postgres pod exists.
# Safe to re-run. If the Secret is absent and POLARIS_DB_PASSWORD is unset, a
# random password is generated once and stored in-cluster.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_load_env.sh
source "${SCRIPT_DIR}/_load_env.sh"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

[ "${ENABLE_POLARIS:-false}" = "true" ] || exit 0

require_tool kubectl

POLARIS_NAMESPACE="${POLARIS_NAMESPACE:-polaris}"
POLARIS_DB_SECRET_NAME="${POLARIS_DB_SECRET_NAME:-polaris-db}"

if kubectl -n "${POLARIS_NAMESPACE}" get secret "${POLARIS_DB_SECRET_NAME}" >/dev/null 2>&1; then
  log "Polaris DB secret already present: ${POLARIS_NAMESPACE}/${POLARIS_DB_SECRET_NAME}"
  exit 0
fi

password="${POLARIS_DB_PASSWORD:-}"
if [ -z "${password}" ]; then
  password="$(head -c 24 /dev/urandom | base64 | tr -d '\n')"
  warn "POLARIS_DB_PASSWORD unset; generated a random password for ${POLARIS_NAMESPACE}/${POLARIS_DB_SECRET_NAME}"
fi

log "create Polaris DB secret: ${POLARIS_NAMESPACE}/${POLARIS_DB_SECRET_NAME}"
kubectl -n "${POLARIS_NAMESPACE}" create secret generic "${POLARIS_DB_SECRET_NAME}" \
  --from-literal=password="${password}"
