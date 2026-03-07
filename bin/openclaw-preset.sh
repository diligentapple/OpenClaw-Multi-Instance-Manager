#!/usr/bin/env bash
set -euo pipefail

PRESET_DIR="${OPENCLAW_MGR_PRESETS:-/usr/local/share/openclaw-manager/presets}"

usage() {
  echo "Usage: openclaw-preset [list | show NAME | create]"
  echo ""
  echo "Commands:"
  echo "  list              List available presets"
  echo "  show NAME         Show contents of a preset"
  echo "  create            Interactively create a new preset"
  echo ""
  echo "Preset directory: $PRESET_DIR"
}

list_presets() {
  if [[ ! -d "$PRESET_DIR" ]]; then
    echo "No presets directory found at $PRESET_DIR"
    return
  fi
  local found=false
  for f in "$PRESET_DIR"/*.json; do
    [[ -f "$f" ]] || continue
    found=true
    echo "  $(basename "$f" .json)"
  done
  if [[ "$found" == false ]]; then
    echo "  (no presets found)"
  fi
}

show_preset() {
  local name="$1"
  local file="${PRESET_DIR}/${name}.json"
  if [[ ! -f "$file" ]]; then
    echo "Preset '$name' not found."
    echo ""
    echo "Available presets:"
    list_presets
    return 1
  fi
  echo "Preset: $name"
  echo "File:   $file"
  echo "---"
  cat "$file"
}

create_preset() {
  echo "Create a new OpenClaw preset"
  echo "============================"
  echo ""

  # Name
  local name=""
  while [[ -z "$name" ]]; do
    read -r -p "Preset name (alphanumeric, e.g. 'mysetup'): " name
    name=$(echo "$name" | tr -cd 'a-zA-Z0-9_-')
    if [[ -z "$name" ]]; then
      echo "Invalid name. Use alphanumeric characters, hyphens, or underscores."
    fi
  done

  local file="${PRESET_DIR}/${name}.json"
  if [[ -f "$file" ]]; then
    read -r -p "Preset '$name' already exists. Overwrite? [y/N]: " overwrite
    if [[ "${overwrite,,}" != "y" ]]; then
      echo "Aborted."
      return 1
    fi
  fi

  # Bind mode
  echo ""
  echo "Network binding mode:"
  echo "  1) loopback  - Local access only (default)"
  echo "  2) lan       - Allow remote access (for Tailscale)"
  local bind_choice=""
  read -r -p "Choice [1]: " bind_choice
  local bind="loopback"
  if [[ "$bind_choice" == "2" ]]; then
    bind="lan"
  fi

  # Allow insecure auth
  echo ""
  echo "Allow insecure auth (HTTP without HTTPS)?"
  echo "  Recommended: yes (needed for HTTP fallback URLs)"
  local insecure_choice=""
  read -r -p "Allow insecure auth? [Y/n]: " insecure_choice
  local insecure=true
  if [[ "${insecure_choice,,}" == "n" ]]; then
    insecure=false
  fi

  # Build JSON
  local json
  json=$(jq -n \
    --arg bind "$bind" \
    --argjson insecure "$insecure" \
    '{
      gateway: {
        bind: $bind,
        controlUi: {
          allowInsecureAuth: $insecure
        }
      }
    }')

  # Write
  echo ""
  echo "Preview:"
  echo "$json"
  echo ""
  read -r -p "Save preset '$name'? [Y/n]: " confirm
  if [[ "${confirm,,}" == "n" ]]; then
    echo "Aborted."
    return 1
  fi

  sudo tee "$file" > /dev/null <<< "$json"
  sudo chmod 644 "$file"
  echo ""
  echo "Saved: $file"
  echo "Use it with: openclaw-new 2-4 --preset $name"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

CMD="${1:-}"

case "$CMD" in
  list|ls)
    echo "Available presets:"
    list_presets
    ;;
  show|cat)
    if [[ -z "${2:-}" ]]; then
      echo "Usage: openclaw-preset show NAME"
      exit 1
    fi
    show_preset "$2"
    ;;
  create|new)
    create_preset
    ;;
  -h|--help|"")
    usage
    ;;
  *)
    echo "Unknown command: $CMD"
    usage
    exit 1
    ;;
esac
