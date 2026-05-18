#!/usr/bin/env bash
# Configure a Keycloak realm `onyxia` with a public PKCE client and a Google
# identity provider. Idempotent (safe to re-run). With the chart's default
# H2 in-memory database, run after every Keycloak restart.
#
# Required env:
#   KC_ADMIN_PASSWORD     Keycloak `admin` bootstrap password (from tfvars).
#   GOOGLE_CLIENT_ID      Google OAuth Web client ID.
#   GOOGLE_CLIENT_SECRET  Google OAuth Web client secret (or set
#                         ONYXIA_OAUTH2_SECRET_NAME to read it from the
#                         Kubernetes Secret created for oauth2-proxy).
#   ONYXIA_HOSTNAME       Public hostname Onyxia is served on (e.g.
#                         onyxia.example.com).
#   KEYCLOAK_HOSTNAME     Public hostname Keycloak is served on (e.g.
#                         auth.onyxia.example.com).
#
# Optional env:
#   KEYCLOAK_NAMESPACE    Default: keycloak
#   KEYCLOAK_POD          Default: keycloak-keycloakx-0
#   ENABLE_POLARIS        Default: false. When true, also register a
#                         confidential client `polaris` + audience mapper so
#                         Onyxia user tokens carry `aud: polaris`.
set -euo pipefail

KEYCLOAK_NAMESPACE="${KEYCLOAK_NAMESPACE:-keycloak}"
KEYCLOAK_POD="${KEYCLOAK_POD:-keycloak-keycloakx-0}"
ONYXIA_OAUTH2_SECRET_NAME="${ONYXIA_OAUTH2_SECRET_NAME:-onyxia-oauth2-proxy}"

err() { echo "ERROR: $*" >&2; exit 2; }

[ -n "${KC_ADMIN_PASSWORD:-}" ] || err "set KC_ADMIN_PASSWORD"
[ -n "${GOOGLE_CLIENT_ID:-}" ]  || err "set GOOGLE_CLIENT_ID"
[ -n "${ONYXIA_HOSTNAME:-}" ]   || err "set ONYXIA_HOSTNAME (e.g. onyxia.example.com)"
[ -n "${KEYCLOAK_HOSTNAME:-}" ] || err "set KEYCLOAK_HOSTNAME (e.g. auth.onyxia.example.com)"

if [ -z "${GOOGLE_CLIENT_SECRET:-}" ]; then
  if ! GOOGLE_CLIENT_SECRET="$(kubectl -n onyxia get secret "${ONYXIA_OAUTH2_SECRET_NAME}" -o jsonpath='{.data.client-secret}' 2>/dev/null | base64 -d)"; then
    err "set GOOGLE_CLIENT_SECRET or create Secret '${ONYXIA_OAUTH2_SECRET_NAME}' in ns 'onyxia' with key client-secret"
  fi
  [ -n "${GOOGLE_CLIENT_SECRET}" ] || err "set GOOGLE_CLIENT_SECRET (Secret '${ONYXIA_OAUTH2_SECRET_NAME}' exists but key 'client-secret' is empty)"
fi

KCADM=(kubectl -n "$KEYCLOAK_NAMESPACE" exec "$KEYCLOAK_POD" -- /opt/keycloak/bin/kcadm.sh)
SERVER=http://localhost:8080

echo "[init-kc] waiting for pod ${KEYCLOAK_NAMESPACE}/${KEYCLOAK_POD} ready..."
until [ "$(kubectl -n "$KEYCLOAK_NAMESPACE" get pod "$KEYCLOAK_POD" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null)" = "true" ]; do
  sleep 5
done

echo "[init-kc] login as admin on master realm..."
"${KCADM[@]}" config credentials --server "$SERVER" --realm master --user admin --password "$KC_ADMIN_PASSWORD"

# Idempotent helpers: try to create, but swallow "<X> already exists" errors.
kc_safe_create() {
  local label="$1"; shift
  local out rc
  out=$("${KCADM[@]}" "$@" 2>&1) && rc=0 || rc=$?
  if [ $rc -eq 0 ]; then
    echo "${out}"
    return 0
  fi
  if echo "${out}" | grep -qiE "already exists|Conflict detected"; then
    echo "[init-kc] ${label} already present, skipping"
    return 0
  fi
  echo "${out}" >&2
  return $rc
}

echo "[init-kc] create realm onyxia (idempotent)..."
kc_safe_create "realm onyxia" create realms -s realm=onyxia -s enabled=true

echo "[init-kc] create client onyxia (public, PKCE) (idempotent)..."
kc_safe_create "client onyxia" create clients -r onyxia \
  -s clientId=onyxia -s publicClient=true -s standardFlowEnabled=true -s directAccessGrantsEnabled=false \
  -s "redirectUris=[\"https://${ONYXIA_HOSTNAME}/*\"]" \
  -s "webOrigins=[\"https://${ONYXIA_HOSTNAME}\"]" \
  -s 'attributes."pkce.code.challenge.method"=S256'

echo "[init-kc] ensure audience mapper on client onyxia for aud=onyxia (idempotent)..."
onyxia_client_uuid="$("${KCADM[@]}" get clients -r onyxia -q clientId=onyxia --fields id --format csv --noquotes | tail -n1)"
if [ -z "${onyxia_client_uuid}" ]; then
  echo "[init-kc] WARN: could not resolve clientId=onyxia UUID; skipping onyxia audience mapper" >&2
else
  kc_safe_create "audience-mapper onyxia on onyxia" create "clients/${onyxia_client_uuid}/protocol-mappers/models" -r onyxia \
    -s name=onyxia-self-audience \
    -s protocol=openid-connect \
    -s protocolMapper=oidc-audience-mapper \
    -s 'config."included.client.audience"=onyxia' \
    -s 'config."id.token.claim"=false' \
    -s 'config."access.token.claim"=true'
fi

echo "[init-kc] create Google identity provider (idempotent)..."
kc_safe_create "identity-provider google" create identity-provider/instances -r onyxia \
  -s alias=google -s providerId=google -s enabled=true -s trustEmail=true \
  -s "config.clientId=$GOOGLE_CLIENT_ID" \
  -s "config.clientSecret=$GOOGLE_CLIENT_SECRET" \
  -s 'config.useJwksUrl=true'

if [ "${ENABLE_POLARIS:-false}" = "true" ]; then
  echo "[init-kc] (polaris) create client polaris (confidential) (idempotent)..."
  # Polaris validates JWTs with audience=polaris. The chart-side env var
  # POLARIS_OIDC_AUDIENCE matches this clientId. publicClient=false so
  # we can later attach a client-scope audience mapper (server-side mappers
  # only run on confidential clients in Keycloak 24+).
  kc_safe_create "client polaris" create clients -r onyxia \
    -s clientId=polaris -s publicClient=false \
    -s standardFlowEnabled=false -s serviceAccountsEnabled=true \
    -s directAccessGrantsEnabled=false \
    -s 'attributes."access.token.lifespan"=3600'

  echo "[init-kc] (polaris) ensure audience mapper on client onyxia (idempotent)..."
  if [ -z "${onyxia_client_uuid}" ]; then
    echo "[init-kc] WARN: could not resolve clientId=onyxia UUID; skipping audience mapper" >&2
  else
    # Re-create is idempotent because mapper names are unique per client and
    # `kc_safe_create` swallows the "already exists" error.
    kc_safe_create "audience-mapper polaris on onyxia" create "clients/${onyxia_client_uuid}/protocol-mappers/models" -r onyxia \
      -s name=polaris-audience \
      -s protocol=openid-connect \
      -s protocolMapper=oidc-audience-mapper \
      -s 'config."included.client.audience"=polaris' \
      -s 'config."id.token.claim"=false' \
      -s 'config."access.token.claim"=true'
  fi
fi

echo "[init-kc] done. Discovery doc:"
curl -s --max-time 10 "https://${KEYCLOAK_HOSTNAME}/realms/onyxia/.well-known/openid-configuration" \
  | head -c 200 || true
echo
