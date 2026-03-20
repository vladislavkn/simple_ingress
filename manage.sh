#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE="docker compose -f $SCRIPT_DIR/docker-compose.yaml"
ENV_FILE="$SCRIPT_DIR/.env"
SERVICES_FILE="$SCRIPT_DIR/services.conf"
CF_DIR="$SCRIPT_DIR/cloudflared"
CF_CONFIG="$CF_DIR/config.yaml"
UUID_FILE="$CF_DIR/uuid"

# ── Helpers ──────────────────────────────────────────────────

load_env() {
    [ -f "$ENV_FILE" ] || { echo "Error: .env not found."; exit 1; }
    source "$ENV_FILE"
    [ -n "${DOMAIN:-}" ] && [ "$DOMAIN" != "example.com" ] || { echo "Error: Set DOMAIN in .env."; exit 1; }
    [ -n "${TUNNEL_NAME:-}" ] || { echo "Error: Set TUNNEL_NAME in .env."; exit 1; }
}

require_uuid() {
    [ -f "$UUID_FILE" ] || { echo "Error: Tunnel not configured. Run '$0 setup' first."; exit 1; }
    TUNNEL_UUID=$(<"$UUID_FILE")
    [ -n "$TUNNEL_UUID" ] || { echo "Error: Empty UUID file. Run '$0 setup' again."; exit 1; }
}

tunnel_running() {
    docker inspect -f '{{.State.Running}}' cloudflared 2>/dev/null | grep -q true
}

# Regenerate config.yaml from services.conf (the only way config.yaml is ever written)
generate_config() {
    require_uuid
    load_env

    {
        echo "tunnel: ${TUNNEL_UUID}"
        echo "credentials-file: /etc/cloudflared/${TUNNEL_UUID}.json"
        echo ""
        echo "ingress:"

        if [ -f "$SERVICES_FILE" ]; then
            while IFS='=' read -r subdomain upstream; do
                subdomain=$(echo "$subdomain" | xargs)  # trim whitespace
                upstream=$(echo "$upstream" | xargs)
                [ -z "$subdomain" ] && continue
                [[ "$subdomain" == \#* ]] && continue
                echo "  - hostname: ${subdomain}.${DOMAIN}"
                echo "    service: http://${upstream}"
            done < "$SERVICES_FILE"
        fi

        echo "  - service: http_status:404"
    } > "$CF_CONFIG"

    chmod 644 "$CF_CONFIG"
    chmod 644 "$CF_DIR"/*.json 2>/dev/null || true
    chmod 755 "$CF_DIR"
}

restart_if_running() {
    if tunnel_running; then
        $COMPOSE restart tunnel
        echo "Tunnel restarted."
    fi
}

# ── Commands ─────────────────────────────────────────────────

cmd_setup() {
    echo "=== Ingress Setup ==="
    load_env

    command -v docker &>/dev/null || { echo "Error: docker not installed."; exit 1; }
    command -v cloudflared &>/dev/null || {
        echo "Error: cloudflared CLI not installed."
        echo "  curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null"
        echo "  echo \"deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared \$(lsb_release -cs) main\" | sudo tee /etc/apt/sources.list.d/cloudflared.list"
        echo "  sudo apt update && sudo apt install cloudflared"
        exit 1
    }

    # Network (idempotent)
    if docker network inspect tunnel-net &>/dev/null; then
        echo "Network tunnel-net exists."
    else
        docker network create tunnel-net
        echo "Created tunnel-net network."
    fi

    # Auth (idempotent)
    if [ -f "$HOME/.cloudflared/cert.pem" ]; then
        echo "Cloudflare auth found."
    else
        echo "Opening browser for Cloudflare login..."
        cloudflared tunnel login
    fi

    # Tunnel (idempotent)
    mkdir -p "$CF_DIR"
    local uuid
    uuid=$(cloudflared tunnel list --output json 2>/dev/null \
        | python3 -c "import sys,json; tunnels=json.load(sys.stdin); print(next((t['id'] for t in tunnels if t['name']=='$TUNNEL_NAME'),'' ))" 2>/dev/null || echo "")

    if [ -n "$uuid" ]; then
        echo "Tunnel '$TUNNEL_NAME' exists (${uuid})."
    else
        cloudflared tunnel create "$TUNNEL_NAME"
        uuid=$(cloudflared tunnel list --output json 2>/dev/null \
            | python3 -c "import sys,json; tunnels=json.load(sys.stdin); print(next(t['id'] for t in tunnels if t['name']=='$TUNNEL_NAME'))")
        echo "Created tunnel '$TUNNEL_NAME' (${uuid})."
    fi

    echo "$uuid" > "$UUID_FILE"

    # Credentials (idempotent)
    local src="$HOME/.cloudflared/${uuid}.json"
    local dst="$CF_DIR/${uuid}.json"
    if [ -f "$src" ]; then
        cp "$src" "$dst"
        echo "Credentials copied."
    elif [ -f "$dst" ]; then
        echo "Credentials already in place."
    else
        echo "Error: Credentials not found at $src"
        exit 1
    fi

    generate_config

    echo ""
    echo "=== Setup complete ==="
    echo "Tunnel: $TUNNEL_NAME ($uuid)"
    echo "Domain: $DOMAIN"
    echo "Next:   $0 start"
}

cmd_start() {
    load_env
    require_uuid
    generate_config
    $COMPOSE up -d
    echo "Running. Domain: $DOMAIN"
}

cmd_stop() {
    $COMPOSE down
    echo "Stopped."
}

cmd_add() {
    local subdomain="$1"
    load_env
    require_uuid

    # Validate
    if [[ ! "$subdomain" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
        echo "Error: Invalid subdomain '$subdomain'. Use lowercase a-z, 0-9, hyphens."
        exit 1
    fi

    # Idempotent: skip if already registered
    if grep -q "^${subdomain}=" "$SERVICES_FILE" 2>/dev/null; then
        echo "Error: '${subdomain}' already registered."
        echo "  To update, delete first: $0 delete $subdomain"
        exit 1
    fi

    read -rp "Upstream (container:port, e.g. nextcloud-app:80): " upstream
    [ -n "$upstream" ] || { echo "Error: Upstream cannot be empty."; exit 1; }

    # Register
    echo "${subdomain}=${upstream}" >> "$SERVICES_FILE"
    echo "Registered: ${subdomain}.${DOMAIN} → ${upstream}"

    # DNS (idempotent — cloudflared skips if CNAME exists)
    echo "Creating DNS record..."
    cloudflared tunnel route dns "$TUNNEL_NAME" "${subdomain}.${DOMAIN}" 2>&1 \
        || echo "  Warning: DNS may already exist or failed. Check Cloudflare dashboard."

    # Regenerate and restart
    generate_config
    restart_if_running

    echo "Done. https://${subdomain}.${DOMAIN}"
}

cmd_delete() {
    local subdomain="$1"
    load_env

    if ! grep -q "^${subdomain}=" "$SERVICES_FILE" 2>/dev/null; then
        echo "Error: '${subdomain}' not found in services.conf."
        exit 1
    fi

    # Remove from registry
    grep -v "^${subdomain}=" "$SERVICES_FILE" > "$SERVICES_FILE.tmp"
    mv "$SERVICES_FILE.tmp" "$SERVICES_FILE"
    echo "Removed: ${subdomain}.${DOMAIN}"

    # Regenerate and restart
    generate_config
    restart_if_running

    echo "Note: Delete the DNS CNAME for ${subdomain}.${DOMAIN} manually in Cloudflare dashboard."
    echo "Done."
}

cmd_list() {
    load_env
    echo "Services:"
    echo ""

    local count=0
    while IFS='=' read -r subdomain upstream; do
        subdomain=$(echo "$subdomain" | xargs)
        upstream=$(echo "$upstream" | xargs)
        [ -z "$subdomain" ] && continue
        [[ "$subdomain" == \#* ]] && continue
        printf "  https://%-35s → %s\n" "${subdomain}.${DOMAIN}" "$upstream"
        count=$((count + 1))
    done < "$SERVICES_FILE"

    [ "$count" -eq 0 ] && echo "  (none)"
}

cmd_sync() {
    load_env
    require_uuid
    generate_config
    restart_if_running
    echo "Config regenerated and tunnel restarted."
}

# ── Main ─────────────────────────────────────────────────────

usage() {
    cat <<EOF
Usage: $0 <command> [args]

  setup              Create tunnel, configure credentials
  start              Start the tunnel
  stop               Stop the tunnel
  add <subdomain>    Register a service, create DNS, restart tunnel
  delete <subdomain> Unregister a service, restart tunnel
  list               Show registered services
  sync               Regenerate config from services.conf and restart
EOF
}

case "${1:-}" in
    setup)  cmd_setup ;;
    start)  cmd_start ;;
    stop)   cmd_stop ;;
    add)    [ -n "${2:-}" ] || { echo "Usage: $0 add <subdomain>"; exit 1; }; cmd_add "$2" ;;
    delete) [ -n "${2:-}" ] || { echo "Usage: $0 delete <subdomain>"; exit 1; }; cmd_delete "$2" ;;
    list)   cmd_list ;;
    sync)   cmd_sync ;;
    *)      usage; exit 1 ;;
esac
