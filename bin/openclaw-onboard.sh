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

# Remove any auto-generated stub config so the wizard starts completely fresh.
# The gateway writes a minimal openclaw.json on first start (to persist the
# auth token), which would otherwise trigger "Existing config detected" in the
# wizard even for brand-new instances.  The gateway tolerates the missing file
# via --allow-unconfigured and will re-read the new config after restart.
sudo rm -f "$CONFIG"

# Join the gateway's Docker Compose network so the wizard can reach the running
# gateway for its connection-checking step (e.g. generating the Telegram pairing
# code).  The network is safe to use even when the gateway restarts mid-wizard
# because compose recreates the container on the same network automatically.
COMPOSE_NETWORK="openclaw${N}_default"
NETWORK_OPT=()
if docker network inspect "$COMPOSE_NETWORK" >/dev/null 2>&1; then
  NETWORK_OPT=(--network "$COMPOSE_NETWORK")
fi

# Pass the existing gateway token to the wizard so it uses the same auth token
# as OPENCLAW_GATEWAY_TOKEN in the .env (created by openclaw-new).  When the
# wizard ran via `docker exec` inside the gateway container it inherited this
# env var automatically.  Now that it runs in a separate container it doesn't
# — causing the wizard to generate a fresh token that diverges from the
# gateway's env token and breaks CLI auth (missing scope: operator.admin).
# Using an array avoids word-splitting and quoting issues with the token value.
WIZARD_TOKEN_OPT=()
if [[ -f "$ENV_FILE" ]]; then
  _wt=$(grep -oP '^OPENCLAW_GATEWAY_TOKEN=\K.*' "$ENV_FILE" 2>/dev/null || true)
  [[ -n "$_wt" ]] && WIZARD_TOKEN_OPT=(-e "OPENCLAW_GATEWAY_TOKEN=$_wt")
fi

# Run onboarding in a *separate* one-off container that shares the data volume.
# This avoids the gateway's file-watcher restarting the container mid-wizard and
# killing the interactive exec session (the root cause of the "exits after
# channel selection" bug).
docker run --rm -it \
  --user root \
  -e HOME=/home/node \
  -e TERM=xterm-256color \
  -e NPM_CONFIG_PREFIX=/home/node/.npm-global \
  -e PATH=/home/node/.npm-global/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  -e NODE_OPTIONS="--disable-warning=DEP0040" \
  "${WIZARD_TOKEN_OPT[@]}" \
  "${NETWORK_OPT[@]}" \
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
