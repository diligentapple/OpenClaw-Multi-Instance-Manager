#!/usr/bin/env bash
set -euo pipefail

usage() { echo "Usage: openclaw-health N"; }

N="${1:-}"
[[ "$N" =~ ^[0-9]+$ ]] || { usage; exit 1; }

CONTAINER="openclaw${N}-gateway"

if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER"; then
  echo "Error: container '$CONTAINER' is not running."
  echo "Use 'openclaw-list' to see running instances."
  exit 1
fi

# Use Docker's built-in health status (runs inside the container, so it works
# regardless of the gateway's bind mode — loopback-bound gateways are not
# reachable from the host through Docker port forwarding).
health=$(docker inspect --format='{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null || echo "unknown")

case "$health" in
  healthy)
    API_PORT=$(docker port "$CONTAINER" 18789/tcp 2>/dev/null | head -1 | awk -F: '{print $NF}' || true)
    echo "Instance #$N is healthy (port ${API_PORT:-18789})."
    ;;
  starting)
    echo "Instance #$N is still starting up..."
    exit 1
    ;;
  *)
    echo "Instance #$N is not healthy (status: $health)."
    echo "  Check logs: openclaw-logs $N --tail 20"
    exit 1
    ;;
esac
