#!/usr/bin/env bash
# Bootstrap the Polaris catalog `onyxia` (Section 4 of the implementation plan
# in docs/superpowers/plans/2026-05-16-iceberg-polaris-plan.md). Idempotent:
# safe to re-run after a Polaris restart, after a Postgres restore, or on
# every `mode=resume` of the GHA workflow.
#
# Required env:
#   POLARIS_HOSTNAME      Public hostname Polaris is served on
#                         (e.g. polaris.onyxia.example.com).
#   KEYCLOAK_HOSTNAME     Public hostname Keycloak is served on (used to mint
#                         a service-account access token for Polaris admin).
#   POLARIS_ADMIN_TOKEN   Optional. A pre-minted bearer token with
#                         CATALOG_MANAGE_METADATA privilege. When empty,
#                         this script tries client_credentials on the
#                         `polaris` Keycloak client (POLARIS_CLIENT_SECRET).
#   POLARIS_CLIENT_SECRET Confidential client secret for the Keycloak
#                         `polaris` client. Required when POLARIS_ADMIN_TOKEN
#                         is empty.
#   POLARIS_NAMESPACE     Default: polaris. Used to resolve the fallback
#                         Kubernetes Secret containing the client secret.
#   POLARIS_CLIENT_SECRET_NAME Default: polaris-client
#
# Storage wiring — Section 4 stub. When ENABLE_POLARIS_STORAGE=true, also pass:
#   POLARIS_WAREHOUSE_BUCKET     e.g. <project>-onyxia-warehouse (no gs://)
#   POLARIS_WAREHOUSE_GSA_EMAIL  GCP service account Polaris impersonates to
#                                vend STS tokens against the bucket.
#
# Without storage, the catalog is created with storageType=FILE so the rest
# of the stack (auth, ingress, OIDC) can still be smoke-tested in isolation.
set -euo pipefail

err() { echo "ERROR: $*" >&2; exit 2; }

CATALOG_NAME="${POLARIS_CATALOG_NAME:-onyxia}"
POLARIS_NAMESPACE="${POLARIS_NAMESPACE:-polaris}"
POLARIS_CLIENT_SECRET_NAME="${POLARIS_CLIENT_SECRET_NAME:-polaris-client}"

[ -n "${POLARIS_HOSTNAME:-}"  ] || err "set POLARIS_HOSTNAME (e.g. polaris.onyxia.example.com)"
[ -n "${KEYCLOAK_HOSTNAME:-}" ] || err "set KEYCLOAK_HOSTNAME"

# Resolve the admin bearer token.
if [ -z "${POLARIS_ADMIN_TOKEN:-}" ]; then
  if [ -z "${POLARIS_CLIENT_SECRET:-}" ] && command -v kubectl >/dev/null 2>&1; then
    POLARIS_CLIENT_SECRET="$(
      kubectl -n "${POLARIS_NAMESPACE}" get secret "${POLARIS_CLIENT_SECRET_NAME}" \
        -o jsonpath='{.data.client-secret}' 2>/dev/null | base64 -d || true
    )"
  fi
  [ -n "${POLARIS_CLIENT_SECRET:-}" ] || \
    err "set POLARIS_ADMIN_TOKEN, POLARIS_CLIENT_SECRET, or create Secret ${POLARIS_NAMESPACE}/${POLARIS_CLIENT_SECRET_NAME}"
  echo "[polaris-init] minting admin token via client_credentials..."
  POLARIS_ADMIN_TOKEN="$(
    curl -sfS -X POST \
      "https://${KEYCLOAK_HOSTNAME}/realms/onyxia/protocol/openid-connect/token" \
      -d "grant_type=client_credentials" \
      -d "client_id=polaris" \
      -d "client_secret=${POLARIS_CLIENT_SECRET}" \
    | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p'
  )"
  [ -n "${POLARIS_ADMIN_TOKEN}" ] || err "could not parse access_token from token endpoint"
fi

POLARIS_URL="https://${POLARIS_HOSTNAME}/api/management/v1"

echo "[polaris-init] check if catalog '${CATALOG_NAME}' already exists..."
HTTP_CODE=$(
  curl -sS -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer ${POLARIS_ADMIN_TOKEN}" \
    "${POLARIS_URL}/catalogs/${CATALOG_NAME}"
)
if [ "${HTTP_CODE}" = "200" ]; then
  echo "[polaris-init] catalog '${CATALOG_NAME}' already exists, nothing to do"
  exit 0
fi
if [ "${HTTP_CODE}" != "404" ]; then
  err "unexpected HTTP ${HTTP_CODE} from GET ${POLARIS_URL}/catalogs/${CATALOG_NAME}"
fi

# Build the storage-config-info payload. With storage stubbed, fall back to
# storageType=FILE under /tmp so the Polaris pod can still serve a catalog
# (useful for keycloak + ingress smoke tests).
if [ "${ENABLE_POLARIS_STORAGE:-false}" = "true" ]; then
  [ -n "${POLARIS_WAREHOUSE_BUCKET:-}"    ] || err "set POLARIS_WAREHOUSE_BUCKET when ENABLE_POLARIS_STORAGE=true"
  [ -n "${POLARIS_WAREHOUSE_GSA_EMAIL:-}" ] || err "set POLARIS_WAREHOUSE_GSA_EMAIL when ENABLE_POLARIS_STORAGE=true"
  STORAGE_JSON=$(cat <<JSON
{
  "storageType": "GCS",
  "gcsServiceAccount": "${POLARIS_WAREHOUSE_GSA_EMAIL}",
  "allowedLocations": ["gs://${POLARIS_WAREHOUSE_BUCKET}/"]
}
JSON
)
  DEFAULT_BASE_LOCATION="gs://${POLARIS_WAREHOUSE_BUCKET}/"
else
  echo "[polaris-init] WARN: ENABLE_POLARIS_STORAGE=false → falling back to storageType=FILE (stub)" >&2
  STORAGE_JSON='{"storageType":"FILE","allowedLocations":["file:///tmp/polaris/"]}'
  DEFAULT_BASE_LOCATION="file:///tmp/polaris/"
fi

PAYLOAD=$(cat <<JSON
{
  "catalog": {
    "type": "INTERNAL",
    "name": "${CATALOG_NAME}",
    "properties": {
      "default-base-location": "${DEFAULT_BASE_LOCATION}",
      "credential-vending-enabled": "true"
    },
    "storageConfigInfo": ${STORAGE_JSON}
  }
}
JSON
)

echo "[polaris-init] POST /catalogs (create '${CATALOG_NAME}')..."
RESP=$(
  curl -sS -X POST \
    -H "Authorization: Bearer ${POLARIS_ADMIN_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "${PAYLOAD}" \
    -w "\nHTTP_CODE=%{http_code}" \
    "${POLARIS_URL}/catalogs"
)
CODE=$(echo "${RESP}" | sed -n 's/^HTTP_CODE=//p')
case "${CODE}" in
  2*)
    echo "[polaris-init] catalog '${CATALOG_NAME}' created"
    ;;
  409)
    echo "[polaris-init] catalog '${CATALOG_NAME}' already exists (race), continuing"
    ;;
  *)
    echo "${RESP}" >&2
    err "POST /catalogs returned HTTP ${CODE}"
    ;;
esac

echo "[polaris-init] done. Polaris config endpoint:"
curl -s --max-time 10 "https://${POLARIS_HOSTNAME}/api/catalog/v1/config" | head -c 200 || true
echo
