#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE="docker compose -f $SCRIPT_DIR/docker-compose.yaml"
CADDYFILE="$SCRIPT_DIR/Caddyfile"
ENV_FILE="$SCRIPT_DIR/.env"

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
    if [ -z "${TUNNEL_TOKEN:-}" ] || [ "$TUNNEL_TOKEN" = "your-tunnel-token-here" ]; then
        echo "Error: Set TUNNEL_TOKEN in .env"
        echo "  1. Go to https://one.dash.cloudflare.com"
        echo "  2. Networks → Tunnels → Create a tunnel"
        echo "  3. Copy the token into .env"
        exit 1
    fi
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

# --- Commands ---

cmd_setup() {
    echo "=== Ingress Setup ==="

    if ! command -v docker &>/dev/null; then
        echo "Error: docker is not installed."
        exit 1
    fi

    check_env

    if ! docker network inspect caddy-net &>/dev/null; then
        echo "Creating caddy-net network..."
        docker network create caddy-net
    else
        echo "caddy-net network already exists."
    fi

    echo ""
    echo "Setup complete. Run '$0 start' to launch."
    echo ""
    echo "Don't forget to add a wildcard public hostname in Cloudflare Tunnel dashboard:"
    echo "  *.${DOMAIN} → http://caddy:80"
}

cmd_start() {
    check_env
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

    # Validate: alphanumeric and hyphens only
    if [[ ! "$subdomain" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
        echo "Error: Invalid subdomain '$subdomain'. Use lowercase alphanumeric and hyphens."
        exit 1
    fi

    # Check if already exists
    if grep -q "^${subdomain}\.\{\\\$DOMAIN\}" "$CADDYFILE"; then
        echo "Error: ${subdomain}.\$DOMAIN already exists in Caddyfile."
        exit 1
    fi

    # Prompt for upstream
    read -rp "Upstream (e.g. container-name:8080): " upstream
    if [ -z "$upstream" ]; then
        echo "Error: Upstream cannot be empty."
        exit 1
    fi

    # Append to Caddyfile
    cat >> "$CADDYFILE" <<EOF

${subdomain}.{\$DOMAIN} {
    reverse_proxy ${upstream}
}
EOF

    echo "Added: ${subdomain}.${DOMAIN} → ${upstream}"

    # Reload if Caddy is running
    if $COMPOSE ps --status running 2>/dev/null | grep -q caddy; then
        reload_caddy
    else
        echo "Caddy is not running. Start with '$0 start', then reload."
    fi
}

cmd_delete() {
    local subdomain="$1"
    load_env

    if ! grep -q "^${subdomain}\.\{\\\$DOMAIN\}" "$CADDYFILE"; then
        echo "Error: ${subdomain}.\$DOMAIN not found in Caddyfile."
        exit 1
    fi

    # Remove the block: blank line before + subdomain line + content + closing brace
    sed -i "/^$/N;/\n${subdomain}\.\{\\\$DOMAIN\}/,/^}/d" "$CADDYFILE"

    echo "Deleted: ${subdomain}.${DOMAIN}"

    if $COMPOSE ps --status running 2>/dev/null | grep -q caddy; then
        reload_caddy
    else
        echo "Caddy is not running. Changes will apply on next start."
    fi
}

cmd_list() {
    load_env
    echo "Configured services:"
    echo ""
    grep -oP '^[a-z0-9-]+(?=\.\{\$DOMAIN\})' "$CADDYFILE" | while read -r sub; do
        # Extract the upstream from the reverse_proxy line
        upstream=$(awk "/^${sub}\.\{\\\$DOMAIN\}/,/^}/" "$CADDYFILE" | grep -oP 'reverse_proxy \K.+' || echo "???")
        printf "  %-20s → %s\n" "${sub}.${DOMAIN}" "$upstream"
    done
}

# --- Main ---

usage() {
    cat <<EOF
Usage: $0 <command> [args]

Commands:
  setup              Initial setup (create network, check env)
  start              Start Caddy + Cloudflare tunnel
  stop               Stop all ingress services
  reload             Reload Caddy after Caddyfile changes
  add <subdomain>    Add a service subdomain and reload
  delete <subdomain> Remove a service subdomain and reload
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