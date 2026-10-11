#!/bin/sh
# Materialise /app/.env from the Docker secret, then hand off to Vite.
#
# The app's documented configuration path is a .env file at the repo root
# (README "Quick Start"), read through loadEnv() in
# server/standalone/vite.config.js. Writing the file here rather than passing environment variables
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

# HOST=0.0.0.0 binds the server so oauth2-proxy can reach it over the container
# network. Since upstream v0.2.0 it no longer relaxes the Host-header check, so
# GEV_ALLOWED_HOSTS (set in docker-compose.yml) must name the public host —
# without it every request 403s with a blocked-host page that looks nothing
# like an auth problem.
if ! grep -q '^HOST=0\.0\.0\.0' /app/.env; then
  echo "godseye: FATAL — .env must set HOST=0.0.0.0 or oauth2-proxy cannot connect." >&2
  exit 1
fi
case ",${GEV_ALLOWED_HOSTS:-}," in
  *,godseye.azarnoff.us,*) ;;
  *)
    echo "godseye: FATAL — GEV_ALLOWED_HOSTS must include godseye.azarnoff.us or the Host header is refused." >&2
    exit 1
    ;;
esac

# Informational only. Since upstream's keyless mode, a boot with neither key
# serves Esri imagery and every keyless layer; photorealistic 3D needs one of
# these two client-exposed keys.
if ! grep -qE '^(GOOGLE_MAPS_API_KEY|CESIUM_ION_TOKEN)=[^[:space:]]' /app/.env; then
  echo "godseye: note — no GOOGLE_MAPS_API_KEY or CESIUM_ION_TOKEN; running on keyless Esri imagery." >&2
fi

echo "godseye: starting Vite dev server on 0.0.0.0:4173"
exec npm run dev
