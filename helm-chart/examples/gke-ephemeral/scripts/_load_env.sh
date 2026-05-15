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

# Sensible defaults for the recommended Keycloak setup. Override in .env.local
# (any of these as ENABLE_*=true|false) if you want a different topology.
export TF_VAR_enable_cert_manager="${ENABLE_CERT_MANAGER:-true}"
export TF_VAR_enable_services_ingress_nginx="${ENABLE_SERVICES_INGRESS_NGINX:-true}"
export TF_VAR_enable_keycloak="${ENABLE_KEYCLOAK:-true}"
# Disabled by default with Keycloak: the gateway + global-auth are not needed
# because Onyxia core does its own OIDC against Keycloak.
export TF_VAR_enable_oauth2_proxy_gateway="${ENABLE_OAUTH2_PROXY_GATEWAY:-false}"
export TF_VAR_services_ingress_nginx_oauth2_auth="${ENABLE_OAUTH2_GLOBAL_AUTH:-false}"

# Generate the gitignored Onyxia values file from the committed template.
TEMPLATE="${EXAMPLE_DIR}/onyxia-private-values.local.yaml.tmpl"
TARGET="${EXAMPLE_DIR}/onyxia-private-values.local.yaml"
if [ -f "${TEMPLATE}" ]; then
  PUBLIC_HOSTNAME="${PUBLIC_HOSTNAME}" KEYCLOAK_HOSTNAME="${KEYCLOAK_HOSTNAME}" \
    envsubst '${PUBLIC_HOSTNAME} ${KEYCLOAK_HOSTNAME}' \
    < "${TEMPLATE}" > "${TARGET}"
fi
