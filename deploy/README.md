# Deploying God's Eye View at `godseye.azarnoff.us`

Scott's self-hosted fork, on the M4 Mac Mini, gated by the same Keycloak and the same `scott@azarnoff.us` Google login that `trips.azarnoff.us` uses.

Everything in this directory is **additive to upstream** — no file outside `deploy/` is modified, so merging `bilawalsidhu/gods-eye-view` stays a fast-forward.

## The two decisions that shape this stack

**1. It runs the Vite dev server, on purpose.** About ten of the app's data proxies in `vite.config.js` register only a `configureServer` hook and no `configurePreviewServer` — `opensky` (live aircraft), `celestrak` (satellites), `cctv`, `tomtom`, `firms`, `overpass`, `adsbdb`, `terrain-heights`, `gbfs`, `adsblol`. A `vite build && vite preview` deployment therefore serves a photorealistic globe with none of the layers the app exists for. Upstream `SECURITY.md` sanctions this shape explicitly: *"The Vite server is a development/preview server. If you expose it beyond localhost, put it behind your own auth/proxy."*

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

The stack deploys and authenticates fine with no keys at all; the globe just stays dark. `GOOGLE_MAPS_API_KEY` is the only mandatory one and the only metered-by-default one.

```bash
cd /Users/Shared/docker/gods-eye-view/deploy
sudo chmod 0600 secrets/godseye.env && sudo vi secrets/godseye.env && sudo chmod 0400 secrets/godseye.env
/usr/local/bin/docker compose up -d --force-recreate godseye-app
```

**Restrict the Maps key in Google Cloud before using it in anger.** It is injected into the browser bundle by design and *is* visible in devtools — upstream is explicit that hiding it is not the plan, restricting it is:

- Application restriction: **HTTP referrers** → `https://godseye.azarnoff.us/*`
- API restriction: **Map Tiles API** only
- A **Cloud Billing budget alert** is the real backstop. The in-app `GEV_RATELIMIT_*` throttles are per-IP, in-memory, reset on restart, and are explicitly **not** billing caps.

## Updating

```bash
cd /Users/Shared/docker/gods-eye-view
git pull origin main
export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"
cd deploy && /usr/local/bin/docker compose up -d --build
```

The source is baked into the image (`COPY . .`) with no bind mount, so a `git pull` alone changes nothing that is running — the rebuild is what ships it.

## Traps worth knowing before you touch this

- **`HOST=0.0.0.0` in `godseye.env` is not optional, and it does two jobs.** It binds the server so oauth2-proxy can reach it, *and* it flips Vite's `allowedHosts` to `true` (`vite.config.js:7368`). Without it the dev server refuses the `Host: godseye.azarnoff.us` header and every request returns a blocked-host page that looks nothing like an auth failure. The entrypoint refuses to start rather than let this happen quietly.
- **The Keycloak audience mapper is required.** Without it Keycloak issues `aud: [account]` and oauth2-proxy rejects its own session. The code exchange succeeds first, so it presents as a bad client secret. `create-keycloak-client.sh` adds the mapper; don't "fix" this with `--oidc-extra-audience=account`, which widens what the proxy trusts instead of making the token correct.
- **Never add `internal-only` to this route expecting a LAN allowlist.** On this box it is a deny-all — Docker Desktop SNATs every inbound connection to `172.26.0.1`, so Traefik never sees a real client IP. And adding `172.26.0.0/16` would open the route to the entire internet while reading like a private restriction.
- **First boot is slow.** Vite pre-bundles Cesium, which is a large dependency; the healthcheck allows a 180 s `start_period` for it. A shorter one flaps the container.
