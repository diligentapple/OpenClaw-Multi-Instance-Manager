#!/usr/bin/env bash
set -euo pipefail

usage() { echo "Usage: openclaw-logs N [--tail N]"; }

N="${1:-}"
[[ "$N" =~ ^[0-9]+$ ]] || { usage; exit 1; }
shift

CONTAINER="openclaw${N}-gateway"

# Allow stopped containers — 'docker logs' works on them, and a crashed
# container is exactly when logs are needed (openclaw-update points here).
if ! docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER"; then
  echo "Error: container '$CONTAINER' does not exist."
  echo "Use 'openclaw-list' to see instances."
  exit 1
fi

exec docker logs -f "$@" "$CONTAINER"
