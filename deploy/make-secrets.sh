#!/usr/bin/env bash
# Generate the two Docker secrets this stack needs. Run ON THE M4, in deploy/.
#
#   ./make-secrets.sh <keycloak-client-secret>
#
# Both outputs are 0400 and live in ./secrets/, which is git-ignored by its own
# internal .gitignore. Neither is ever committed. Re-running is safe: the
# oauth2-proxy config is regenerated, but an existing godseye.env is LEFT ALONE
# so that filling in API keys is not undone by a later run.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

CLIENT_SECRET="${1:-}"
if [[ -z "${CLIENT_SECRET}" ]]; then
  echo "usage: ./make-secrets.sh <keycloak-client-secret>" >&2
  echo "  the secret for client 'godseye' in realm 'personal' at auth.azarnoff.us" >&2
  exit 1
fi

mkdir -p secrets

# --- oauth2-proxy -----------------------------------------------------------
# The cookie secret must be exactly 16, 24 or 32 bytes. base64 of 32 raw bytes
# is what oauth2-proxy's own docs recommend.
COOKIE_SECRET="$(openssl rand -base64 32 | tr -d '\n')"

cat > secrets/oauth2-proxy.cfg <<EOF
client_id = "godseye"
client_secret = "${CLIENT_SECRET}"
cookie_secret = "${COOKIE_SECRET}"
EOF
chmod 0400 secrets/oauth2-proxy.cfg
echo "wrote secrets/oauth2-proxy.cfg (fresh cookie secret — existing sessions are invalidated)"

# --- app environment --------------------------------------------------------
if [[ -f secrets/godseye.env ]]; then
  echo "secrets/godseye.env already exists — left untouched (edit it by hand to add keys)"
  exit 0
fi

cat > secrets/godseye.env <<'EOF'
# God's Eye View — runtime configuration for godseye.azarnoff.us.
# This file becomes /app/.env inside the container. 0400, git-ignored, host-only.
#
# After editing:  /usr/local/bin/docker compose up -d --force-recreate godseye-app

# --- required: the only mandatory key, and the only metered-by-default one ---
# Google Cloud → enable "Map Tiles API" → create key → RESTRICT IT:
#   Application restriction: HTTP referrers → https://godseye.azarnoff.us/*
#   API restriction:         Map Tiles API only
# This key is injected into the browser bundle by design and IS visible in
# devtools. The referrer restriction is what makes that safe; without it a
# leaked key is billable to Scott by anyone who finds it.
# Set a Cloud Billing budget alert as the real backstop.
GOOGLE_MAPS_API_KEY=

# --- server binding — do not change; the entrypoint refuses to start without it
HOST=0.0.0.0
PORT=4173

# --- cost rails -------------------------------------------------------------
# Per-IP, process-local throttles on the two spend-bearing endpoint families.
# Upstream defaults these to UNLIMITED and recommends setting them whenever the
# server is not on localhost. Ours is not. These are guards, not billing caps.
GEV_RATELIMIT_GOOGLE_PER_MIN=60
GEV_RATELIMIT_OPENAI_PER_MIN=30

# --- optional: OpenAI voice control (server-side only, never sent to browser) -
OPENAI_API_KEY=
OPENAI_REALTIME_MODEL=gpt-realtime-2
OPENAI_REALTIME_MODEL_MINI=gpt-realtime-2.1-mini
OPENAI_REALTIME_VOICE=marin
OPENAI_REALTIME_REASONING_EFFORT=low
OPENAI_REALTIME_CONTEXT_TOKENS=3000
OPENAI_REALTIME_CONTEXT_RETENTION=0.5
OPENAI_HUD_SUMMARY_MODEL=gpt-5-nano

# --- optional: NASA FIRMS active fires (free key, server-side only) ----------
# https://firms.modaps.eosdis.nasa.gov/api/map_key/
FIRMS_MAP_KEY=

# --- optional: OpenSky aircraft (free account → better rate limits) ----------
# With these blank, set OPENSKY_AUTH_MODE=anon for the rate-limited public feed.
OPENSKY_AUTH_MODE=anon
OPENSKY_CLIENT_ID=
OPENSKY_CLIENT_SECRET=

# --- optional: AISStream live vessels (free key, server-side only) -----------
AISSTREAM_API_KEY=
VITE_AIS_LIVE_API_URL=/api/ais-live
VITE_AIS_LIVE_MAX_ROWS=12000
VITE_AIS_LIVE_LABEL_MAX_ROWS=900

# --- optional: TomTom live traffic (free tier ~50k tiles/day) ----------------
# Keyless, the traffic layer runs its built-in simulation instead.
TOMTOM_API_KEY=
TOMTOM_DAILY_TILE_BUDGET=40000

# --- optional: Cesium ion (only for the Bing imagery stacks) ----------------
# CLIENT-EXPOSED like the Maps key — use a public assets:read token with URL
# restrictions if you set one.
CESIUM_ION_TOKEN=
EOF
chmod 0400 secrets/godseye.env
echo "wrote secrets/godseye.env — fill in GOOGLE_MAPS_API_KEY to light up the globe"
