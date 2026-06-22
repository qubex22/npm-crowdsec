#!/bin/bash
# =============================================================================
# init-crowdsec-bouncer.sh
# =============================================================================
#
# Runtime initialisation script for the CrowdSec OpenResty Bouncer.
#
# Called by the s6-overlay `crowdsec-init` service before nginx starts.
#
# Responsibilities:
#   1. Ensure /data/crowdsec/ exists and contains a valid config file
#      (copied from /defaults/crowdsec/ on first boot; user edits preserved).
#   2. Copy new template files from /defaults/ if they don't already exist.
#   3. Patch the bouncer config with environment variables if provided.
#   4. Fix legacy template paths from LePresidente builds (/tmp/ prefix).
#   5. Inject the CrowdSec Lua snippet into NPM's nginx.conf http block
#      so that every proxied request is checked.
#
# Environment variables:
#   CROWDSEC_ENABLED        — "true" to enable the bouncer (default: false)
#   CROWDSEC_LAPI_URL       — CrowdSec Local API URL (e.g. http://crowdsec:8080)
#   CROWDSEC_API_KEY        — API key for authentication
#   CROWDSEC_CONFIG_CONTENT — Multi-line string of KEY=VALUE pairs to merge
#                             into the bouncer config (overrides individual keys).
#
# =============================================================================

set -euo pipefail

DEFAULTS_DIR="/defaults/crowdsec"
CONFIG_DIR="/data/crowdsec"
TEMPLATES_DEFAULTS="${DEFAULTS_DIR}/templates"
TEMPLATES_CONFIG="${CONFIG_DIR}/templates"
BOUNCER_CONF="${CONFIG_DIR}/crowdsec-openresty-bouncer.conf"
DEFAULT_CONF="${DEFAULTS_DIR}/crowdsec-openresty-bouncer.conf"
NGINX_SNIPPET="${DEFAULTS_DIR}/crowdsec_openresty.snippet"
NGINX_CONF="/etc/nginx/nginx.conf"

log() {
    echo "[crowdsec-init] $*"
}

# ---------------------------------------------------------------------------
# Step 0: Fix legacy paths from LePresidente migration
#   LePresidente used /config/ as the data root.  jc21 uses /data/.
#   Existing nginx config files reference /config/log/ — fix them.
#   Also create /data/logs symlink for jc21's fallback error log path.
# ---------------------------------------------------------------------------
if [ -d "/data/nginx" ]; then
    # Fix /config/log/ → /data/log/ in all existing nginx config files
    find /data/nginx -type f -name '*.conf' -exec sed -i 's|/config/log/|/data/log/|g' {} +
    log "Fixed legacy /config/log/ paths in nginx config files"
fi

# jc21's nginx.conf references /data/logs/ but the actual dir is /data/log/
if [ -d "/data/log" ] && [ ! -d "/data/logs" ]; then
    ln -sf log /data/logs
    log "Created /data/logs → /data/log symlink for jc21 compatibility"
fi

# ---------------------------------------------------------------------------
# Step 1: Ensure config directory and file exist
# ---------------------------------------------------------------------------
mkdir -p "${CONFIG_DIR}" "${TEMPLATES_CONFIG}"

if [ ! -f "${BOUNCER_CONF}" ]; then
    log "No existing bouncer config found — copying defaults to ${CONFIG_DIR}"
    cp "${DEFAULT_CONF}" "${BOUNCER_CONF}"
else
    # Merge new keys from defaults into the user's existing config.
    # This ensures that when the bouncer adds new config options in an
    # update, they appear in the user's file with their default values.
    log "Existing bouncer config found — checking for new default keys..."
    current_keys=$(grep -v '^\s*#' "${BOUNCER_CONF}" | grep '=' | sed 's/=.*//g' | sort)
    default_keys=$(grep -v '^\s*#' "${DEFAULT_CONF}" | grep '=' | sed 's/=.*//g' | sort)
    new_keys=$(comm -23 <(echo "$default_keys") <(echo "$current_keys"))
    if [ -n "$new_keys" ]; then
        log "Adding new config keys: ${new_keys}"
        grep -Ff <(echo "$new_keys") "${DEFAULT_CONF}" >> "${BOUNCER_CONF}"
    fi
fi

# ---------------------------------------------------------------------------
# Step 2: Copy new template files (idempotent — never overwrites)
# ---------------------------------------------------------------------------
for tmpl in "${TEMPLATES_DEFAULTS}"/*.html; do
    [ -f "$tmpl" ] || continue
    base=$(basename "$tmpl")
    if [ ! -f "${TEMPLATES_CONFIG}/${base}" ]; then
        log "Copying new template: ${base}"
        cp "$tmpl" "${TEMPLATES_CONFIG}/${base}"
    fi
done

# ---------------------------------------------------------------------------
# Step 3: Patch config with environment variables
# ---------------------------------------------------------------------------

# Enable/disable the bouncer
if [ "${CROWDSEC_ENABLED:-false}" = "true" ]; then
    log "Enabling CrowdSec bouncer via CROWDSEC_ENABLED=true"
    sed -i 's/^ENABLED=.*/ENABLED=true/' "${BOUNCER_CONF}"
else
    sed -i 's/^ENABLED=.*/ENABLED=false/' "${BOUNCER_CONF}"
fi

# Override API_URL and API_KEY if provided
if [ -n "${CROWDSEC_LAPI_URL:-}" ]; then
    log "Setting API_URL to ${CROWDSEC_LAPI_URL}"
    sed -i "s|^API_URL=.*|API_URL=${CROWDSEC_LAPI_URL}|" "${BOUNCER_CONF}"
fi

if [ -n "${CROWDSEC_API_KEY:-}" ]; then
    log "Setting API_KEY (masked)"
    sed -i "s|^API_KEY=.*|API_KEY=${CROWDSEC_API_KEY}|" "${BOUNCER_CONF}"
fi

# Merge CROWDSEC_CONFIG_CONTENT (multi-line KEY=VALUE string)
if [ -n "${CROWDSEC_CONFIG_CONTENT:-}" ]; then
    log "Merging custom config from CROWDSEC_CONFIG_CONTENT"
    while IFS= read -r line; do
        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        key=$(echo "$line" | cut -d'=' -f1)
        value=$(echo "$line" | cut -d'=' -f2-)
        if grep -q "^${key}=" "${BOUNCER_CONF}"; then
            sed -i "s|^${key}=.*|${key}=${value}|" "${BOUNCER_CONF}"
        else
            echo "${key}=${value}" >> "${BOUNCER_CONF}"
        fi
    done <<< "${CROWDSEC_CONFIG_CONTENT}"
fi

# ---------------------------------------------------------------------------
# Step 3b: Fix legacy template paths from LePresidente builds
#   LePresidente baked /tmp/crowdsec-openresty-bouncer-install/ paths into
#   the config. Also fix /var/lib/crowdsec/lua/templates paths from older
#   bouncer versions. Both need to point to /data/crowdsec/templates/.
# ---------------------------------------------------------------------------
TEMPLATE_DIR="${CONFIG_DIR}/templates"
sed -i "s|/tmp/crowdsec-openresty-bouncer-install/config/crowdsec//templates|${TEMPLATE_DIR}|g" "${BOUNCER_CONF}"
sed -i "s|/var/lib/crowdsec/lua/templates|${TEMPLATE_DIR}|g" "${BOUNCER_CONF}"
# Double-slash cleanup (LePresidente artifact: /config/crowdsec//templates)
sed -i 's|//templates|/templates|g' "${BOUNCER_CONF}"

# ---------------------------------------------------------------------------
# Step 4: Patch the nginx snippet to point to the correct config path
# ---------------------------------------------------------------------------
# The snippet references a hardcoded config path; update it to /data/crowdsec/
SNIPPET_RUNTIME="/tmp/crowdsec_openresty_runtime.snippet"
sed "s|/etc/crowdsec/bouncers/crowdsec-openresty-bouncer.conf|${BOUNCER_CONF}|" \
    "${NGINX_SNIPPET}" > "${SNIPPET_RUNTIME}"

# ---------------------------------------------------------------------------
# Step 5: Inject the CrowdSec snippet into nginx.conf http block
# ---------------------------------------------------------------------------
if [ "${CROWDSEC_ENABLED:-false}" = "true" ]; then
    if [ -f "${NGINX_CONF}" ]; then
        # Check if the snippet was already injected (idempotent)
        if ! grep -q 'crowdsec_cache' "${NGINX_CONF}"; then
            log "Injecting CrowdSec Lua snippet into ${NGINX_CONF} http block"

            # Read the snippet content
            SNIPPET_CONTENT=$(cat "${SNIPPET_RUNTIME}")

            # Use awk to insert the snippet right after the opening of the http block
            # We look for the line that starts the http { block and insert after it
            awk -v snippet="${SNIPPET_CONTENT}" '
            /^http[[:space:]]*\{/ {
                print
                print ""
                print "# === CrowdSec OpenResty Bouncer (auto-injected) ==="
                print snippet
                print "# === End CrowdSec ==="
                print ""
                next
            }
            { print }
            ' "${NGINX_CONF}" > "${NGINX_CONF}.tmp"

            mv "${NGINX_CONF}.tmp" "${NGINX_CONF}"
            log "CrowdSec snippet injected successfully"
        else
            log "CrowdSec snippet already present in nginx.conf — skipping injection"
        fi
    else
        log "WARNING: ${NGINX_CONF} not found — CrowdSec snippet will NOT be injected"
        log "         (This may happen if NPM has not yet generated its config)"
    fi
else
    # Remove any previously-injected snippet if bouncer is disabled
    if [ -f "${NGINX_CONF}" ] && grep -q 'crowdsec_cache' "${NGINX_CONF}"; then
        log "CrowdSec disabled — removing previously injected snippet from nginx.conf"
        sed -i '/# === CrowdSec OpenResty Bouncer/,/# === End CrowdSec ===/d' "${NGINX_CONF}"
    fi
fi

# Clean up
rm -f "${SNIPPET_RUNTIME}"

log "CrowdSec bouncer initialisation complete (ENABLED=${CROWDSEC_ENABLED:-false})"
