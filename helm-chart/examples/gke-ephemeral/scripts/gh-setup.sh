#!/usr/bin/env bash
# Push the GitHub Actions variables and secrets needed by
# .github/workflows/onyxia-gke-ephemeral.yml. Reads .env.local for the
# non-secret values and prompts for the secret values (or reads them from env).
#
# Required: `gh` CLI authenticated against your fork.
# Optional env (skip the prompts):
#   GOOGLE_OAUTH_CLIENT_SECRET, GOOGLE_OAUTH_COOKIE_SECRET, KEYCLOAK_ADMIN_PASSWORD,
#   GCP_SA_KEY_PATH (path to a JSON key file for the deployer SA)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXAMPLE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${EXAMPLE_DIR}/.env.local"

[ -f "${ENV_FILE}" ] || { echo "ERROR: missing ${ENV_FILE}. Copy .env.local.example first." >&2; exit 2; }

# shellcheck disable=SC1090
set -a; source "${ENV_FILE}"; set +a

REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
echo "[gh-setup] target repo: ${REPO}"

declare -A VARS=(
  [GCP_PROJECT_ID]="${PROJECT_ID}"
  [GCP_REGION]="${REGION}"
  [GCP_CLUSTER_NAME]="${CLUSTER_NAME}"
  [PUBLIC_HOSTNAME]="${PUBLIC_HOSTNAME}"
  [KEYCLOAK_HOSTNAME]="${KEYCLOAK_HOSTNAME}"
  [LETSENCRYPT_EMAIL]="${LETSENCRYPT_EMAIL}"
  [GOOGLE_OAUTH_CLIENT_ID]="${GOOGLE_OAUTH_CLIENT_ID}"
  [GOOGLE_OAUTH_ALLOWED_EMAILS]="${GOOGLE_OAUTH_ALLOWED_EMAILS}"
)
for key in "${!VARS[@]}"; do
  echo "[gh-setup] var ${key} ← ${VARS[$key]}"
  gh variable set "$key" --body "${VARS[$key]}" --repo "${REPO}"
done

prompt_secret() {
  local name="$1" val="${!2:-}"
  if [ -z "${val}" ]; then
    read -r -s -p "[gh-setup] enter secret ${name}: " val; echo
  fi
  [ -n "${val}" ] || { echo "ERROR: ${name} cannot be empty" >&2; exit 2; }
  gh secret set "${name}" --body "${val}" --repo "${REPO}"
  echo "[gh-setup] secret ${name} ← set"
}

prompt_secret GOOGLE_OAUTH_CLIENT_SECRET GOOGLE_OAUTH_CLIENT_SECRET
prompt_secret GOOGLE_OAUTH_COOKIE_SECRET GOOGLE_OAUTH_COOKIE_SECRET
prompt_secret KEYCLOAK_ADMIN_PASSWORD KEYCLOAK_ADMIN_PASSWORD

# GCP_SA_KEY: read from file if path provided, else prompt for paste.
if [ -n "${GCP_SA_KEY_PATH:-}" ] && [ -f "${GCP_SA_KEY_PATH}" ]; then
  gh secret set GCP_SA_KEY --body "$(cat "${GCP_SA_KEY_PATH}")" --repo "${REPO}"
  echo "[gh-setup] secret GCP_SA_KEY ← read from ${GCP_SA_KEY_PATH}"
else
  echo "[gh-setup] paste the GCP service-account JSON key, then Ctrl-D:"
  GCP_SA_KEY="$(cat)"
  gh secret set GCP_SA_KEY --body "${GCP_SA_KEY}" --repo "${REPO}"
  echo "[gh-setup] secret GCP_SA_KEY ← set"
fi

echo "[gh-setup] done. Run the workflow:"
echo "  gh workflow run onyxia-gke-ephemeral.yml --repo ${REPO} -f mode=init"
