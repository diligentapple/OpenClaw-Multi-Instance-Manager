#!/usr/bin/env bash
set -euo pipefail

usage() { echo "Usage: openclaw-onboard N"; }

N="${1:-}"
[[ "$N" =~ ^[0-9]+$ ]] || { usage; exit 1; }

HOME_DIR="${HOME:-/root}"
INSTANCE_DIR="${HOME_DIR}/openclaw${N}"
DATA_DIR="${HOME_DIR}/.openclaw${N}"
COMPOSE_FILE="${INSTANCE_DIR}/docker-compose.yml"

if [[ ! -d "$DATA_DIR" ]]; then
  echo "Data directory $DATA_DIR not found. Run openclaw-new $N first."
  exit 1
fi

if [[ ! -f "$COMPOSE_FILE" ]]; then
  echo "Compose file $COMPOSE_FILE not found. Run openclaw-new $N first."
  exit 1
fi

COMPOSE_BIN="docker compose"
if ! docker compose version >/dev/null 2>&1; then
  COMPOSE_BIN="docker-compose"
fi

echo "Running onboarding for instance #$N..."
$COMPOSE_BIN -f "$COMPOSE_FILE" run --rm openclaw-cli onboard --mode local

# Always enable insecure auth so HTTP fallback URLs work without HTTPS
CONFIG="${DATA_DIR}/openclaw.json"
if [[ -f "$CONFIG" ]]; then
  local_tmp=$(mktemp)
  if sudo jq '.gateway.controlUi.allowInsecureAuth = true' "$CONFIG" > "$local_tmp" && jq empty "$local_tmp" 2>/dev/null; then
    owner=$(sudo stat -c '%u:%g' "$CONFIG")
    sudo mv "$local_tmp" "$CONFIG"
    sudo chown "$owner" "$CONFIG"
  else
    rm -f "$local_tmp"
  fi
fi
