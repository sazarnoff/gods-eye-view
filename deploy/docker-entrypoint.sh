#!/bin/sh
# Materialise /app/.env from the Docker secret, then hand off to Vite.
#
# The app's documented configuration path is a .env file at the repo root
# (README "Quick Start"), and vite.config.js reads it through loadEnv() at
# line 7336. Writing the file here rather than passing environment variables
# keeps every key out of `docker inspect`, out of the compose file and out of
# the process environment of anything but the server itself — AGENTS.md §6.
set -eu

SECRET=/run/secrets/godseye_env

if [ ! -r "$SECRET" ]; then
  echo "godseye: FATAL — $SECRET is missing or unreadable." >&2
  echo "godseye: run deploy/make-secrets.sh on the host before starting." >&2
  exit 1
fi

cp "$SECRET" /app/.env
chmod 0400 /app/.env

# HOST=0.0.0.0 does two jobs and both are required here. It binds the server so
# oauth2-proxy can reach it over the container network, and it flips Vite's
# `allowedHosts` to true (vite.config.js:7368) — without it the dev server
# rejects the Host header "godseye.azarnoff.us" outright and every request 403s
# with a blocked-host page that looks nothing like an auth problem.
if ! grep -q '^HOST=0\.0\.0\.0' /app/.env; then
  echo "godseye: FATAL — .env must set HOST=0.0.0.0 or the Host header is refused." >&2
  exit 1
fi

# Warn, but do not refuse to start. A keyless boot still serves the app and the
# auth gate; the globe simply stays dark until the Maps key is filled in. That
# is a deliberately recoverable state, not a broken deploy.
if grep -q '^GOOGLE_MAPS_API_KEY=\s*$' /app/.env; then
  echo "godseye: WARNING — GOOGLE_MAPS_API_KEY is empty; the 3D globe will not load." >&2
fi

echo "godseye: starting Vite dev server on 0.0.0.0:4173"
exec npm run dev
