#!/bin/sh
# Install (or re-install) the Jev Router background service on Linux.
# Run ONCE by the user, from THEIR Terminal.
#
#   bash server/install-service.sh              # install + start + health check
#   bash server/install-service.sh render       # print the unit, touch nothing
#   bash server/install-service.sh status       # is it up?
#   bash server/install-service.sh restart      # reload the running policy
#   bash server/install-service.sh uninstall    # stop and remove the unit
#
# The macOS launchd plist lives in install-service-macos.sh; this is the
# systemd --user counterpart. Both keep the same environment contract:
# CODEX_HOME, CODEX_ROUTER_STATE_DIR and an optional JEV_ENV_FILE.
set -eu

REPO="$(cd "$(dirname -- "$0")/.." && pwd -P)"

# systemd unit names are not reverse-DNS; keep this short and stable, and let
# JEV_ROUTER_UNIT rename it for anyone who needs a second instance.
UNIT=${JEV_ROUTER_UNIT:-jev-router.service}
UNIT_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user
UNIT_PATH=$UNIT_DIR/$UNIT
CODEX_HOME_VALUE=${CODEX_HOME:-$HOME/.codex}
STATE_VALUE=${MODEL_ROUTER_STATE_DIR:-${CODEX_ROUTER_STATE_DIR:-${KIMI_CODEX_STATE_DIR:-$CODEX_HOME_VALUE/codex-router}}}
STATE_HOME=${XDG_STATE_HOME:-$HOME/.local/state}
LOG_DIR=$STATE_HOME/jev-codex-router
LOG_PATH=$LOG_DIR/jev-router.log
PYTHON=${JEV_ROUTER_PYTHON:-$(command -v python3 2>/dev/null || true)}

# systemd reads %, so a literal percent has to be doubled in a unit file.
unit_quote() {
  printf '"%s"' "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/%/%%/g')"
}

usage() {
  cat <<'EOF'
Usage: bash server/install-service.sh [install|render|status|restart|logs|uninstall]

  install     Write the systemd --user unit, enable it, start it, health check
  render      Print the unit file to stdout without touching systemd
  status      Report unit state and the local health endpoint
  restart     Restart the service (use after editing server/routing_policy.py)
  logs        Follow the service log
  uninstall   Stop, disable and remove the unit

Environment: JEV_ROUTER_UNIT, JEV_ROUTER_PYTHON, JEV_ENV_FILE, XDG_CONFIG_HOME,
XDG_STATE_HOME, MODEL_ROUTER_STATE_DIR, CODEX_HOME.
EOF
}

systemctl_user() {
  systemctl --user "$@"
}

user_session_available() {
  systemctl_user show-environment >/dev/null 2>&1
}

render_unit() {
  cat <<EOF
[Unit]
Description=Jev Codex Router decision server (127.0.0.1:4319)
Documentation=file://$REPO/server/INSTALL.md
After=network-online.target

[Service]
Type=simple
WorkingDirectory=$(unit_quote "$REPO")
ExecStart=$(unit_quote "$PYTHON") $(unit_quote "$REPO/server/jev_server.py")
Restart=always
RestartSec=5
Environment=CODEX_HOME=$(unit_quote "$CODEX_HOME_VALUE")
Environment=CODEX_ROUTER_STATE_DIR=$(unit_quote "$STATE_VALUE")
Environment=PYTHONUNBUFFERED=1
$(if [ -n "${JEV_ENV_FILE:-}" ]; then
    printf 'Environment=JEV_ENV_FILE=%s\n' "$(unit_quote "$JEV_ENV_FILE")"
  fi)
StandardOutput=append:$LOG_PATH
StandardError=append:$LOG_PATH

[Install]
WantedBy=default.target
EOF
}

health_check() {
  attempt=0
  while [ "$attempt" -lt 20 ]; do
    if "$PYTHON" "$REPO/server/healthcheck.py"; then
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 1
  done
  return 1
}

require_prerequisites() {
  command -v systemctl >/dev/null 2>&1 || {
    echo "systemctl not found; this installer needs systemd (Omarchy/Arch, Fedora, Debian, Ubuntu)." >&2
    exit 1
  }
  [ -n "$PYTHON" ] || {
    echo "python3 not found; install Python 3.11+ or set JEV_ROUTER_PYTHON." >&2
    exit 1
  }
  [ -f "$REPO/server/jev_server.py" ] || {
    echo "jev_server.py is missing from $REPO/server." >&2
    exit 1
  }
  if ! user_session_available; then
    cat >&2 <<EOF
systemctl --user cannot reach a user session, so the unit cannot be enabled.

Either run this from a normal desktop or SSH login of this account, or make the
user manager persistent outside the login session:

  sudo loginctl enable-linger "$(id -un)"
EOF
    exit 1
  fi
}

# The service has to outlive the desktop session: without linger, systemd stops
# every user unit at logout, and a router that silently disappears looks exactly
# like a quota problem. Changing linger is a system-level change, so it is
# opt-in rather than something an installer does behind the user's back.
linger_state() {
  loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null || true
}

install_unit() {
  require_prerequisites
  mkdir -p "$UNIT_DIR" "$LOG_DIR"
  # A unit whose command or repo path changed would otherwise keep running the
  # previous one after an update.
  systemctl_user stop "$UNIT" >/dev/null 2>&1 || true
  pkill -f 'server/jev_server\.py' >/dev/null 2>&1 || true
  render_unit >"$UNIT_PATH"
  systemctl_user daemon-reload
  systemctl_user enable --now "$UNIT"
  if health_check; then
    echo ""
    echo "— Jev Router service OK ($UNIT)"
  else
    echo "Jev Router health check failed; recent log lines:" >&2
    tail -n 20 "$LOG_PATH" >&2 2>/dev/null || true
    exit 1
  fi
  if [ "$(linger_state)" != "yes" ]; then
    cat >&2 <<EOF

Note: linger is off, so $UNIT stops when you log out and Codex calls will
fall back until you log back in. To keep it running headless:

  sudo loginctl enable-linger "$(id -un)"
EOF
  fi
  echo "Uninstall: bash $REPO/server/install-service-linux.sh uninstall"
}

uninstall_unit() {
  if [ -f "$UNIT_PATH" ]; then
    systemctl_user disable --now "$UNIT" >/dev/null 2>&1 || true
    rm -f "$UNIT_PATH"
    systemctl_user daemon-reload >/dev/null 2>&1 || true
  else
    systemctl_user disable --now "$UNIT" >/dev/null 2>&1 || true
  fi
  pkill -f 'server/jev_server\.py' >/dev/null 2>&1 || true
  echo "Jev Router service removed ($UNIT). Router provider state was kept;"
  echo "remove it with: router/bin/codex-router providers generic disable jev"
}

command=${1:-install}
case "$command" in
  install) install_unit ;;
  render) render_unit ;;
  status)
    systemctl_user --no-pager status "$UNIT" || true
    "$PYTHON" "$REPO/server/healthcheck.py" && echo "health: ok" || echo "health: failing"
    ;;
  restart)
    require_prerequisites
    systemctl_user restart "$UNIT"
    health_check
    ;;
  logs) exec tail -f "$LOG_PATH" ;;
  uninstall) uninstall_unit ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
