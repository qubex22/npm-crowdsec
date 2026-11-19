# =============================================================================
# Nginx Proxy Manager + CrowdSec OpenResty Bouncer
# =============================================================================
#
# This image layers the CrowdSec OpenResty Bouncer on top of the official
# jc21/nginx-proxy-manager image.  The NPM Node.js application, Certbot, and
# s6-overlay process manager are all provided by the base image — we only add
# the CrowdSec Lua libraries and a runtime init service.
#
# Rebuild after an upstream update with a single command:
#   docker pull jc21/nginx-proxy-manager:latest
#   docker build -t npm-crowdsec:latest .
#
# =============================================================================

# Base image tag.  The CI workflow passes the exact NPM version it detected so
# the image really matches the version recorded in .npm-version (instead of
# silently floating on :latest).
ARG NPM_VERSION=latest

FROM jc21/nginx-proxy-manager:${NPM_VERSION} AS base

# ---------------------------------------------------------------------------
# Build args
#   NPM_VERSION                           — informational, used for labels
#   CROWDSEC_OPENRESTY_BOUNCER_VERSION    — bouncer release to install
# ---------------------------------------------------------------------------
ARG NPM_VERSION=latest
ARG CROWDSEC_OPENRESTY_BOUNCER_VERSION=1.2.5

LABEL maintainer="Custom NPM + CrowdSec Build" \
      org.label-schema.name="npm-crowdsec" \
      org.label-schema.description="Nginx Proxy Manager with CrowdSec OpenResty Bouncer" \
      org.label-schema.vcs-url="https://github.com/qubex22/npm-crowdsec" \
      org.label-schema.version="${NPM_VERSION}-cs${CROWDSEC_OPENRESTY_BOUNCER_VERSION}" \
      io.npm-crowdsec.npm-version="${NPM_VERSION}" \
      io.npm-crowdsec.bouncer-version="${CROWDSEC_OPENRESTY_BOUNCER_VERSION}"

# ---------------------------------------------------------------------------
# 1. Download and extract the CrowdSec OpenResty Bouncer release tarball
# ---------------------------------------------------------------------------
RUN mkdir -p /tmp/cs-bouncer \
    && curl -fsSL --retry 3 --retry-delay 2 \
       "https://github.com/crowdsecurity/cs-openresty-bouncer/releases/download/v${CROWDSEC_OPENRESTY_BOUNCER_VERSION}/crowdsec-openresty-bouncer.tgz" \
       | tar xz --strip 1 -C /tmp/cs-bouncer \
    # Fail loudly if an upstream release ever changes its layout
    && test -f /tmp/cs-bouncer/lua/lib/crowdsec.lua \
    && test -f /tmp/cs-bouncer/config/config_example.conf \
    && test -f /tmp/cs-bouncer/openresty/crowdsec_openresty.conf

# ---------------------------------------------------------------------------
# 2. Install bouncer Lua libraries into OpenResty's lualib path
#    The bouncer expects: /etc/nginx/lualib/plugins/crowdsec/
# ---------------------------------------------------------------------------
RUN mkdir -p /etc/nginx/lualib/plugins/crowdsec \
    && cp -r /tmp/cs-bouncer/lua/lib/plugins/crowdsec/* /etc/nginx/lualib/plugins/crowdsec/ \
    && cp /tmp/cs-bouncer/lua/lib/crowdsec.lua /etc/nginx/lualib/ \
    && test -f /etc/nginx/lualib/crowdsec.lua \
    && test -f /etc/nginx/lualib/plugins/crowdsec/config.lua

# ---------------------------------------------------------------------------
# 3. Ensure lua-resty-http is available
#    Bouncer >= 1.2 vendors its own copy under plugins/crowdsec/resty/ (and the
#    nginx snippet puts that directory first in lua_package_path).  Older
#    releases need it installed with opm, which talks to opm.openresty.org and
#    is retried because that endpoint is occasionally unavailable.
# ---------------------------------------------------------------------------
RUN set -eux; \
    if [ -f /etc/nginx/lualib/plugins/crowdsec/resty/http.lua ]; then \
        echo "lua-resty-http is vendored by the bouncer — skipping opm"; \
    else \
        echo "Installing lua-resty-http with opm"; \
        ok="false"; \
        for attempt in 1 2 3; do \
            if /etc/nginx/bin/opm get ledgetech/lua-resty-http; then ok="true"; break; fi; \
            echo "opm attempt ${attempt} failed — retrying in 5s"; \
            sleep 5; \
        done; \
        test "${ok}" = "true"; \
        cp -r /etc/nginx/site/lualib/resty/http.lua \
              /etc/nginx/site/lualib/resty/http_headers.lua \
              /etc/nginx/site/lualib/resty/http_connect.lua \
              /etc/nginx/lualib/resty/; \
        rm -rf /etc/nginx/site/; \
    fi

# ---------------------------------------------------------------------------
# 4. Copy response templates (ban.html, captcha.html) to a persistent path
# ---------------------------------------------------------------------------
RUN mkdir -p /defaults/crowdsec/templates \
    && cp -r /tmp/cs-bouncer/templates/* /defaults/crowdsec/templates/ \
    && test -f /defaults/crowdsec/templates/ban.html

# ---------------------------------------------------------------------------
# 5. Generate the default bouncer config file
#    Place it at /defaults/crowdsec/ so the init script can copy it to
#    /data/crowdsec/ on first boot (preserving user edits across rebuilds).
# ---------------------------------------------------------------------------
RUN mkdir -p /defaults/crowdsec \
    && sed "s|\${CROWDSEC_LAPI_URL}|http://127.0.0.1:8080|; s|\${API_KEY}||" \
         /tmp/cs-bouncer/config/config_example.conf \
         > /defaults/crowdsec/crowdsec-openresty-bouncer.conf \
    # Set ENABLED=false by default — user must opt-in via env var or config
    && sed -i 's/^ENABLED=true/ENABLED=false/' /defaults/crowdsec/crowdsec-openresty-bouncer.conf

# ---------------------------------------------------------------------------
# 6. Generate the CrowdSec nginx snippet (with SSL cert path resolved)
#    This is NOT installed into nginx/conf.d directly — it is injected into
#    the http block of NPM's generated nginx.conf at container start-up.
#    lua_package_path puts the bouncer directory first so a vendored
#    resty.http wins over the base image / opm copy (upstream ordering).
# ---------------------------------------------------------------------------
RUN sed 's|\${SSL_CERTS_PATH}|/etc/ssl/certs/ca-certificates.crt|g' \
    /tmp/cs-bouncer/openresty/crowdsec_openresty.conf \
    | sed "s|^[[:space:]]*lua_package_path.*;|lua_package_path '/etc/nginx/lualib/plugins/crowdsec/?.lua;/etc/nginx/lualib/?.lua;;';|" \
    > /defaults/crowdsec/crowdsec_openresty.snippet \
    && grep -q "crowdsec-openresty-bouncer/v${CROWDSEC_OPENRESTY_BOUNCER_VERSION}" /defaults/crowdsec/crowdsec_openresty.snippet

# ---------------------------------------------------------------------------
# 7. Clean up the extracted tarball
# ---------------------------------------------------------------------------
RUN rm -rf /tmp/cs-bouncer

# ---------------------------------------------------------------------------
# 8. Copy the runtime init script
# ---------------------------------------------------------------------------
COPY scripts/init-crowdsec-bouncer.sh /usr/local/bin/init-crowdsec-bouncer.sh
RUN chmod +x /usr/local/bin/init-crowdsec-bouncer.sh

# ---------------------------------------------------------------------------
# 9. Override the nginx s6-overlay run script to run CrowdSec init first
#    This ensures the init script runs BEFORE nginx starts, guaranteeing that
#    the CrowdSec snippet is injected into nginx.conf before nginx reads it.
#    The original nginx run script is preserved at /etc/s6-overlay/s6-rc.d/nginx/run.orig
# ---------------------------------------------------------------------------
RUN cp /etc/s6-overlay/s6-rc.d/nginx/run /etc/s6-overlay/s6-rc.d/nginx/run.orig

# Write new nginx run script that runs init first, then starts nginx
RUN cat > /etc/s6-overlay/s6-rc.d/nginx/run << 'RUNSCRIPT'
#!/command/with-contenv bash
# shellcheck shell=bash

set -e

. /usr/bin/common.sh

# Run CrowdSec bouncer initialization before starting nginx
# This injects the Lua snippet into nginx.conf and sets up config files
/usr/local/bin/init-crowdsec-bouncer.sh

log_info 'Starting nginx ...'
exec s6-setuidgid "$PUID:$PGID" nginx
RUNSCRIPT

RUN chmod +x /etc/s6-overlay/s6-rc.d/nginx/run
