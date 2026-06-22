# npm-crowdsec

[![NPM Version Check & Build](https://github.com/qubex22/npm-crowdsec/actions/workflows/npm-version-check.yml/badge.svg)](https://github.com/qubex22/npm-crowdsec/actions/workflows/npm-version-check.yml)

A Docker image that layers the [CrowdSec OpenResty Bouncer](https://github.com/crowdsecurity/cs-openresty-bouncer) on top of the official [jc21/nginx-proxy-manager](https://github.com/NginxProxyManager/nginx-proxy-manager) image.

No forking — just a Dockerfile that builds on the upstream image and can be rebuilt in seconds whenever it updates.

## Architecture

```
+--------------------------------------------------+
|  npm-crowdsec                                     |
|                                                    |
|  Build-time:                                      |
|    - lua-resty-http (via opm)                     |
|    - CrowdSec Lua libs -> /etc/nginx/lualib/      |
|    - Response templates -> /defaults/crowdsec/    |
|    - Default bouncer config                        |
|                                                    |
|  Runtime (before nginx starts):                    |
|    1. Copy/merge bouncer config -> /data/crowdsec/ |
|    2. Patch config with environment variables      |
|    3. Inject CrowdSec Lua snippet into nginx.conf  |
|    4. Start nginx                                  |
+--------------------------------------------------+
               |
               v
+--------------------------------------------------+
|  jc21/nginx-proxy-manager:latest                  |
|  (NPM, Node.js, OpenResty, Certbot, s6-overlay)   |
+--------------------------------------------------+
```

## Quick Start

### Build Locally

```bash
docker build -t npm-crowdsec:latest .
```

### Run with Docker Compose

Copy [`docker-compose.example.yml`](docker-compose.example.yml) to `docker-compose.yml`, set your API key, and go:

```yaml
services:
  crowdsec:
    image: crowdsecurity/crowdsec:latest
    environment:
      GID: "${GID:-1000}"
      COLLECTIONS: "crowdsecurity/linux crowdsecurity/nginx"
    volumes:
      - crowdsec-data:/var/lib/crowdsec
      - crowdsec-config:/etc/crowdsec
    restart: unless-stopped

  npm:
    image: npm-crowdsec:latest
    depends_on: [crowdsec]
    environment:
      DB_SQLITE_FILE: "/data/database.sqlite"
      TZ: "${TZ:-UTC}"
      CROWDSEC_ENABLED: "true"
      CROWDSEC_LAPI_URL: "http://crowdsec:8080"
      CROWDSEC_API_KEY: "your-bouncer-api-key-here"
    ports:
      - "80:80"
      - "443:443"
      - "8181:81"   # NPM admin panel
    volumes:
      - npm-data:/data
    restart: unless-stopped

volumes:
  npm-data:
  crowdsec-data:
  crowdsec-config:
```

### Generate a Bouncer API Key

After starting the CrowdSec container:

```bash
docker exec crowdsec cscli bouncers add npm-bouncer
```

Copy the returned key and set it as `CROWDSEC_API_KEY` in your compose file.

## Configuration

### Environment Variables

| Variable | Default | Description |
|---|---|---|
| `CROWDSEC_ENABLED` | `false` | Set to `true` to enable the bouncer |
| `CROWDSEC_LAPI_URL` | `http://127.0.0.1:8080` | CrowdSec Local API URL |
| `CROWDSEC_API_KEY` | *(empty)* | API key for bouncer authentication |
| `CROWDSEC_CONFIG_CONTENT` | *(empty)* | Multi-line `KEY=VALUE` string to merge into config |
| `DB_SQLITE_FILE` | `/data/database.sqlite` | SQLite database path (NPM) |
| `TZ` | `UTC` | Timezone |

Example with extra config:

```yaml
environment:
  CROWDSEC_ENABLED: "true"
  CROWDSEC_LAPI_URL: "http://crowdsec:8080"
  CROWDSEC_API_KEY: "my-key"
  CROWDSEC_CONFIG_CONTENT: |
    MODE=stream
    REQUEST_TIMEOUT=5000
    EXCLUDE_LOCATION=/health,/metrics
```

### Direct Config File Editing

Edit the bouncer config in your mounted volume:

```
./npm/data/crowdsec/crowdsec-openresty-bouncer.conf
```

On next container start, new keys from upstream defaults are merged in automatically. Your existing values are always preserved.

### Key Bouncer Options

| Config Key | Description |
|---|---|
| `ENABLED` | `true`/`false` — master on/off switch |
| `API_URL` | CrowdSec Local API URL |
| `API_KEY` | Authentication key |
| `MODE` | `live` (default) or `stream` (faster, long-polling) |
| `REQUEST_TIMEOUT` | Timeout for API calls in ms (default: 3000) |
| `UPDATE_FREQUENCY` | Cache refresh interval in seconds (default: 10) |
| `BAN_TEMPLATE_PATH` | Path to ban response HTML template |
| `CAPTCHA_PROVIDER` | `recaptcha`, `hcaptcha`, or `turnstile` |
| `EXCLUDE_LOCATION` | Comma-separated paths to exclude from bouncing |

## Rebuilding After Upstream Updates

```bash
# 1. Pull the latest upstream image
docker pull jc21/nginx-proxy-manager:latest

# 2. Rebuild
docker build -t npm-crowdsec:latest .

# 3. Recreate your container (data volume is preserved)
docker compose up -d --force-recreate npm
```

**Your `/data/` volume is never touched by a rebuild.** All user data, NPM database, SSL certificates, and CrowdSec config survive the image update.

### Updating the CrowdSec Bouncer Version

```bash
docker build --build-arg CROWDSEC_OPENRESTY_BOUNCER_VERSION=1.2.0 -t npm-crowdsec:latest .
```

## File Layout Inside the Image

```
/etc/nginx/
+-- nginx.conf                          # Generated by NPM (CrowdSec injected at runtime)
+-- lualib/
    +-- crowdsec.lua                    # Bouncer main module
    +-- resty/http*.lua                 # lua-resty-http dependency
    +-- plugins/crowdsec/               # Bouncer plugin modules

/defaults/crowdsec/                     # Build-time defaults (read-only)
+-- crowdsec-openresty-bouncer.conf     # Default bouncer config
+-- crowdsec_openresty.snippet          # nginx Lua snippet template
+-- templates/
    +-- ban.html
    +-- captcha.html

/data/crowdsec/                         # Runtime config (mounted volume)
+-- crowdsec-openresty-bouncer.conf     # Active config (user-editable)
+-- templates/                          # Custom response templates
```

## GitHub Actions

A [GitHub Action](.github/workflows/npm-version-check.yml) runs weekly to check for new Nginx Proxy Manager releases on Docker Hub. When a newer version is detected, it automatically:

1. Builds a new `npm-crowdsec` image
2. Pushes it to your configured registry
3. Creates a GitHub release with pull instructions

### Setup

1. Fork or clone this repository
2. In **Settings > Secrets and variables > Actions**, add:
   - `DOCKER_REGISTRY` — e.g. `ghcr.io` or `docker.io/youruser`
   - `DOCKER_USERNAME` — your registry username
   - `DOCKER_PASSWORD` — your registry password or access token
3. The workflow runs every Monday at 06:00 UTC, or manually via **Actions > Run workflow**

### Manual Dispatch

You can trigger a build on demand with optional inputs:

- **Force build** — build even if no new NPM version is available
- **CrowdSec version** — override the bouncer version for this build

## Troubleshooting

### Bouncer Not Blocking

```bash
# Check the config
docker exec npm cat /data/crowdsec/crowdsec-openresty-bouncer.conf | grep -E "^(ENABLED|API_URL|API_KEY)="

# Verify snippet was injected
docker exec npm grep crowdsec_cache /etc/nginx/nginx.conf

# Check logs
docker logs npm 2>&1 | grep -i crowdsec
```

### Nginx Fails to Start

```bash
# Test nginx config validity
docker exec npm nginx -t

# Check init script logs
docker logs npm 2>&1 | grep crowdsec-init
```

### Reset CrowdSec Config

```bash
rm -rf ./npm/data/crowdsec/
docker compose restart npm
```

## Credits

- [jc21/nginx-proxy-manager](https://github.com/NginxProxyManager/nginx-proxy-manager) — Nginx Proxy Manager
- [NginxProxyManager/docker-nginx-full](https://github.com/NginxProxyManager/docker-nginx-full) — Official OpenResty base image
- [crowdsecurity/cs-openresty-bouncer](https://github.com/crowdsecurity/cs-openresty-bouncer) — CrowdSec OpenResty Bouncer
