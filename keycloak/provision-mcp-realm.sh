#!/usr/bin/env bash
# Provision the mcp realm and the pre-registered public client that
# Agentgateway's mcpAuthentication.clientId points at.
# Mirrors https://agentgateway.dev/docs/standalone/latest/integrations/auth/keycloak/
# (realm, client, audience mapper, users) without Dynamic Client Registration.
# Idempotent: safe to re-run after Keycloak restarts.
set -euo pipefail

KEYCLOAK_URL="${KEYCLOAK_URL:-http://keycloak:8080}"
KEYCLOAK_ADMIN="${KEYCLOAK_ADMIN:-admin}"
KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:-admin}"
REALM="${KEYCLOAK_REALM:-mcp}"
CLIENT_ID="${KEYCLOAK_CLIENT_ID:-agentgateway}"
kcadm() { /opt/keycloak/bin/kcadm.sh "$@"; }
# kcadm --format csv may print a header row (id, name, ...).
# Keycloak's image has no awk; keep this POSIX so provision can run.
csv_id() {
  tr -d '\r' | sed -n '/^id$/d;/^name$/d;/./{p;q;}'
}

log() { printf 'keycloak-provision: %s\n' "$*"; }

log "waiting for ${KEYCLOAK_URL}"
ready=0
for _ in $(seq 1 60); do
  if kcadm config credentials --server "${KEYCLOAK_URL}" --realm master \
    --user "${KEYCLOAK_ADMIN}" --password "${KEYCLOAK_ADMIN_PASSWORD}"; then
    ready=1
    break
  fi
  sleep 2
done
[[ "${ready}" == "1" ]] || {
  log "Keycloak admin API never accepted credentials"
  exit 1
}

if kcadm get "realms/${REALM}" >/dev/null 2>&1; then
  log "realm ${REALM} already exists"
else
  # sslRequired=NONE is required for this local setup. Keycloak's default of
  # external rejects requests that do not arrive over HTTPS or from a local
  # address, and a container reached through a published port does not count
  # as local. Do not use this setting in production.
  log "creating realm ${REALM}"
  kcadm create realms -s "realm=${REALM}" -s enabled=true -s sslRequired=NONE
fi

# Keep Frontend URL empty so the mcp realm uses KC_HOSTNAME
# (http://localhost:8080). A pin to http://keycloak:8080 makes MCP clients
# redirect the browser to a hostname the host cannot resolve.
# Empty string: HostnameV2 treats blank frontendUrl as unset.
log "ensuring realm ${REALM} has no frontendUrl override"
if ! kcadm update "realms/${REALM}" -s "sslRequired=NONE" -d 'attributes.frontendUrl'; then
  kcadm update "realms/${REALM}" -s "sslRequired=NONE" -s 'attributes.frontendUrl='
fi

CLIENT_UUID="$(kcadm get clients -r "${REALM}" -q "clientId=${CLIENT_ID}" \
  --fields id --format csv --noquotes | csv_id || true)"
if [[ -z "${CLIENT_UUID}" ]]; then
  # Public PKCE client. MCP clients cannot keep a secret (OAuth 2.1 / MCP
  # authorization). directAccessGrantsEnabled is only for the guide's
  # password-grant curl checks. Real clients use authorization code + PKCE.
  log "creating public client ${CLIENT_ID}"
  kcadm create clients -r "${REALM}" \
    -s "clientId=${CLIENT_ID}" \
    -s name="Agentgateway MCP" \
    -s publicClient=true \
    -s standardFlowEnabled=true \
    -s implicitFlowEnabled=false \
    -s directAccessGrantsEnabled=true \
    -s serviceAccountsEnabled=false \
    -s 'redirectUris=["http://localhost:*","http://127.0.0.1:*"]' \
    -s 'webOrigins=["*"]' \
    -s 'attributes."pkce.code.challenge.method"=S256'
  CLIENT_UUID="$(kcadm get clients -r "${REALM}" -q "clientId=${CLIENT_ID}" \
    --fields id --format csv --noquotes | csv_id)"
fi
[[ -n "${CLIENT_UUID}" ]] || {
  log "failed to resolve client UUID for ${CLIENT_ID}"
  exit 1
}

# Re-runs (and clients created before this change) must still require PKCE S256.
log "ensuring PKCE S256 on client ${CLIENT_ID}"
kcadm update "clients/${CLIENT_UUID}" -r "${REALM}" \
  -s 'attributes."pkce.code.challenge.method"=S256'

MAPPER_NAME="agentgateway-audience"
if kcadm get "clients/${CLIENT_UUID}/protocol-mappers/models" -r "${REALM}" \
  --format csv --fields name --noquotes | grep -qx "${MAPPER_NAME}"; then
  log "audience mapper ${MAPPER_NAME} already exists"
else
  # Required: by default Keycloak sets aud to account and records the client
  # only in azp, so Agentgateway's audiences: [agentgateway] never matches.
  log "creating audience mapper ${MAPPER_NAME}"
  kcadm create "clients/${CLIENT_UUID}/protocol-mappers/models" -r "${REALM}" \
    -s "name=${MAPPER_NAME}" \
    -s protocol=openid-connect \
    -s protocolMapper=oidc-audience-mapper \
    -s 'config."included.client.audience"=agentgateway' \
    -s 'config."access.token.claim"=true'
fi

if kcadm get "roles/mcp-admin" -r "${REALM}" >/dev/null 2>&1; then
  log "role mcp-admin already exists"
else
  log "creating role mcp-admin"
  kcadm create roles -r "${REALM}" -s name=mcp-admin
fi

ensure_user() {
  local username="$1" password="$2" email="$3" first="$4" last="$5" with_admin="$6"
  local user_id
  user_id="$(kcadm get users -r "${REALM}" -q "username=${username}" \
    --fields id --format csv --noquotes | csv_id || true)"
  if [[ -z "${user_id}" ]]; then
    # Email and name are required by Keycloak's default user profile. Without
    # them the token endpoint returns invalid_grant / Account is not fully set up.
    log "creating user ${username}"
    kcadm create users -r "${REALM}" \
      -s "username=${username}" -s enabled=true -s emailVerified=true \
      -s "email=${email}" -s "firstName=${first}" -s "lastName=${last}"
    kcadm set-password -r "${REALM}" --username "${username}" --new-password "${password}"
  else
    log "user ${username} already exists"
  fi
  if [[ "${with_admin}" == "1" ]]; then
    kcadm add-roles -r "${REALM}" --uusername "${username}" --rolename mcp-admin || true
  fi
}

ensure_user mcpuser mcppassword mcpuser@example.com MCP User 1
ensure_user noroleuser mcppassword noroleuser@example.com No Role 0

# This scenario uses the pre-registered ${CLIENT_ID} client. Do not relax
# Keycloak's Trusted Hosts policy: Agentgateway short-circuits DCR with
# mcpAuthentication.clientId and never proxies registration to Keycloak.

log "realm ${REALM} is ready (pre-registered client ${CLIENT_ID}, users mcpuser and noroleuser)"
