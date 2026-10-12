# Deploying God's Eye View at `godseye.azarnoff.us`

Scott's self-hosted fork, on the M4 Mac Mini, gated by the same Keycloak and the same `scott@azarnoff.us` Google login that `trips.azarnoff.us` uses.

Everything in this directory is **additive to upstream** — no file outside `deploy/` is modified, so merging `bilawalsidhu/gods-eye-view` stays a fast-forward.

## The two decisions that shape this stack

**1. It runs the Vite dev server, on purpose.** When this was built (2026-08-25), about ten of the app's data proxies registered only a `configureServer` hook, so `vite build && vite preview` served a globe with none of the live layers. Upstream has since split the providers into `server/providers/` and most now register `configurePreviewServer` too (checked 2026-10-01), so a preview-server image may now be viable — but it is untested here, and the dev server still works. Upstream `SECURITY.md` sanctions this shape explicitly: *"The Vite server is a development/preview server. If you expose it beyond localhost, put it behind your own auth/proxy."*

**2. The gate is oauth2-proxy, not in-app OIDC.** `trips.azarnoff.us` implements OIDC inside the application (`src/lib/oidc.ts`, public client, browser PKCE). That is not transplantable here: this is unmodified upstream code with no auth layer, and patching a 7,383-line `vite.config.js` would poison every future merge. So the gate sits *in front*, following the pattern already proven on `genii.azarnoff.us`. Same Keycloak, same realm `personal`, same Google federation — different plumbing.

**The gate is load-bearing in a way it usually isn't.** The Vite server is an **API-key broker**: `/api/realtime/token`, `/api/google/nearby-places` and friends spend real money on Scott's accounts. Anyone who can send it HTTP can spend that quota. An unauthenticated path to `godseye-app` is a billing hole, not just an information leak — which is why the app container publishes no host port and has no Traefik router of its own.

## Allocations

| What | Value |
|---|---|
| Repo on M4 | `/Users/Shared/docker/gods-eye-view/` |
| Compose file | `deploy/docker-compose.yml` (run from `deploy/`) |
| Containers | `godseye-app`, `godseye-oauth2-proxy` |
| Host ports | **none** — both containers are on `traefik_default` only |
| Public URL | `https://godseye.azarnoff.us` |
| Keycloak | realm `personal`, confidential client `godseye` |
| Access list | `deploy/authenticated-emails.txt` |

DNS needs no work: `*.azarnoff.us` is a Cloudflare wildcard already pointing at the house IP, and Traefik holds the wildcard cert.

## Access control — where it actually lives

Two independent fences, and it matters which does what:

- **Keycloak realm `personal`** decides *who you are*. Its Google IdP creates a user for any Google account that tries, so a valid token proves identity and nothing more.
- **`authenticated-emails.txt`** decides *who gets in*. It contains exactly one address. This is deliberately **not** `--email-domain=azarnoff.us`.

Adding someone is a one-line edit to that file. oauth2-proxy **watches it and reloads on change** (`watcher.go` logs `watching '/etc/oauth2-proxy/authenticated-emails.txt' for updates` at startup), so no restart is needed — restart only if a change appears not to take. Nothing else in the stack grants access.

## First deploy

```bash
ssh m4-mac-mini
export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"   # required over SSH — see below
git clone https://github.com/sazarnoff/gods-eye-view.git /Users/Shared/docker/gods-eye-view
cd /Users/Shared/docker/gods-eye-view/deploy

./create-keycloak-client.sh          # prints the client secret
./make-secrets.sh <that-secret>      # writes secrets/oauth2-proxy.cfg + secrets/godseye.env

cp traefik-godseye.yml /Users/Shared/docker/traefik/dynamic/godseye.yml   # Traefik auto-reloads

/usr/local/bin/docker compose up -d --build
curl -s -o /dev/null -w '%{http_code}\n' https://godseye.azarnoff.us/      # expect 302 → Keycloak
```

**Over SSH, put Docker Desktop's bin on PATH first.** A non-interactive login doesn't have it, `~/.docker/config.json` sets `"credsStore": "desktop"`, and the build dies on its first line with `docker-credential-desktop: executable file not found` — which reads like a registry auth problem and isn't.

## Adding API keys

No key is mandatory any more. With none, upstream serves keyless Esri imagery plus flights, satellites, earthquakes, cameras, radio, launches and weather. Photorealistic 3D needs **either** `CESIUM_ION_TOKEN` (free Community plan, personal/non-commercial) **or** `GOOGLE_MAPS_API_KEY` (metered). `OPENAI_API_KEY` (voice + HUD summary) is the other metered one; AISStream (ships), NASA FIRMS (fires) and TomTom (traffic) are free. Upstream README § "API Keys" is the current list.

The secret file is owned by `scottaza`, so no sudo is needed:

```bash
cd /Users/Shared/docker/gods-eye-view/deploy
chmod 0600 secrets/godseye.env && vi secrets/godseye.env && chmod 0400 secrets/godseye.env
/usr/local/bin/docker compose up -d --force-recreate godseye-app
```

**Do not use the in-app POWER UP → Provider Settings panel here.** It writes `/app/.env` inside the container, and the entrypoint overwrites that file from the Docker secret on every start — so a key entered there works until the next recreate and then silently vanishes. The secret file is the only durable place.

**Restrict the Maps key in Google Cloud before using it in anger.** It is injected into the browser bundle by design and *is* visible in devtools — upstream is explicit that hiding it is not the plan, restricting it is:

- Application restriction: **HTTP referrers** → `https://godseye.azarnoff.us/*`
- API restriction: **Map Tiles API** only
- A **Cloud Billing budget alert** is the real backstop. The in-app `GEV_RATELIMIT_*` throttles are per-IP, in-memory, reset on restart, and are explicitly **not** billing caps.

## Updating

Merge upstream into the fork on a workstation (`deploy/` is additive, so only `.gitignore` has ever conflicted), push, then on the M4:

```bash
cd /Users/Shared/docker/gods-eye-view
git pull origin main
export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"
cd deploy && /usr/local/bin/docker compose build --pull && /usr/local/bin/docker compose up -d
```

The source is baked into the image (`COPY . .`) with no bind mount, so a `git pull` alone changes nothing that is running — the rebuild is what ships it. `--pull` matters: upstream's `engines` requires Node ≥ 24.14, and a cached `node:24-alpine` base can be older.

Upstream warns that installs older than late September 2026 have empty Traffic, Mapped Installations and ALPR layers, because public Overpass servers now refuse them. Keep this fork current.

## Traps worth knowing before you touch this

- **The app needs both `HOST=0.0.0.0` (in `godseye.env`) and `GEV_ALLOWED_HOSTS=godseye.azarnoff.us` (in `docker-compose.yml`).** `HOST` binds the server so oauth2-proxy can reach it. Since upstream v0.2.0 (merged 2026-10-12) a wildcard bind no longer disables the Host-header check, so the public name must be listed explicitly. Without it every request through oauth2-proxy returns a 403 "blocked host" page that looks nothing like an auth failure. The entrypoint refuses to start if either one is missing.
- **Paid endpoints refuse proxied requests.** Since v0.2.0, upstream's cross-site gate (`src/localRequestGate.mjs`) returns 403 for any request carrying reverse-proxy headers on `/api/realtime/*`, `/api/openai/*`, `/api/google/*` and `/api/mapillary/*`. Every request here comes through Traefik and oauth2-proxy. **Mapillary works** because oauth2-proxy sends `/api/mapillary/` to `godseye-mapillary-hop`, an nginx container that strips exactly the gate's `PROXY_SIGNALS` headers (`nginx-mapillary.conf`); the request is already authenticated by then, and the gate's `Sec-Fetch-Site`/`Origin` checks still run. **OpenAI voice and Google Places still cannot work**, which is fine while their metered keys stay unset. If you enable one, add its prefix the same way rather than widening the hop. If upstream adds a header to `PROXY_SIGNALS`, add it to the nginx file too, or Street Level goes back to 403.
- **The Keycloak audience mapper is required.** Without it Keycloak issues `aud: [account]` and oauth2-proxy rejects its own session. The code exchange succeeds first, so it presents as a bad client secret. `create-keycloak-client.sh` adds the mapper; don't "fix" this with `--oidc-extra-audience=account`, which widens what the proxy trusts instead of making the token correct.
- **Never add `internal-only` to this route expecting a LAN allowlist.** On this box it is a deny-all — Docker Desktop SNATs every inbound connection to `172.26.0.1`, so Traefik never sees a real client IP. And adding `172.26.0.0/16` would open the route to the entire internet while reading like a private restriction.
- **First boot is slow.** Vite pre-bundles Cesium, which is a large dependency; the healthcheck allows a 180 s `start_period` for it. A shorter one flaps the container.
