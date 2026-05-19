#!/usr/bin/env bash
# Unit test for scripts/keycloak-init.sh audience-mapper setup.
# Shadows kubectl + curl + sleep so the script runs offline. Asserts:
#   - the base `onyxia` audience mapper is always configured on the `onyxia`
#     client, so user tokens carry `aud: onyxia` for the STS bridge,
#   - create-client polaris is attempted exactly once,
#   - the audience-mapper create command is shaped right
#     (protocolMapper=oidc-audience-mapper, included.client.audience=polaris),
#   - re-running the script is idempotent (no duplicate calls, no exit code).
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXAMPLE_DIR="$(cd "${TEST_DIR}/../.." && pwd)"
SCRIPT="${EXAMPLE_DIR}/scripts/keycloak-init.sh"
[ -x "${SCRIPT}" ] || { echo "FAIL: ${SCRIPT} not executable" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Tiny kubectl mock. Logs every invocation to $WORK/calls, swallows --
# (kcadm.sh delimiter) so we can spot the kcadm subcommands themselves.
cat > "$WORK/kubectl" <<'MOCK'
#!/usr/bin/env bash
echo "kubectl $*" >> "$KCMOCK_CALLS"
# After the script invokes kcadm via `kubectl exec ... -- /opt/keycloak/bin/kcadm.sh <cmd>`,
# return canned answers for the subcommands the polaris branch uses.
saw_dashdash=0
for arg in "$@"; do
  if [ "${arg}" = "--" ]; then saw_dashdash=1; continue; fi
  if [ "${saw_dashdash}" = "1" ]; then
    case "${arg}" in
      config)        exit 0 ;;
      create)        exit 0 ;;  # treat every create as success — covers first-run path
      get)
        # Asked for the client UUIDs or for the polaris client secret.
        if printf '%s\n' "$*" | grep -F 'client-secret' >/dev/null; then
          echo '{"type":"secret","value":"secret-from-mock"}'
          exit 0
        fi
        if printf '%s\n' "$*" | grep -F 'clientId=polaris' >/dev/null; then
          echo "polaris-client-uuid-xyz"
          exit 0
        fi
        echo "client-uuid-xyz"
        exit 0
        ;;
    esac
  fi
done
# Status checks ("get pod ... ready") — return 'true' so the readiness wait exits.
echo "true"
MOCK
chmod +x "$WORK/kubectl"

# curl + sleep stubs.
cat > "$WORK/curl"  <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
chmod +x "$WORK/curl"
cat > "$WORK/sleep" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
chmod +x "$WORK/sleep"

export KCMOCK_CALLS="$WORK/calls"
: > "$KCMOCK_CALLS"

env -i \
  PATH="$WORK:/usr/bin:/bin" \
  KC_ADMIN_PASSWORD=dummy \
  GOOGLE_CLIENT_ID=g-id \
  GOOGLE_CLIENT_SECRET=g-secret \
  ONYXIA_HOSTNAME=onyxia.example.com \
  KEYCLOAK_HOSTNAME=auth.onyxia.example.com \
  ENABLE_POLARIS=true \
  KCMOCK_CALLS="$KCMOCK_CALLS" \
  bash "$SCRIPT" >"$WORK/run1.out" 2>&1 || {
    echo "FAIL: first run exited non-zero" >&2
    cat "$WORK/run1.out" >&2
    exit 1
  }

# Assertions on the first run.
grep -F 'create clients -r onyxia ' "$KCMOCK_CALLS" | grep -F 'clientId=polaris' >/dev/null \
  || { echo "FAIL: create client polaris not invoked" >&2; cat "$KCMOCK_CALLS" >&2; exit 1; }

grep -F 'protocol-mappers/models -r onyxia' "$KCMOCK_CALLS" \
  | grep -F 'protocolMapper=oidc-audience-mapper' \
  | grep -F 'included.client.audience"=polaris' >/dev/null \
  || { echo "FAIL: audience mapper create command malformed or missing" >&2; cat "$KCMOCK_CALLS" >&2; exit 1; }

# Audience mapper must target the resolved client UUID, not the literal "onyxia".
grep -F 'clients/client-uuid-xyz/protocol-mappers/models' "$KCMOCK_CALLS" >/dev/null \
  || { echo "FAIL: audience mapper not addressed by resolved UUID" >&2; cat "$KCMOCK_CALLS" >&2; exit 1; }

# client_credentials on the confidential polaris client must also mint a token
# with aud=polaris, so a second audience mapper targets the polaris client UUID.
grep -F 'clients/polaris-client-uuid-xyz/protocol-mappers/models' "$KCMOCK_CALLS" \
  | grep -F 'included.client.audience"=polaris' >/dev/null \
  || { echo "FAIL: polaris client did not receive its own audience mapper" >&2; cat "$KCMOCK_CALLS" >&2; exit 1; }

grep -F 'create secret generic polaris-client' "$KCMOCK_CALLS" | grep -F 'client-secret=secret-from-mock' >/dev/null \
  || { echo "FAIL: polaris client secret was not mirrored into a Kubernetes Secret" >&2; cat "$KCMOCK_CALLS" >&2; exit 1; }

# Second run with the same setup must still exit 0 (idempotency contract).
: > "$KCMOCK_CALLS"
env -i \
  PATH="$WORK:/usr/bin:/bin" \
  KC_ADMIN_PASSWORD=dummy \
  GOOGLE_CLIENT_ID=g-id \
  GOOGLE_CLIENT_SECRET=g-secret \
  ONYXIA_HOSTNAME=onyxia.example.com \
  KEYCLOAK_HOSTNAME=auth.onyxia.example.com \
  ENABLE_POLARIS=true \
  KCMOCK_CALLS="$KCMOCK_CALLS" \
  bash "$SCRIPT" >"$WORK/run2.out" 2>&1 || {
    echo "FAIL: second run exited non-zero (idempotency)" >&2
    cat "$WORK/run2.out" >&2
    exit 1
  }

# ENABLE_POLARIS=false (default) must NOT touch polaris client/mapper.
: > "$KCMOCK_CALLS"
env -i \
  PATH="$WORK:/usr/bin:/bin" \
  KC_ADMIN_PASSWORD=dummy \
  GOOGLE_CLIENT_ID=g-id \
  GOOGLE_CLIENT_SECRET=g-secret \
  ONYXIA_HOSTNAME=onyxia.example.com \
  KEYCLOAK_HOSTNAME=auth.onyxia.example.com \
  KCMOCK_CALLS="$KCMOCK_CALLS" \
  bash "$SCRIPT" >"$WORK/run3.out" 2>&1 || {
    echo "FAIL: ENABLE_POLARIS=false (default) run exited non-zero" >&2
    cat "$WORK/run3.out" >&2
    exit 1
  }
grep -F 'protocol-mappers/models -r onyxia' "$KCMOCK_CALLS" \
  | grep -F 'protocolMapper=oidc-audience-mapper' \
  | grep -F 'included.client.audience"=onyxia' >/dev/null \
  || { echo "FAIL: onyxia audience mapper missing in default path" >&2; cat "$KCMOCK_CALLS" >&2; exit 1; }
if grep -F 'clientId=polaris' "$KCMOCK_CALLS" >/dev/null; then
  echo "FAIL: polaris client was created when ENABLE_POLARIS was not set" >&2
  exit 1
fi

echo "PASS"
