# Ingress — Caddy + Cloudflare Tunnel

Reverse proxy setup that routes `*.yourdomain.com` to Docker services via Cloudflare Tunnel.
All routing is managed locally via `manage.sh` — no need to touch the Cloudflare dashboard
after initial setup.

## Architecture

```
Internet → Cloudflare Edge (HTTPS) → Tunnel → cloudflared container → caddy container → service containers
```

All service containers connect to the shared `caddy-net` Docker network.
No ports need to be published on service containers.

## Prerequisites

- Docker with Compose plugin
- `cloudflared` CLI installed on the host (for tunnel creation and DNS management)
- A domain with DNS managed by Cloudflare

## Quick Start

```bash
# 1. Edit .env with your domain and tunnel name
cp .env.example .env
nano .env

# 2. Setup: authenticates with Cloudflare, creates tunnel, copies credentials
./manage.sh setup

# 3. Start Caddy + tunnel
./manage.sh start

# 4. Add your first service
./manage.sh add nextcloud
# Upstream: nextcloud-app:80
```

## Usage

```bash
./manage.sh setup                # Authenticate, create tunnel, configure credentials
./manage.sh start                # Start Caddy + Cloudflare tunnel
./manage.sh stop                 # Stop everything
./manage.sh reload               # Reload Caddy after manual Caddyfile edits
./manage.sh add <subdomain>      # Add service → updates Caddy + tunnel config + DNS
./manage.sh delete <subdomain>   # Remove service → updates Caddy + tunnel config
./manage.sh list                 # List configured subdomains and upstreams
```

## What `add` Does

When you run `./manage.sh add nextcloud`:

1. Prompts for the upstream (e.g. `nextcloud-app:80`)
2. Adds a block to `Caddyfile`
3. Adds an ingress rule to `cloudflared/config.yml`
4. Creates a DNS CNAME record via `cloudflared tunnel route dns`
5. Reloads Caddy and restarts the tunnel

## Adding a New Service

1. In the service's `docker-compose.yml`, give the public-facing container a
   `container_name` and attach it to `caddy-net`:

   ```yaml
   services:
     app:
       container_name: myapp
       networks:
         - internal
         - caddy-net
   networks:
     internal:
     caddy-net:
       external: true
   ```

2. Start the service:

   ```bash
   cd ~/apps/myapp && docker compose up -d
   ```

3. Register it:
   ```bash
   cd ~/apps/ingress && ./manage.sh add myapp
   # Upstream: myapp:8080
   ```

Done. `https://myapp.yourdomain.com` is live.

## Setting Up on a New Machine

1. Clone/copy this folder to `~/apps/ingress`.
2. Edit `.env` with your domain and tunnel name.
3. Run `./manage.sh setup` — it will:
   - Open a Cloudflare auth URL (first time only)
   - Create the tunnel (or reuse existing)
   - Copy credentials into `cloudflared/`
   - Write `cloudflared/config.yml`
4. Run `./manage.sh start`.

## Files

| File                      | Purpose                                           |
| ------------------------- | ------------------------------------------------- |
| `manage.sh`               | Single entry point for all operations             |
| `docker-compose.yml`      | Caddy + cloudflared containers                    |
| `Caddyfile`               | Caddy routing rules per subdomain                 |
| `.env`                    | Domain and tunnel name                            |
| `cloudflared/config.yml`  | Tunnel ingress rules (managed by `manage.sh`)     |
| `cloudflared/<uuid>.json` | Tunnel credentials (created by `manage.sh setup`) |
