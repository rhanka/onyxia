#!/usr/bin/env bash
# Thin wrapper around tofu that:
#   1. ensures the GCS state bucket exists,
#   2. runs `tofu init` with the right backend-config for the given layer,
#   3. forwards the rest to tofu.
#
# Usage:
#   ./_tofu.sh <layer> <tofu args...>
# Example:
#   ./_tofu.sh app apply -input=false -auto-approve
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_load_env.sh
source "${SCRIPT_DIR}/_load_env.sh"

LAYER="${1:?usage: ./_tofu.sh <base|cluster|app> <tofu args...>}"
shift
LAYER_DIR="${EXAMPLE_DIR}/terraform/${LAYER}"
[ -d "${LAYER_DIR}" ] || { echo "ERROR: no terraform/${LAYER}" >&2; exit 2; }

# Create the state bucket on demand (idempotent).
if ! gcloud storage buckets describe "gs://${ONYXIA_TFSTATE_BUCKET}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  echo "[tofu] creating GCS state bucket gs://${ONYXIA_TFSTATE_BUCKET}"
  gcloud storage buckets create "gs://${ONYXIA_TFSTATE_BUCKET}" \
    --project="${PROJECT_ID}" --location="${REGION}" --uniform-bucket-level-access >/dev/null
  gcloud storage buckets update "gs://${ONYXIA_TFSTATE_BUCKET}" --versioning >/dev/null
fi

cd "${LAYER_DIR}"
tofu init -input=false -upgrade=false -reconfigure \
  -backend-config="bucket=${ONYXIA_TFSTATE_BUCKET}" \
  -backend-config="prefix=${LAYER}" >/dev/null

exec tofu "$@"
