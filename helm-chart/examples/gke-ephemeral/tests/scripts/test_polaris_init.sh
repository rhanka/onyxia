#!/usr/bin/env bash
# Unit test for scripts/polaris-init.sh.
# Shadows `curl` with a scripted state machine to cover:
#   - fresh install (GET catalog -> 404, POST catalog -> 201),
#   - idempotent re-run (GET catalog -> 200, no POST),
#   - storage stub branch (ENABLE_POLARIS_STORAGE unset -> storageType=FILE),
#   - storage on branch (ENABLE_POLARIS_STORAGE=true -> storageType=GCS,
#     payload references the configured bucket + GSA).
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXAMPLE_DIR="$(cd "${TEST_DIR}/../.." && pwd)"
SCRIPT="${EXAMPLE_DIR}/scripts/polaris-init.sh"
[ -x "${SCRIPT}" ] || { echo "FAIL: ${SCRIPT} not executable" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# State for the curl mock. CURL_GET_CODE controls what the GET catalog
# returns; CURL_POST_CODE controls the POST. Payloads are written to
# $CURL_BODIES (one line per POST) so the test can inspect them.
cat > "$WORK/curl" <<'MOCK'
#!/usr/bin/env bash
# Find the URL (last positional arg) and the body (-d JSON) if any.
url=""
body=""
seen_d=0
write_format=""
for arg in "$@"; do
  if [ "${seen_d}" = "1" ]; then body="${arg}"; seen_d=0; continue; fi
  case "${arg}" in
    -d)      seen_d=1 ;;
    -X)      ;;
    -H)      ;;
    -s|-S|-sS|-sf|-sfS|--max-time) ;;
    -o)      ;;
    -w)      ;;
    /dev/null) ;;
    -)       ;;
    *)
      case "${arg}" in
        "%{http_code}") ;;
        $'\nHTTP_CODE=%{http_code}') ;;
        http*) url="${arg}" ;;
      esac
      ;;
  esac
done

# Token endpoint (client_credentials grant).
if [[ "${url}" == *"/protocol/openid-connect/token" ]]; then
  echo '{"access_token":"token-from-mock"}'
  exit 0
fi

# GET <polaris-url>/catalogs/<name> — output: just the HTTP_CODE because the
# script invokes it with -o /dev/null -w "%{http_code}".
if [[ "${url}" == *"/catalogs/onyxia" ]]; then
  printf '%s' "${CURL_GET_CODE:-404}"
  exit 0
fi

# POST <polaris-url>/catalogs — script reads HTTP_CODE from a trailing
# "HTTP_CODE=<code>" line in the response.
if [[ "${url}" == *"/catalogs" ]]; then
  echo "${body}" >> "${CURL_BODIES}"
  echo "{}"
  echo "HTTP_CODE=${CURL_POST_CODE:-201}"
  exit 0
fi

# Anything else (the trailing GET /api/catalog/v1/config) — return empty.
exit 0
MOCK
chmod +x "$WORK/curl"

run_once() {
  local label="$1"; shift
  : > "$WORK/bodies"
  env -i \
    PATH="$WORK:/usr/bin:/bin" \
    POLARIS_HOSTNAME=polaris.onyxia.example.com \
    KEYCLOAK_HOSTNAME=auth.onyxia.example.com \
    POLARIS_CLIENT_SECRET=mock-client-secret \
    CURL_BODIES="$WORK/bodies" \
    "$@" \
    bash "$SCRIPT" >"$WORK/out-${label}" 2>&1 || {
      echo "FAIL: run '${label}' exited non-zero" >&2
      cat "$WORK/out-${label}" >&2
      exit 1
    }
}

# --- 1. Fresh install + stub storage ---------------------------------------
run_once "fresh-stub" CURL_GET_CODE=404 CURL_POST_CODE=201
test -s "$WORK/bodies" || { echo "FAIL: no POST body captured for fresh-stub" >&2; exit 1; }
grep -F '"storageType":"FILE"'  "$WORK/bodies" >/dev/null || \
  { echo "FAIL: stub did not request storageType=FILE" >&2; cat "$WORK/bodies" >&2; exit 1; }

# --- 2. Idempotent re-run (catalog already there) --------------------------
run_once "rerun" CURL_GET_CODE=200 CURL_POST_CODE=999
test ! -s "$WORK/bodies" || { echo "FAIL: re-run still POSTed when catalog existed" >&2; cat "$WORK/bodies" >&2; exit 1; }

# --- 3. Storage on -> GCS payload ------------------------------------------
run_once "gcs-on" \
  CURL_GET_CODE=404 CURL_POST_CODE=201 \
  ENABLE_POLARIS_STORAGE=true \
  POLARIS_WAREHOUSE_BUCKET=acme-onyxia-warehouse \
  POLARIS_WAREHOUSE_GSA_EMAIL=polaris-warehouse@acme.iam.gserviceaccount.com
grep -F '"storageType": "GCS"'  "$WORK/bodies" >/dev/null || \
  { echo "FAIL: storage-on did not request storageType=GCS" >&2; cat "$WORK/bodies" >&2; exit 1; }
grep -F 'gs://acme-onyxia-warehouse/'  "$WORK/bodies" >/dev/null || \
  { echo "FAIL: bucket missing from GCS storage payload" >&2; cat "$WORK/bodies" >&2; exit 1; }
grep -F 'polaris-warehouse@acme.iam.gserviceaccount.com'  "$WORK/bodies" >/dev/null || \
  { echo "FAIL: GSA email missing from GCS storage payload" >&2; cat "$WORK/bodies" >&2; exit 1; }

echo "PASS"
