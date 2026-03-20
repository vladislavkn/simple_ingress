# Ingress — Cloudflare Tunnel

Routes `*.yourdomain.com` to Docker containers via Cloudflare Tunnel.
No reverse proxy needed — cloudflared routes directly to each service.

## Architecture

```
Internet → Cloudflare (HTTPS) → Tunnel → cloudflared → service containers
```

Cloudflare terminates TLS at the edge. Internally, everything is plain HTTP
over a shared Docker network (`tunnel-net`).

## Prerequisites

- Docker with Compose plugin
- `cloudflared` CLI on the host (for tunnel creation and DNS management)
- A domain with DNS managed by Cloudflare

## Quick Start

```bash
nano .env                    # set DOMAIN and TUNNEL_NAME
./manage.sh setup            # authenticate, create tunnel, generate config
./manage.sh start            # launch cloudflared container
./manage.sh add nextcloud    # register service, create DNS, restart tunnel
```

## Commands

```bash
./manage.sh setup              # one-time: auth + tunnel creation + credentials
./manage.sh start              # start the tunnel container
./manage.sh stop               # stop the tunnel container
./manage.sh add <subdomain>    # register service → DNS + config + restart
./manage.sh delete <subdomain> # unregister service → config + restart
./manage.sh list               # show registered services
./manage.sh sync               # regenerate config.yaml from services.conf
```

All commands are idempotent.

## How `add` Works

`./manage.sh add nextcloud` does three things:

1. Appends `nextcloud=nextcloud-app:80` to `services.conf`
2. Creates a DNS CNAME via `cloudflared tunnel route dns`
3. Regenerates `cloudflared/config.yaml` and restarts the tunnel

## Connecting a Service

A service needs two things: a `container_name` and the `tunnel-net` network.

```yaml
# ~/apps/nextcloud/docker-compose.yaml
services:
  db:
    image: mariadb
    restart: always
    environment:
      MYSQL_ROOT_PASSWORD: changeme
      MYSQL_DATABASE: nextcloud
      MYSQL_USER: nextcloud
      MYSQL_PASSWORD: changeme
    volumes:
      - db_data:/var/lib/mysql
    networks:
      - internal

  app:
    image: nextcloud
    container_name: nextcloud-app   # ← cloudflared routes to this name
    restart: always
    environment:
      MYSQL_HOST: db
      MYSQL_DATABASE: nextcloud
      MYSQL_USER: nextcloud
      MYSQL_PASSWORD: changeme
    volumes:
      - app_data:/var/www/html
    depends_on:
      - db
    networks:
      - internal
      - tunnel-net                  # ← shared network

volumes:
  db_data:
  app_data:

networks:
  internal:
  tunnel-net:
    external: true
```

Then:

```bash
cd ~/apps/nextcloud && docker compose up -d
cd ~/apps/ingress && ./manage.sh add nextcloud
# Upstream: nextcloud-app:80
```

`https://nextcloud.yourdomain.com` is live.

## Setting Up on a New Machine

1. Copy this folder
2. Edit `.env`
3. `./manage.sh setup` (opens browser for Cloudflare auth)
4. `./manage.sh start`
5. Existing `services.conf` entries are picked up automatically

## Design Decisions

**Why no reverse proxy (Caddy/Traefik)?**
Cloudflared already routes by hostname. Adding Caddy means double config,
HTTPS cert issues (Caddy tries Let's Encrypt, which fails behind a tunnel),
and an extra network hop. For a homelab behind Cloudflare, it's unnecessary.

If you later need advanced features (rate limiting, auth middleware, rewrites),
add Traefik. It auto-discovers Docker containers via labels, so you wouldn't
need to manage a Caddyfile. But for basic routing, cloudflared alone is enough.

**Why `services.conf` instead of editing YAML directly?**
`config.yaml` is always regenerated from `services.conf`. This avoids fragile
sed/awk YAML editing in bash and makes every operation idempotent. Run
`./manage.sh sync` at any time to reconcile.

## Files

```
├── manage.sh              # all operations
├── docker-compose.yaml    # cloudflared container
├── .env                   # DOMAIN and TUNNEL_NAME
├── services.conf          # subdomain=container:port registry
├── cloudflared/
│   ├── config.yaml        # generated — do not edit manually
│   ├── uuid               # tunnel UUID
│   └── <uuid>.json        # tunnel credentials
└── README.md
```
