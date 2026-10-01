# God's Eye View — godseye.azarnoff.us
#
# This image runs the VITE DEV SERVER, deliberately. When it was built
# (2026-08-25) ~10 data proxies registered only `configureServer`, so
# `vite build && vite preview` served a globe with no live layers. Upstream has
# since added `configurePreviewServer` to most providers (server/providers/);
# a preview image may now work but is untested — see deploy/README.md.
#
# Upstream SECURITY.md sanctions exactly this shape: "The Vite server is a
# development/preview server. If you expose it beyond localhost, put it behind
# your own auth/proxy." Ours is oauth2-proxy + Keycloak, and this container
# publishes no host port at all.

FROM node:24-alpine

# puppeteer is a devDependency used only by the repo's QA scripts. We need the
# other devDependencies (vite itself is one), so we cannot --omit=dev — but we
# can decline the ~200 MB Chromium download that comes with it.
ENV PUPPETEER_SKIP_DOWNLOAD=1

WORKDIR /app

# Copied separately so a source change doesn't re-run the install layer.
COPY package.json package-lock.json ./
RUN npm ci

COPY . .

# The entrypoint materialises /app/.env from the Docker secret at startup.
COPY deploy/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

EXPOSE 4173
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
