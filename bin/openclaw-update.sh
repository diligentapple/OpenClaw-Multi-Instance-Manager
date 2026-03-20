#!/usr/bin/env bash
set -euo pipefail

usage() { echo "Usage: openclaw-update N"; }

N="${1:-}"
[[ "$N" =~ ^[0-9]+$ ]] || { usage; exit 1; }

HOME_DIR="${HOME:-/root}"
INSTANCE_DIR="${HOME_DIR}/openclaw${N}"
DATA_DIR="${HOME_DIR}/.openclaw${N}"
COMPOSE_FILE="${INSTANCE_DIR}/docker-compose.yml"
CONTAINER="openclaw${N}-gateway"

COMPOSE_BIN="docker compose"
if ! docker compose version >/dev/null 2>&1; then
  COMPOSE_BIN="docker-compose"
fi

[[ -f "$COMPOSE_FILE" ]] || { echo "Missing: $COMPOSE_FILE"; exit 1; }

# 1. Backup config before updating
CONFIG="${DATA_DIR}/openclaw.json"
if [[ -f "$CONFIG" ]]; then
  backup="${CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
  sudo cp "$CONFIG" "$backup"
  echo "Config backed up to $backup"
fi

# 2. Pull latest image
echo "Pulling latest OpenClaw image..."
docker pull ghcr.io/openclaw/openclaw:latest

# 2b. Re-render docker-compose template (picks up template improvements)
TEMPLATE="${OPENCLAW_MGR_TEMPLATE:-/usr/local/share/openclaw-manager/templates/docker-compose.yml.tmpl}"
if [[ -f "$TEMPLATE" ]]; then
  API_PORT=$(grep -oP '"\K\d+(?=:18789")' "$COMPOSE_FILE" | head -1)
  WS_PORT=$(grep -oP '"\K\d+(?=:18790")' "$COMPOSE_FILE" | head -1)
  TZ=$(grep -oP 'TZ:\s*\K\S+' "$COMPOSE_FILE" | head -1)
  TZ="${TZ:-Asia/Tokyo}"
  if [[ -n "$API_PORT" && -n "$WS_PORT" ]]; then
    echo "Re-rendering docker-compose template..."
    sed \
      -e "s/{{N}}/${N}/g" \
      -e "s/{{API_PORT}}/${API_PORT}/g" \
      -e "s/{{WS_PORT}}/${WS_PORT}/g" \
      -e "s#{{DATA_DIR}}#${DATA_DIR}#g" \
      -e "s#{{TZ}}#${TZ}#g" \
      "$TEMPLATE" > "$COMPOSE_FILE"
  fi
fi

# 3. Recreate container with new image
$COMPOSE_BIN -f "$COMPOSE_FILE" up -d --force-recreate

# 4. Wait for container to be ready
echo "Waiting for container to start..."
local_tries=0
while ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER" && [[ $local_tries -lt 15 ]]; do
  sleep 1
  ((local_tries++)) || true
done

# 5. Run doctor to handle config migrations
if docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  echo "Running config migration (doctor)..."
  docker exec "$CONTAINER" node /app/dist/index.js doctor 2>/dev/null || true

  # 6. Restart gateway to pick up migrated config
  echo "Restarting gateway..."
  docker restart "$CONTAINER" >/dev/null 2>&1

  # 7. Verify health (retry for up to 30s to allow startup + lsof install)
  API_PORT=$(docker port "$CONTAINER" 18789/tcp 2>/dev/null | head -1 | awk -F: '{print $NF}' || true)
  if [[ -n "$API_PORT" ]]; then
    healthy=false
    for i in $(seq 1 15); do
      if curl -sf "http://127.0.0.1:${API_PORT}/healthz" >/dev/null 2>&1; then
        healthy=true
        break
      fi
      sleep 2
    done
    if $healthy; then
      echo "Instance #$N updated and healthy."
    else
      echo "Instance #$N updated but health check failed."
      echo "  Check logs: openclaw-logs $N --tail 20"
    fi
  else
    echo "Instance #$N updated but could not determine port."
    echo "  Check logs: openclaw-logs $N --tail 20"
  fi
else
  echo "Warning: container did not start. Check: openclaw-logs $N"
fi
