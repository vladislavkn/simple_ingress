# Ingress — Caddy + Cloudflare Tunnel

Reverse proxy setup that routes `*.yourdomain.com` to Docker services via Cloudflare Tunnel.

## Architecture

```
Internet → Cloudflare Edge (HTTPS) → Tunnel → cloudflared container → caddy container → service containers
```

All service containers connect to the shared `caddy-net` Docker network. No ports need to be published on the host.

## Prerequisites

- Docker with Compose plugin installed
- A domain with DNS managed by Cloudflare
- A Cloudflare Tunnel token ([dashboard](https://one.dash.cloudflare.com) → Networks → Tunnels → Create a tunnel)

## Quick Start

1. Edit `.env` with your domain and tunnel token.
2. Run `./manage.sh setup`
3. Run `./manage.sh start`
4. In Cloudflare Tunnel dashboard, add a wildcard public hostname:
   `*.yourdomain.com → http://caddy:80`

## Usage

```bash
./manage.sh setup                # Create docker network, validate .env
./manage.sh start                # Start Caddy + Cloudflare tunnel
./manage.sh stop                 # Stop everything
./manage.sh reload               # Reload Caddy after manual Caddyfile edits
./manage.sh add <subdomain>      # Add a service (prompts for upstream), reload
./manage.sh delete <subdomain>   # Remove a service, reload
./manage.sh list                 # List configured subdomains and upstreams
```

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

2. Start the service: `docker compose up -d`

3. Register it:

   ```bash
   ./manage.sh add myapp
   # Upstream: myapp:8080
   ```

   Done. `myapp.yourdomain.com` is now live.

## Files

| File                 | Purpose                               |
| -------------------- | ------------------------------------- |
| `manage.sh`          | Single entry point for all operations |
| `docker-compose.yml` | Caddy + cloudflared containers        |
| `Caddyfile`          | Routing rules per subdomain           |
| `.env`               | Domain and tunnel token               |
| `README.md`          | This file                             |
