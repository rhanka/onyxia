#!/usr/bin/env bash
# Source this from any script in ./scripts/ to load .env.local and export the
# right TF_VAR_* + helm-template variables. No personal value lives in any
# tracked file — everything flows from .env.local.
#
# Usage:
#   source "$(dirname "$0")/_load_env.sh"
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXAMPLE_DIR="$(cd "${_SCRIPT_DIR}/.." && pwd)"
TF_APP_DIR="${EXAMPLE_DIR}/terraform/app"
ENV_FILE="${EXAMPLE_DIR}/.env.local"

if [ ! -f "${ENV_FILE}" ]; then
  echo "ERROR: ${ENV_FILE} is missing. Run: cp .env.local.example .env.local && \$EDITOR .env.local" >&2
  exit 2
fi

# Load .env.local. Each line is KEY=VALUE; no shell evaluation, no quoting tricks.
set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

# Required vars (no passwords here — they live in Kubernetes Secrets created
# out of band; see README for the `kubectl create secret` commands).
for var in PROJECT_ID REGION CLUSTER_NAME PUBLIC_HOSTNAME LETSENCRYPT_EMAIL GOOGLE_OAUTH_CLIENT_ID KEYCLOAK_HOSTNAME; do
  if [ -z "${!var:-}" ]; then
    echo "ERROR: ${var} is not set in ${ENV_FILE}" >&2
    exit 2
  fi
done

# Convention: remote state lives in a GCS bucket per project.
export ONYXIA_TFSTATE_BUCKET="${ONYXIA_TFSTATE_BUCKET:-${PROJECT_ID}-onyxia-tfstate}"

# Map env vars to Terraform var inputs (TF_VAR_ prefix is auto-picked).
export TF_VAR_project_id="${PROJECT_ID}"
export TF_VAR_region="${REGION}"
export TF_VAR_cluster_name="${CLUSTER_NAME}"
export TF_VAR_public_hostname="${PUBLIC_HOSTNAME}"
export TF_VAR_cert_manager_letsencrypt_email="${LETSENCRYPT_EMAIL}"
export TF_VAR_oauth2_proxy_client_id="${GOOGLE_OAUTH_CLIENT_ID}"

# Build the JSON array Terraform expects for allowed emails.
_emails_json=$(printf '%s' "${GOOGLE_OAUTH_ALLOWED_EMAILS}" \
  | awk -F',' '{ printf "["; for (i=1;i<=NF;i++) printf "%s\"%s\"", (i>1?",":""), $i; printf "]"; }')
export TF_VAR_oauth2_proxy_allowed_emails="${_emails_json}"

export TF_VAR_oauth2_proxy_cookie_domain=".${PUBLIC_HOSTNAME}"
export TF_VAR_oauth2_proxy_whitelist_domains="[\".${PUBLIC_HOSTNAME}\"]"
export TF_VAR_keycloak_hostname="${KEYCLOAK_HOSTNAME}"
export TF_VAR_extra_values_files='["../../onyxia-gke-public-values.yaml","../../onyxia-private-values.local.yaml"]'

# GCS storage (STS bridge + user data bucket + Polaris warehouse bucket).
# The bridge is exposed through the existing ingress-nginx LoadBalancer; point
# STS_BRIDGE_HOSTNAME at the same IP as PUBLIC_HOSTNAME.
export GCS_DATA_BUCKET="${GCS_DATA_BUCKET:-${PROJECT_ID}-onyxia-data}"
export GCS_POLARIS_WAREHOUSE_BUCKET="${GCS_POLARIS_WAREHOUSE_BUCKET:-${PROJECT_ID}-onyxia-warehouse}"
export STS_BRIDGE_HOSTNAME="${STS_BRIDGE_HOSTNAME:-sts.${PUBLIC_HOSTNAME}}"
export TF_VAR_enable_gcs_storage="${ENABLE_GCS_STORAGE:-true}"
export TF_VAR_gcs_data_bucket_name="${GCS_DATA_BUCKET}"
export TF_VAR_gcs_polaris_warehouse_bucket_name="${GCS_POLARIS_WAREHOUSE_BUCKET}"
export TF_VAR_sts_bridge_hostname="${STS_BRIDGE_HOSTNAME}"
export TF_VAR_sts_bridge_image="${STS_BRIDGE_IMAGE:-ghcr.io/rhanka/onyxia-gcs-sts-bridge:latest}"

# Sensible defaults for the recommended Keycloak setup. Override in .env.local
# (any of these as ENABLE_*=true|false) if you want a different topology.
export TF_VAR_enable_cert_manager="${ENABLE_CERT_MANAGER:-true}"
export TF_VAR_enable_services_ingress_nginx="${ENABLE_SERVICES_INGRESS_NGINX:-true}"
export TF_VAR_enable_keycloak="${ENABLE_KEYCLOAK:-true}"
# Persist the Keycloak realm across pod restarts via a small Postgres
# in the keycloak namespace. Required for resume-after-restart to be
# truly painless.
export TF_VAR_keycloak_persist_realm="${KEYCLOAK_PERSIST_REALM:-true}"
# Disabled by default with Keycloak: the gateway + global-auth are not needed
# because Onyxia core does its own OIDC against Keycloak.
export TF_VAR_enable_oauth2_proxy_gateway="${ENABLE_OAUTH2_PROXY_GATEWAY:-false}"
export TF_VAR_services_ingress_nginx_oauth2_auth="${ENABLE_OAUTH2_GLOBAL_AUTH:-false}"

# Apache Polaris (Iceberg catalog). Off by default — see README "Lakehouse
# Iceberg via Polaris". When ENABLE_POLARIS=true, a Postgres + Polaris pod +
# Ingress land in the polaris namespace. Keep ENABLE_POLARIS_STORAGE=false
# until you actually want Polaris to vend STS access against the warehouse
# bucket created by this same workpackage.
export TF_VAR_enable_polaris="${ENABLE_POLARIS:-false}"
export TF_VAR_polaris_hostname="${POLARIS_HOSTNAME:-}"
export TF_VAR_enable_polaris_storage="${ENABLE_POLARIS_STORAGE:-false}"
export TF_VAR_polaris_warehouse_bucket="${POLARIS_WAREHOUSE_BUCKET:-${GCS_POLARIS_WAREHOUSE_BUCKET}}"
export TF_VAR_polaris_warehouse_gsa_email="${POLARIS_WAREHOUSE_GSA_EMAIL:-polaris-warehouse@${PROJECT_ID}.iam.gserviceaccount.com}"
if [ -n "${POLARIS_IMAGE:-}" ]; then
  export TF_VAR_polaris_image="${POLARIS_IMAGE}"
fi

# Generate the gitignored Onyxia values file from the committed template.
TEMPLATE="${EXAMPLE_DIR}/onyxia-private-values.local.yaml.tmpl"
TARGET="${EXAMPLE_DIR}/onyxia-private-values.local.yaml"
if [ -f "${TEMPLATE}" ]; then
  PUBLIC_HOSTNAME="${PUBLIC_HOSTNAME}" KEYCLOAK_HOSTNAME="${KEYCLOAK_HOSTNAME}" \
    envsubst '${PUBLIC_HOSTNAME} ${KEYCLOAK_HOSTNAME}' \
    < "${TEMPLATE}" > "${TARGET}"

  if [ "${ENABLE_GCS_STORAGE:-true}" = "true" ]; then
    export TARGET GCS_DATA_BUCKET STS_BRIDGE_HOSTNAME KEYCLOAK_HOSTNAME
    python3 - <<'PY'
import os, pathlib

p = pathlib.Path(os.environ["TARGET"])
text = p.read_text()
block = f"""      data:
        defaultDurationSeconds: 86400
        monitoring:
          enabled: false
        S3:
          URL: https://storage.googleapis.com
          region: auto
          pathStyleAccess: true
          workingDirectory:
            bucketMode: shared
            bucketName: {os.environ["GCS_DATA_BUCKET"]}
            prefix: user-
            prefixGroup: project-
          sts:
            URL: https://{os.environ["STS_BRIDGE_HOSTNAME"]}/
            durationSeconds: 86400
            oidcConfiguration:
              issuerUri: https://{os.environ["KEYCLOAK_HOSTNAME"]}/realms/onyxia
              clientID: onyxia"""
needle = "      data: {}"
if needle not in text:
    raise SystemExit(f"expected marker not found in {p}: {needle}")
p.write_text(text.replace(needle, block, 1))
PY
  fi
fi

# Sentropic theme (optional). When ENABLE_SENTROPIC_THEME=true, regenerate the
# palette/font/header env vars and splice them under web.env in the values file.
# Idempotent: a previous block (delimited by the markers below) is replaced.
if [ "${ENABLE_SENTROPIC_THEME:-false}" = "true" ]; then
  : "${SENTROPIC_HEADER_LOGO_URL:?Set SENTROPIC_HEADER_LOGO_URL in .env.local}"
  : "${SENTROPIC_HEADER_TEXT_BOLD:?Set SENTROPIC_HEADER_TEXT_BOLD in .env.local}"
  : "${SENTROPIC_HEADER_TEXT_FOCUS:?Set SENTROPIC_HEADER_TEXT_FOCUS in .env.local}"

  THEME_DIR="${EXAMPLE_DIR}/theme"
  (cd "${THEME_DIR}" && [ -d node_modules ] || npm ci --silent)

  FRAGMENT="$( (cd "${THEME_DIR}" && node sentropic-to-onyxia.mjs) )"
  # Indent the fragment by 4 spaces so it lands under `  env:`.
  INDENTED="$(printf '%s\n' "${FRAGMENT}" | sed 's/^/    /')"

  # Replace the existing block, or insert one after the `  env:` line.
  export TARGET INDENTED
  python3 - <<'PY'
import os, re, pathlib
p = pathlib.Path(os.environ['TARGET'])
text = p.read_text()
indented = os.environ['INDENTED']
block = "    # BEGIN SENTROPIC THEME — generated, do not edit\n" + indented + "\n    # END SENTROPIC THEME\n"
pattern = re.compile(r"    # BEGIN SENTROPIC THEME[\s\S]*?    # END SENTROPIC THEME\n", re.MULTILINE)
if pattern.search(text):
    text = pattern.sub(block, text)
else:
    text = re.sub(r"(\nweb:\n  env:\n)", r"\1" + block, text, count=1)
p.write_text(text)
PY
fi
