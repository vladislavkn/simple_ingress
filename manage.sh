#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE="docker compose -f $SCRIPT_DIR/docker-compose.yaml"
CADDYFILE="$SCRIPT_DIR/Caddyfile"
ENV_FILE="$SCRIPT_DIR/.env"
CF_DIR="$SCRIPT_DIR/cloudflared"
CF_CONFIG="$CF_DIR/config.yaml"

# --- Helpers ---

load_env() {
    if [ ! -f "$ENV_FILE" ]; then
        echo "Error: .env file not found at $ENV_FILE"
        exit 1
    fi
    source "$ENV_FILE"
}

check_env() {
    load_env
    if [ -z "${DOMAIN:-}" ] || [ "$DOMAIN" = "example.com" ]; then
        echo "Error: Set DOMAIN in .env to your actual domain."
        exit 1
    fi
    if [ -z "${TUNNEL_NAME:-}" ]; then
        echo "Error: Set TUNNEL_NAME in .env."
        exit 1
    fi
}

check_tunnel_configured() {
    if ! grep -q "^tunnel:" "$CF_CONFIG" 2>/dev/null; then
        echo "Error: Tunnel not configured. Run '$0 setup' first."
        exit 1
    fi
}

get_tunnel_uuid() {
    grep "^tunnel:" "$CF_CONFIG" | awk '{print $2}'
}

reload_caddy() {
    if $COMPOSE exec caddy caddy validate --config /etc/caddy/Caddyfile 2>/dev/null; then
        $COMPOSE exec caddy caddy reload --config /etc/caddy/Caddyfile
        echo "Caddy reloaded."
    else
        echo "Error: Caddyfile has syntax errors. Fix before reloading."
        exit 1
    fi
}

restart_tunnel() {
    if is_tunnel_running; then
        $COMPOSE restart tunnel
        echo "Tunnel restarted."
    fi
}

is_caddy_running() {
    docker inspect -f '{{.State.Running}}' caddy 2>/dev/null | grep -q true
}

is_tunnel_running() {
    docker inspect -f '{{.State.Running}}' cloudflared 2>/dev/null | grep -q true
}

# --- Commands ---

cmd_setup() {
    echo "=== Ingress Setup ==="

    if ! command -v docker &>/dev/null; then
        echo "Error: docker is not installed."
        exit 1
    fi

    if ! command -v cloudflared &>/dev/null; then
        echo "Error: cloudflared CLI is not installed on the host."
        echo "Install: curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null"
        echo '  echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/cloudflared.list'
        echo "  sudo apt update && sudo apt install cloudflared"
        exit 1
    fi

    check_env
    mkdir -p "$CF_DIR"

    # Create docker network
    if ! docker network inspect caddy-net &>/dev/null; then
        echo "Creating caddy-net network..."
        docker network create caddy-net
    else
        echo "caddy-net network already exists."
    fi

    # Authenticate with Cloudflare if not already
    if [ ! -f "$HOME/.cloudflared/cert.pem" ]; then
        echo ""
        echo "Authenticating with Cloudflare..."
        echo "A browser URL will be printed — open it to log in."
        cloudflared tunnel login
    else
        echo "Cloudflare authentication found."
    fi

    # Create tunnel if it doesn't exist
    if cloudflared tunnel list 2>/dev/null | grep -q "$TUNNEL_NAME"; then
        echo "Tunnel '$TUNNEL_NAME' already exists."
        TUNNEL_UUID=$(cloudflared tunnel list 2>/dev/null | grep "$TUNNEL_NAME" | awk '{print $1}')
    else
        echo "Creating tunnel '$TUNNEL_NAME'..."
        cloudflared tunnel create "$TUNNEL_NAME"
        TUNNEL_UUID=$(cloudflared tunnel list 2>/dev/null | grep "$TUNNEL_NAME" | awk '{print $1}')
    fi

    echo "Tunnel UUID: $TUNNEL_UUID"

    # Copy credentials into cloudflared dir
    CREDS_SRC="$HOME/.cloudflared/${TUNNEL_UUID}.json"
    CREDS_DST="$CF_DIR/${TUNNEL_UUID}.json"
    if [ -f "$CREDS_SRC" ]; then
        cp "$CREDS_SRC" "$CREDS_DST"
        echo "Credentials copied to $CREDS_DST"
    elif [ -f "$CREDS_DST" ]; then
        echo "Credentials already in place."
    else
        echo "Error: Could not find credentials at $CREDS_SRC"
        exit 1
    fi

    # Write cloudflared config (preserve existing ingress rules if any)
    if grep -q "^tunnel:" "$CF_CONFIG" 2>/dev/null; then
        # Update tunnel and credentials-file lines in place
        sed -i "s|^tunnel:.*|tunnel: ${TUNNEL_UUID}|" "$CF_CONFIG"
        sed -i "s|^credentials-file:.*|credentials-file: /etc/cloudflared/${TUNNEL_UUID}.json|" "$CF_CONFIG"
    else
        # Fresh config — prepend tunnel info, strip template comments
        local tmp
        tmp=$(mktemp)
        cat > "$tmp" <<EOF
tunnel: ${TUNNEL_UUID}
credentials-file: /etc/cloudflared/${TUNNEL_UUID}.json

$(grep -v "^#" "$CF_CONFIG")
EOF
        mv "$tmp" "$CF_CONFIG"
    fi

    echo ""
    echo "=== Setup complete ==="
    echo "Tunnel: $TUNNEL_NAME ($TUNNEL_UUID)"
    echo "Domain: $DOMAIN"
    echo ""
    echo "Next: $0 start"
}

cmd_start() {
    check_env
    check_tunnel_configured
    echo "Starting ingress..."
    $COMPOSE up -d
    echo "Running. Domain: $DOMAIN"
}

cmd_stop() {
    echo "Stopping ingress..."
    $COMPOSE down
    echo "Stopped."
}

cmd_reload() {
    echo "Reloading Caddy..."
    reload_caddy
}

cmd_add() {
    local subdomain="$1"
    load_env
    check_tunnel_configured

    # Validate: alphanumeric and hyphens only
    if [[ ! "$subdomain" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
        echo "Error: Invalid subdomain '$subdomain'. Use lowercase alphanumeric and hyphens."
        exit 1
    fi

    local fqdn="${subdomain}.${DOMAIN}"

    # Check if already exists in Caddyfile
    if grep -qF "${fqdn}" "$CADDYFILE"; then
        echo "Error: $fqdn already exists."
        exit 1
    fi

    # Prompt for upstream
    read -rp "Upstream (e.g. container-name:8080): " upstream
    if [ -z "$upstream" ]; then
        echo "Error: Upstream cannot be empty."
        exit 1
    fi

    # 1. Add to Caddyfile
    cat >> "$CADDYFILE" <<EOF

${fqdn} {
    reverse_proxy ${upstream}
}
EOF
    echo "[Caddy] Added: $fqdn → $upstream"

    # 2. Add to cloudflared config (insert before the catch-all rule)
    sed -i "/^  - service: http_status:404/i\\  - hostname: ${fqdn}\n    service: http://caddy:80" "$CF_CONFIG"
    echo "[Tunnel] Added ingress: $fqdn → caddy:80"

    # 3. Add DNS record
    if command -v cloudflared &>/dev/null; then
        echo "[DNS] Creating CNAME for $fqdn..."
        cloudflared tunnel route dns "$TUNNEL_NAME" "$fqdn" 2>&1 || echo "  Warning: DNS route may already exist or failed. Check manually."
    else
        echo "[DNS] cloudflared not on host — add CNAME manually:"
        echo "  $fqdn → $(get_tunnel_uuid).cfargotunnel.com (proxied)"
    fi

    # 4. Reload/restart running services
    if is_caddy_running; then
        reload_caddy
    else
        echo "Caddy is not running. Start with '$0 start'."
    fi

    if is_tunnel_running; then
        restart_tunnel
    fi

    echo ""
    echo "Done. $fqdn is ready."
}

cmd_delete() {
    local subdomain="$1"
    load_env

    local fqdn="${subdomain}.${DOMAIN}"

    if ! grep -qF "${fqdn}" "$CADDYFILE"; then
        echo "Error: $fqdn not found in Caddyfile."
        exit 1
    fi

    # 1. Remove from Caddyfile (the block: fqdn line through closing brace)
    sed -i "/^${fqdn//./\\.} {/,/^}/d" "$CADDYFILE"
    echo "[Caddy] Removed: $fqdn"

    # 2. Remove from cloudflared config (hostname line + service line below it)
    sed -i "/^  - hostname: ${fqdn}$/{N;d;}" "$CF_CONFIG"
    echo "[Tunnel] Removed ingress: $fqdn"

    # 3. DNS: cloudflared has no "route dns delete" — inform user
    echo "[DNS] Remove the CNAME for $fqdn manually in the Cloudflare dashboard."

    # 4. Reload/restart running services
    if is_caddy_running; then
        reload_caddy
    fi

    if is_tunnel_running; then
        restart_tunnel
    fi

    echo ""
    echo "Done. $fqdn removed."
}

cmd_list() {
    load_env
    echo "Configured services:"
    echo ""

    local found=false
    grep -oP '^[a-z0-9.-]+(?= \{)' "$CADDYFILE" | grep -v "^:" | while read -r host; do
        found=true
        upstream=$(awk "/^${host//./\\.} \\{/,/^}/" "$CADDYFILE" | grep -oP 'reverse_proxy \K.+' || echo "???")
        printf "  https://%-30s → %s\n" "$host" "$upstream"
    done

    if [ "$found" = false ]; then
        echo "  (none)"
    fi
}

# --- Main ---

usage() {
    cat <<EOF
Usage: $0 <command> [args]

Commands:
  setup              Authenticate, create tunnel, configure credentials
  start              Start Caddy + Cloudflare tunnel
  stop               Stop all ingress services
  reload             Reload Caddy after manual Caddyfile edits
  add <subdomain>    Add service to Caddy + tunnel + DNS, reload
  delete <subdomain> Remove service from Caddy + tunnel, reload
  list               List configured subdomains
EOF
}

case "${1:-}" in
    setup)  cmd_setup ;;
    start)  cmd_start ;;
    stop)   cmd_stop ;;
    reload) cmd_reload ;;
    add)
        [ -z "${2:-}" ] && { echo "Usage: $0 add <subdomain>"; exit 1; }
        cmd_add "$2"
        ;;
    delete)
        [ -z "${2:-}" ] && { echo "Usage: $0 delete <subdomain>"; exit 1; }
        cmd_delete "$2"
        ;;
    list)   cmd_list ;;
    *)      usage; exit 1 ;;
esac