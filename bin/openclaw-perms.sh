#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: openclaw-perms [options] N|all"
  echo ""
  echo "Grant the host user direct read/write access to instance data dirs"
  echo "(~/.openclawN) via POSIX ACLs, so WinSCP / SFTP / VS Code Remote can"
  echo "browse and edit files without 'access denied'."
  echo ""
  echo "Why this is needed: the gateway inside the container runs as root and"
  echo "creates files as root:root with mode 0600. A file created with mode"
  echo "0600 clamps its ACL mask to 0, which disables the inherited host-user"
  echo "ACL entry until the mask is re-applied. This command re-applies both"
  echo "the entry and the mask."
  echo ""
  echo "Container behavior is unchanged: the gateway runs as root (ACLs never"
  echo "restrict it) and uid 1000 stays the owner of all files."
  echo ""
  echo "Options:"
  echo "  --install     Install a root cron job (every minute) that keeps"
  echo "                ACLs fresh as the gateway writes new files"
  echo "  --uninstall   Remove the cron job"
  echo "  --user USER   Host user to grant access to (default: current user)"
  echo ""
  echo "Examples:"
  echo "  openclaw-perms 1                 Fix instance 1 now"
  echo "  openclaw-perms all               Fix all instances now"
  echo "  openclaw-perms --install all     Fix continuously (recommended)"
}

is_int() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }

# Print only when attached to a terminal — keeps the cron log quiet.
say() { if [[ -t 1 ]]; then echo "$@"; fi; }

INSTALL=false
UNINSTALL=false
TARGET=""
HOST_USER=""
CRON_TAG="# openclaw-perms"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install)   INSTALL=true; shift ;;
    --uninstall) UNINSTALL=true; shift ;;
    --user) [[ $# -ge 2 ]] || { echo "Error: --user requires a value"; exit 1; }; HOST_USER="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *)
      if [[ -z "$TARGET" ]]; then
        TARGET="$1"
      else
        echo "Error: unexpected argument '$1'"; usage; exit 1
      fi
      shift
      ;;
  esac
done

# Resolve the host user (the account WinSCP/SFTP logs in as) and their home.
HOST_USER="${HOST_USER:-${SUDO_USER:-${USER:-$(id -un)}}}"
if ! id "$HOST_USER" >/dev/null 2>&1; then
  echo "Error: user '$HOST_USER' does not exist."
  exit 1
fi
USER_HOME=$(eval echo "~${HOST_USER}")

if [[ "$UNINSTALL" == true ]]; then
  sudo crontab -l 2>/dev/null | grep -v "$CRON_TAG" | sudo crontab - 2>/dev/null || true
  echo "openclaw-perms cron job removed."
  exit 0
fi

if [[ -z "$TARGET" ]]; then
  usage; exit 1
fi
if [[ "$TARGET" != "all" ]] && ! is_int "$TARGET"; then
  echo "Error: N must be a number or 'all'"
  exit 1
fi

if ! command -v setfacl >/dev/null 2>&1; then
  echo "Error: setfacl not found. Install it first:"
  echo "  Ubuntu/Debian: sudo apt-get install -y acl"
  echo "  RHEL/CentOS:   sudo yum install -y acl"
  exit 1
fi

if [[ "$INSTALL" == true ]]; then
  SELF="$(command -v openclaw-perms 2>/dev/null || echo "/usr/local/bin/openclaw-perms")"
  # Root crontab: setfacl on root/1000-owned files needs root, and root
  # cron jobs don't depend on passwordless sudo for the invoking user.
  CRON_LINE="* * * * * ${SELF} --user ${HOST_USER} ${TARGET} >> /tmp/openclaw-perms.log 2>&1 ${CRON_TAG}"
  { sudo crontab -l 2>/dev/null | grep -v "$CRON_TAG" || true; echo "$CRON_LINE"; } | sudo crontab -
  echo "openclaw-perms cron job installed (root crontab, every minute, user: ${HOST_USER})."
  echo "Logs: /tmp/openclaw-perms.log"
fi

fix_dir() {
  local dir="$1"
  # Named-user entry plus an explicit mask. The mask re-apply is the key
  # part: files created with mode 0600 clamp the ACL mask to 0, disabling
  # the inherited entry. Setting m::rwX does not widen access for the
  # owning group — its own entry (---) still applies.
  sudo setfacl -R  -m "u:${HOST_USER}:rwX,m::rwX" "$dir" 2>/dev/null || true
  sudo setfacl -R -d -m "u:${HOST_USER}:rwX,m::rwX" "$dir" 2>/dev/null || true
}

if [[ "$TARGET" == "all" ]]; then
  found=false
  for dir in "${USER_HOME}"/.openclaw[0-9]*; do
    sudo test -d "$dir" || continue
    base="$(basename "$dir")"
    is_int "${base#.openclaw}" || continue
    found=true
    fix_dir "$dir"
  done
  if [[ "$found" == false ]]; then
    say "No instance data dirs found in ${USER_HOME}."
    exit 0
  fi
else
  dir="${USER_HOME}/.openclaw${TARGET}"
  if ! sudo test -d "$dir"; then
    say "Error: ${dir} not found. Create the instance first: openclaw-new ${TARGET}"
    exit 1
  fi
  fix_dir "$dir"
fi

say "Host user '${HOST_USER}' granted rwX (ACL) on instance data — SFTP/WinSCP edits will work."
