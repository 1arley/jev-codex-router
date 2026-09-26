#!/bin/sh
# Install (or re-install) the Jev Router background service on this machine.
# Run ONCE by the user, from THEIR Terminal (the service manager is
# deliberately restricted inside supervised agents).
#
#   bash ~/Documents/Github/jev-codex-router/server/install-service.sh
#
# Dispatches to the systemd --user unit on Linux and to the launchd agent on
# macOS. Both keep the same environment contract: CODEX_HOME,
# CODEX_ROUTER_STATE_DIR and an optional JEV_ENV_FILE.
set -eu

REPO="$(cd "$(dirname -- "$0")/.." && pwd -P)"

case "$(uname -s)" in
  Darwin) exec "$REPO/server/install-service-macos.sh" "$@" ;;
  Linux) exec "$REPO/server/install-service-linux.sh" "$@" ;;
  *)
    echo "Unsupported platform: $(uname -s)." >&2
    echo "Supported: macOS (launchd) and Linux (systemd --user)." >&2
    exit 1
    ;;
esac
