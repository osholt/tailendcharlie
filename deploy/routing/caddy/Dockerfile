# Caddy with the rate-limit module, which the stock image does not include.
# Both stages are pinned to the version the relay already runs.
FROM caddy:2.11.4-builder AS build
# A pseudo-version pins the exact commit; the module has no recent release tag.
ARG CADDY_RATELIMIT_VERSION=v0.1.1-0.20260612195517-5625512f24f6
RUN xcaddy build --with "github.com/mholt/caddy-ratelimit@${CADDY_RATELIMIT_VERSION}"

FROM caddy:2.11.4-alpine
COPY --from=build /usr/bin/caddy /usr/bin/caddy
RUN caddy list-modules | grep -qx 'http.handlers.rate_limit'
