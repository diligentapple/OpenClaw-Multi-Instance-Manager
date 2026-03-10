#!/usr/bin/env bash
set -euo pipefail

usage() { echo "Usage: openclaw-onboard N"; }

N="${1:-}"
[[ "$N" =~ ^[0-9]+$ ]] || { usage; exit 1; }

HOME_DIR="${HOME:-/root}"
DATA_DIR="${HOME_DIR}/.openclaw${N}"
CONTAINER="openclaw${N}-gateway"

if [[ ! -d "$DATA_DIR" ]]; then
  echo "Data directory $DATA_DIR not found. Run openclaw-new $N first."
  exit 1
fi

# Verify the container exists (running, restarting, or any state)
if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
  echo "Error: container '$CONTAINER' does not exist."
  echo "Use 'openclaw-new $N' to create it, or 'openclaw-list' to see instances."
  exit 1
fi

# Wait until the container is in "running" state.
# On a fresh instance the gateway may crash-loop (no config yet) so we need to
# catch it during the brief window between restarts when it is "running".
echo "Running onboarding for instance #$N..."
status=$(docker inspect --format '{{.State.Status}}' "$CONTAINER" 2>/dev/null || true)
if [[ "$status" != "running" ]]; then
  echo "Container is $status – waiting for it to start..."
  for i in $(seq 1 30); do
    sleep 1
    status=$(docker inspect --format '{{.State.Status}}' "$CONTAINER" 2>/dev/null || true)
    [[ "$status" == "running" ]] && break
  done
  if [[ "$status" != "running" ]]; then
    echo "Error: container '$CONTAINER' did not reach running state (status: $status)."
    echo "Check logs with: docker logs $CONTAINER"
    exit 1
  fi
fi

# The gateway may restart itself mid-onboarding (e.g. after channel selection),
# which kills the docker-exec session.  Retry automatically so the wizard can
# resume from where it left off.
MAX_RETRIES=5
for attempt in $(seq 1 "$MAX_RETRIES"); do
  rc=0
  docker exec -it "$CONTAINER" node dist/index.js onboard --mode local || rc=$?

  # Success – wizard finished normally
  [[ "$rc" -eq 0 ]] && break

  # If the config file now exists the wizard completed before the container
  # restarted – treat it as success.
  [[ -f "${DATA_DIR}/openclaw.json" ]] && break

  if [[ "$attempt" -eq "$MAX_RETRIES" ]]; then
    echo "Error: onboarding failed after $MAX_RETRIES attempts (last exit code: $rc)."
    echo "Check logs with: docker logs $CONTAINER"
    exit 1
  fi

  echo ""
  echo "Container restarted during onboarding – retrying (attempt $((attempt+1))/$MAX_RETRIES)..."

  # Wait for the container to come back up
  for _ in $(seq 1 30); do
    sleep 1
    s=$(docker inspect --format '{{.State.Status}}' "$CONTAINER" 2>/dev/null || true)
    [[ "$s" == "running" ]] && break
  done
done

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
