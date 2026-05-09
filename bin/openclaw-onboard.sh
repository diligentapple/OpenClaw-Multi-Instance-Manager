#!/usr/bin/env bash
set -euo pipefail

usage() { echo "Usage: openclaw-onboard N"; }

N="${1:-}"
[[ "$N" =~ ^[0-9]+$ ]] || { usage; exit 1; }

HOME_DIR="${HOME:-/root}"
DATA_DIR="${HOME_DIR}/.openclaw${N}"
CONTAINER="openclaw${N}-gateway"
ENV_FILE="${HOME_DIR}/openclaw${N}/.env"
CONFIG="${DATA_DIR}/openclaw.json"

# Verify Docker daemon is reachable (catches missing docker group membership)
if ! docker info >/dev/null 2>&1; then
  echo "Error: cannot connect to the Docker daemon."
  echo "If Docker is running, add your user to the docker group:"
  echo "  sudo usermod -aG docker \$USER"
  echo "Then log out and back in (or run: newgrp docker)."
  exit 1
fi

if ! sudo test -d "$DATA_DIR"; then
  echo "Data directory $DATA_DIR not found. Run openclaw-new $N first."
  exit 1
fi

# Verify the container exists (running, restarting, or any state)
if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
  echo "Error: container '$CONTAINER' does not exist."
  echo "Use 'openclaw-new $N' to create it, or 'openclaw-list' to see instances."
  exit 1
fi

# Resolve the image the instance is running so the onboarding container matches
IMAGE=$(docker inspect --format '{{.Config.Image}}' "$CONTAINER" 2>/dev/null || echo "ghcr.io/openclaw/openclaw:latest")

echo "Running onboarding for instance #$N..."

# The gateway runs as root (user: root in compose) and writes files owned by
# root:root.  The wizard process drops to uid 1000 internally, so it cannot
# delete or overwrite root-owned files during a Reset.  Fix ownership first.
sudo chown -R 1000:1000 "$DATA_DIR" 2>/dev/null || true

# Check whether openclaw.json is a user-configured file (has channels/auth content)
# or just the auto-generated stub the gateway writes on first start.
# - Stub (no user content): delete so the wizard starts completely fresh.
# - Real config (Telegram tokens, API keys, etc.): keep it.  The wizard will
#   show "Existing config detected" and re-pair the device while preserving the
#   user's settings.  This is the correct path for fixing a scope issue without
#   losing configuration.
_is_stub=true
if sudo test -f "$CONFIG"; then
  _has_channels=$(sudo jq -r 'if (.channels // {} | length) > 0 then "yes" else "no" end' "$CONFIG" 2>/dev/null || echo "no")
  _has_auth=$(sudo jq -r 'if ((.auth.profiles // {}) | length) > 0 then "yes" else "no" end' "$CONFIG" 2>/dev/null || echo "no")
  if [[ "$_has_channels" == "yes" || "$_has_auth" == "yes" ]]; then
    _is_stub=false
  fi
fi

if [[ "$_is_stub" == "true" ]]; then
  sudo rm -f "$CONFIG"
else
  echo "Existing config detected (has user settings). Wizard will re-pair without wiping configuration."
fi

# Ensure the gateway container is running so the wizard can connect to it.
if [[ "$(docker inspect --format '{{.State.Status}}' "$CONTAINER" 2>/dev/null)" != "running" ]]; then
  echo "Starting gateway container..."
  docker start "$CONTAINER" >/dev/null
  sleep 2
fi

# Run the wizard in a separate container that shares the gateway's network
# namespace (--network container:NAME).  This gives the wizard loopback access
# to the gateway (127.0.0.1:18789) — the same as the old 'docker exec' approach.
# The gateway grants operator.admin scope to wizard connections over loopback,
# which is required for 'openclaw-remote --approve' to work afterwards.
# Using a separate container (instead of docker exec) means the gateway's
# file-watcher can restart the gateway mid-wizard without killing the wizard
# session (the root cause of the "exits after channel selection" bug).
docker run --rm -it \
  --user root \
  --network "container:${CONTAINER}" \
  -e HOME=/home/node \
  -e TERM=xterm-256color \
  -e NPM_CONFIG_PREFIX=/home/node/.npm-global \
  -e PATH=/home/node/.npm-global/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  -e NODE_OPTIONS="--disable-warning=DEP0040" \
  -v "${DATA_DIR}:/home/node/.openclaw" \
  "$IMAGE" \
  node openclaw.mjs onboard --mode local

# Patch openclaw.json BEFORE restarting the gateway so only one restart is
# needed and the gateway reads the fully correct config from the start:
#
#  1. allowInsecureAuth = true   — HTTP fallback URLs work without HTTPS
#  2. gateway.auth.token = $env_token — belt-and-suspenders token sync.
#     The wizard should already write the correct token (OPENCLAW_GATEWAY_TOKEN
#     was passed above), but if anything went wrong this guarantees alignment.
if sudo test -f "$CONFIG"; then
  _patch_tmp=$(mktemp)
  _env_token=""
  [[ -f "$ENV_FILE" ]] && _env_token=$(grep -oP '^OPENCLAW_GATEWAY_TOKEN=\K.*' "$ENV_FILE" 2>/dev/null || true)

  if [[ -n "$_env_token" ]]; then
    sudo jq --arg tok "$_env_token" \
      '.gateway.controlUi.allowInsecureAuth = true | .gateway.auth.token = $tok' \
      "$CONFIG" > "$_patch_tmp" 2>/dev/null || true
  else
    sudo jq '.gateway.controlUi.allowInsecureAuth = true' \
      "$CONFIG" > "$_patch_tmp" 2>/dev/null || true
  fi

  if jq empty "$_patch_tmp" 2>/dev/null; then
    _owner=$(sudo stat -c '%u:%g' "$CONFIG")
    sudo mv "$_patch_tmp" "$CONFIG"
    sudo chown "$_owner" "$CONFIG"
  else
    rm -f "$_patch_tmp"
  fi
fi

# Restart the gateway once with the fully patched config.
echo "Restarting gateway to apply new configuration..."
docker restart "$CONTAINER" >/dev/null 2>&1 || true

# Wait for the container to come back up and respond.
# Re-query docker port each iteration because after force-recreate the
# container needs a moment before port mappings are available.
API_PORT=$(docker port "$CONTAINER" 18789/tcp 2>/dev/null | head -1 | awk -F: '{print $NF}' || true)
if [[ -z "${API_PORT:-}" ]]; then
  API_PORT=$(docker inspect "$CONTAINER" \
    --format='{{range $p, $b := .NetworkSettings.Ports}}{{if eq $p "18789/tcp"}}{{(index $b 0).HostPort}}{{end}}{{end}}' 2>/dev/null || true)
fi
: "${API_PORT:=18789}"

for i in $(seq 1 60); do
  # Try host-side HTTP check first; fall back to in-container check
  # (needed when gateway binds to loopback — host can't reach container's 127.0.0.1)
  if curl -sf --max-time 2 "http://127.0.0.1:${API_PORT}/healthz" >/dev/null 2>&1 \
     || docker exec "$CONTAINER" node -e "fetch('http://127.0.0.1:18789/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))" >/dev/null 2>&1; then
    echo "Gateway is up."
    break
  fi
  if [[ "$i" -eq 60 ]]; then
    echo "Warning: gateway not responding after 120s. Check: openclaw-logs $N --tail 20"
  fi
  sleep 2
done

# Follow gateway logs briefly so the user sees any Telegram pairing code emitted
# on startup.  Use --tail 50 rather than --since Ns: if the health check took
# a while the startup logs would be older than any fixed time window.
echo ""
echo "Gateway startup log (Ctrl-C to stop, or wait ~15s):"
timeout 15 docker logs --tail 50 -f "$CONTAINER" 2>&1 || true
echo ""

echo "Onboarding complete for instance #$N"
echo "  Dashboard : http://127.0.0.1:${API_PORT}/"
echo "  Logs      : openclaw-logs $N"
echo "  Approve   : openclaw-remote $N --approve"
