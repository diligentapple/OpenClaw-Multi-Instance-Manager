#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: openclaw-delete N|N-M"
  echo "Example: openclaw-delete 3"
  echo "         openclaw-delete 2-4    (delete instances 2, 3, 4)"
}

is_int() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }

RANGE_ARG="${1:-}"

# Parse N or N-M range
if [[ "$RANGE_ARG" =~ ^([0-9]+)-([0-9]+)$ ]]; then
  RANGE_START="${BASH_REMATCH[1]}"
  RANGE_END="${BASH_REMATCH[2]}"
  if [[ "$RANGE_START" -lt 1 || "$RANGE_END" -lt "$RANGE_START" ]]; then
    echo "Error: invalid range $RANGE_ARG (start must be >= 1 and <= end)"
    exit 1
  fi
elif is_int "$RANGE_ARG" && [[ "$RANGE_ARG" -ge 1 ]]; then
  RANGE_START="$RANGE_ARG"
  RANGE_END="$RANGE_ARG"
else
  usage; exit 1
fi

HOME_DIR="${HOME:-/root}"

# Verify Docker daemon is reachable (catches missing docker group membership)
if ! docker info >/dev/null 2>&1; then
  echo "Error: cannot connect to the Docker daemon."
  echo "If Docker is running, add your user to the docker group:"
  echo "  sudo usermod -aG docker \$USER"
  echo "Then log out and back in (or run: newgrp docker)."
  exit 1
fi

COMPOSE_BIN="docker compose"
if ! docker compose version >/dev/null 2>&1; then
  COMPOSE_BIN="docker-compose"
fi

# Collect instances that actually exist
TARGETS=()
for (( i=RANGE_START; i<=RANGE_END; i++ )); do
  idir="${HOME_DIR}/openclaw${i}"
  ddir="${HOME_DIR}/.openclaw${i}"
  if [[ -d "$idir" || -d "$ddir" ]]; then
    TARGETS+=("$i")
  fi
done

if [[ ${#TARGETS[@]} -eq 0 ]]; then
  echo "No instances found in range ${RANGE_START}-${RANGE_END}."
  exit 1
fi

# Show what will be deleted
echo "About to DELETE the following OpenClaw instances:"
for n in "${TARGETS[@]}"; do
  echo "  #$n  (openclaw${n}/ .openclaw${n}/)"
done
echo ""
read -r -p "Type DELETE to confirm: " CONFIRM
if [[ "$CONFIRM" != "DELETE" ]]; then
  echo "Aborted."
  exit 1
fi

# ---------------------------------------------------------------------------
# Delete each instance
# ---------------------------------------------------------------------------

delete_instance() {
  local N="$1"
  local INSTANCE_DIR="${HOME_DIR}/openclaw${N}"
  local DATA_DIR="${HOME_DIR}/.openclaw${N}"
  local CONTAINER="openclaw${N}-gateway"
  local PROJECT="openclaw${N}"

  # Tailscale serve cleanup — try live docker port, then compose file
  if command -v tailscale >/dev/null 2>&1; then
    local API_PORT=""
    API_PORT=$(docker port "$CONTAINER" 18789/tcp 2>/dev/null | head -1 | awk -F: '{print $NF}' || echo "")
    if [[ -z "$API_PORT" ]]; then
      API_PORT=$(grep -oP '"\K[0-9]+(?=:18789")' "${INSTANCE_DIR}/docker-compose.yml" 2>/dev/null || echo "")
    fi
    if [[ -n "$API_PORT" ]]; then
      sudo tailscale serve --https="$API_PORT" off 2>/dev/null || true
    fi
  fi

  # Stop + remove container. Try compose first (cleanest — also removes
  # compose-managed networks and volumes), then force-remove as fallback in
  # case compose state is corrupt or the container was created outside compose.
  if [[ -f "${INSTANCE_DIR}/docker-compose.yml" ]]; then
    $COMPOSE_BIN -f "${INSTANCE_DIR}/docker-compose.yml" down -v --remove-orphans --timeout 10 >/dev/null 2>&1 || true
  fi
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true

  # Remove any orphan containers/networks that carry this project's label.
  # Belt-and-suspenders: compose down above usually handles these, but a
  # corrupt compose file or manual rename would leave them behind.
  local orphan_cids
  orphan_cids=$(docker ps -aq --filter "label=com.docker.compose.project=${PROJECT}" 2>/dev/null || true)
  if [[ -n "$orphan_cids" ]]; then
    docker rm -f $orphan_cids >/dev/null 2>&1 || true
  fi
  local orphan_nets
  orphan_nets=$(docker network ls --format '{{.Name}}' 2>/dev/null \
    | grep -E "^${PROJECT}(_|$)" || true)
  if [[ -n "$orphan_nets" ]]; then
    while IFS= read -r net; do
      [[ -n "$net" ]] && docker network rm "$net" >/dev/null 2>&1 || true
    done <<< "$orphan_nets"
  fi

  # Remove data + instance dirs. sudo rm handles files owned by any uid
  # (root, 1000, or host user) and matches hidden files/dirs.
  if [[ -e "$DATA_DIR" ]] || sudo test -e "$DATA_DIR"; then
    sudo rm -rf "$DATA_DIR" 2>/dev/null || true
  fi
  if [[ -e "$INSTANCE_DIR" ]]; then
    sudo rm -rf "$INSTANCE_DIR" 2>/dev/null || true
  fi

  # Remove shortcut symlink
  local SHORTCUT="/usr/local/bin/openclaw${N}"
  if [[ -L "$SHORTCUT" || -e "$SHORTCUT" ]]; then
    rm -f "$SHORTCUT" 2>/dev/null || sudo rm -f "$SHORTCUT" 2>/dev/null || true
  fi

  # Verify everything is actually gone so the next openclaw-new starts clean
  local issues=()
  if [[ -e "$INSTANCE_DIR" ]] || sudo test -e "$INSTANCE_DIR"; then
    issues+=("$INSTANCE_DIR still exists")
  fi
  if [[ -e "$DATA_DIR" ]] || sudo test -e "$DATA_DIR"; then
    issues+=("$DATA_DIR still exists")
  fi
  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER"; then
    issues+=("container $CONTAINER still exists")
  fi
  if docker network ls --format '{{.Name}}' 2>/dev/null | grep -qE "^${PROJECT}(_|$)"; then
    issues+=("docker network for ${PROJECT} still exists")
  fi
  if [[ -e "$SHORTCUT" || -L "$SHORTCUT" ]]; then
    issues+=("$SHORTCUT still exists")
  fi

  if [[ ${#issues[@]} -gt 0 ]]; then
    echo "Warning: instance #$N cleanup incomplete:"
    printf '  - %s\n' "${issues[@]}"
    return 1
  fi

  echo "Deleted instance #$N"
}

for n in "${TARGETS[@]}"; do
  delete_instance "$n"
done

echo ""
echo "Done: ${#TARGETS[@]} instance(s) deleted."
