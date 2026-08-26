#!/usr/bin/env bash
# Create (or repair) the Keycloak client that gates godseye.azarnoff.us.
#
#   KC_ADMIN_PASSWORD=... ./create-keycloak-client.sh
#
# Idempotent: if client "godseye" already exists it is updated in place and its
# existing secret is printed rather than rotated. Prints the client secret on the
# last line — feed that straight into ./make-secrets.sh.
set -euo pipefail

KC_URL="${KC_URL:-https://auth.azarnoff.us}"
REALM="${REALM:-personal}"
CLIENT_ID="${CLIENT_ID:-godseye}"
REDIRECT_URI="https://godseye.azarnoff.us/oauth2/callback"
KC_ADMIN_USER="${KC_ADMIN_USER:-scottaza}"

if [[ -z "${KC_ADMIN_PASSWORD:-}" ]]; then
  read -rsp "Keycloak admin password for ${KC_ADMIN_USER}: " KC_ADMIN_PASSWORD
  echo
fi

TOKEN="$(curl -sf -X POST \
  "${KC_URL}/realms/master/protocol/openid-connect/token" \
  -d "client_id=admin-cli" -d "grant_type=password" \
  -d "username=${KC_ADMIN_USER}" \
  --data-urlencode "password=${KC_ADMIN_PASSWORD}" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')"

auth=(-H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json")

# --- the client ------------------------------------------------------------
# Confidential (publicClient=false) because oauth2-proxy holds a client secret,
# unlike the trip-planner client which is public and does PKCE from the browser.
# PKCE S256 is required anyway — every other client in this realm uses it.
read -r -d '' PAYLOAD <<EOF || true
{
  "clientId": "${CLIENT_ID}",
  "name": "God's Eye View (godseye.azarnoff.us)",
  "description": "oauth2-proxy gate for the God's Eye View fork. Access list is authenticated-emails.txt in the stack, not this client.",
  "enabled": true,
  "protocol": "openid-connect",
  "publicClient": false,
  "standardFlowEnabled": true,
  "directAccessGrantsEnabled": false,
  "serviceAccountsEnabled": false,
  "implicitFlowEnabled": false,
  "redirectUris": ["${REDIRECT_URI}"],
  "webOrigins": ["https://godseye.azarnoff.us"],
  "attributes": { "pkce.code.challenge.method": "S256" }
}
EOF

EXISTING="$(curl -sf "${auth[@]}" \
  "${KC_URL}/admin/realms/${REALM}/clients?clientId=${CLIENT_ID}" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["id"] if d else "")')"

if [[ -n "${EXISTING}" ]]; then
  echo "client '${CLIENT_ID}' exists (${EXISTING}) — updating in place, secret NOT rotated"
  curl -sf -X PUT "${auth[@]}" \
    "${KC_URL}/admin/realms/${REALM}/clients/${EXISTING}" -d "${PAYLOAD}"
  UUID="${EXISTING}"
else
  curl -sf -X POST "${auth[@]}" \
    "${KC_URL}/admin/realms/${REALM}/clients" -d "${PAYLOAD}"
  UUID="$(curl -sf "${auth[@]}" \
    "${KC_URL}/admin/realms/${REALM}/clients?clientId=${CLIENT_ID}" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["id"])')"
  echo "created client '${CLIENT_ID}' (${UUID})"
fi

# --- the audience mapper, and it is NOT optional ---------------------------
# ⚠️ Without this, Keycloak returns aud:[account] and oauth2-proxy rejects its
# OWN session with "audience from claim aud with value [account] does not match
# with any of allowed audiences". The code exchange SUCCEEDS first, so it
# presents as a client-secret problem and is not. This cost a debugging cycle on
# the genii stack; expect it on every Keycloak client on this box.
#
# The other "fix" you will find online — --oidc-extra-audience=account — widens
# what the proxy trusts instead of making the token correct. Do not use it.
HAS_MAPPER="$(curl -sf "${auth[@]}" \
  "${KC_URL}/admin/realms/${REALM}/clients/${UUID}/protocol-mappers/models" \
  | python3 -c "import json,sys; print(any(m['name']=='audience' for m in json.load(sys.stdin)))")"

if [[ "${HAS_MAPPER}" == "True" ]]; then
  echo "audience mapper already present"
else
  curl -sf -X POST "${auth[@]}" \
    "${KC_URL}/admin/realms/${REALM}/clients/${UUID}/protocol-mappers/models" \
    -d "{
      \"name\": \"audience\",
      \"protocol\": \"openid-connect\",
      \"protocolMapper\": \"oidc-audience-mapper\",
      \"config\": {
        \"included.client.audience\": \"${CLIENT_ID}\",
        \"access.token.claim\": \"true\",
        \"id.token.claim\": \"false\"
      }
    }"
  echo "added oidc-audience-mapper naming '${CLIENT_ID}'"
fi

SECRET="$(curl -sf "${auth[@]}" \
  "${KC_URL}/admin/realms/${REALM}/clients/${UUID}/client-secret" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["value"])')"

echo
echo "client secret: ${SECRET}"
