#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# setup.sh — runs INSIDE the container (as root) to install + harden OpenClaw.
# Normally invoked by provision-lxc.sh, but can be run standalone in any fresh
# Debian 13 LXC. Idempotent where practical.
#
# Reads configuration from the environment (provision-lxc.sh exports it):
#   OC_USER EXPOSURE_MODE TAILSCALE_AUTHKEY CT_HOSTNAME
#   CONFIG_GIT_REMOTE CONFIG_GIT_SSH_KEY ENABLE_BROWSER ENABLE_SIGNAL
# ============================================================================

OC_USER="${OC_USER:-openclaw}"
EXPOSURE_MODE="${EXPOSURE_MODE:-tailscale}"
ENABLE_BROWSER="${ENABLE_BROWSER:-true}"
ENABLE_SIGNAL="${ENABLE_SIGNAL:-false}"

OC_HOME="/var/lib/${OC_USER}"
OC_LIVE="${OC_HOME}/.openclaw"
OC_REPO="${OC_HOME}/openclaw-config"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

log() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; }

[[ $(id -u) -eq 0 ]] || { echo "must run as root inside the container"; exit 1; }

# Use an always-present locale so apt/perl don't spew locale warnings in a
# fresh container (en_US.UTF-8 isn't generated yet).
export LANG=C.UTF-8 LC_ALL=C.UTF-8

# Helper: run a command as the agent user with a correct HOME.
as_agent() { runuser -u "$OC_USER" -- env HOME="$OC_HOME" "$@"; }

# ── base packages + Node + OpenClaw ────────────────────────────────────────
log "Base packages, Node.js 22, OpenClaw"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl ca-certificates gnupg git jq >/dev/null
curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null 2>&1
apt-get install -y -qq nodejs >/dev/null
npm install -g openclaw@latest >/dev/null 2>&1
OC_BIN="$(command -v openclaw)"
ok "OpenClaw installed at $OC_BIN ($("$OC_BIN" --version 2>/dev/null | head -1))"

# ── dedicated non-root agent user ──────────────────────────────────────────
log "Dedicated non-root agent user: $OC_USER"
if ! id "$OC_USER" >/dev/null 2>&1; then
  useradd --system --create-home --home-dir "$OC_HOME" --shell /usr/sbin/nologin "$OC_USER"
fi
install -d -o "$OC_USER" -g "$OC_USER" -m 700 "$OC_LIVE" "$OC_LIVE/cron" "$OC_REPO"
ok "user + directories ready ($OC_HOME)"

# ── path config consumed by the bin/ helpers ───────────────────────────────
cat > /etc/openclaw-lxc.env <<EOF
OC_USER=${OC_USER}
OC_HOME=${OC_HOME}
OC_LIVE=${OC_LIVE}
OC_REPO=${OC_REPO}
CONFIG_GIT_SSH_KEY=${CONFIG_GIT_SSH_KEY:-}
EOF
chmod 644 /etc/openclaw-lxc.env

# ── base gateway config (loopback by default; exposure handled below) ───────
log "Gateway configuration (mode: $EXPOSURE_MODE)"
as_agent "$OC_BIN" config set gateway.mode local >/dev/null
as_agent "$OC_BIN" config set gateway.bind loopback >/dev/null

case "$EXPOSURE_MODE" in
  tailscale)
    curl -fsSL https://tailscale.com/install.sh | sh >/dev/null 2>&1
    [[ -n "${TAILSCALE_AUTHKEY:-}" ]] && tailscale up --authkey="${TAILSCALE_AUTHKEY}" --hostname="${CT_HOSTNAME:-$OC_USER}" >/dev/null 2>&1 || true
    # Let the agent user run `tailscale serve` without root.
    tailscale set --operator="$OC_USER" >/dev/null 2>&1 || true
    as_agent "$OC_BIN" config set gateway.tailscale.mode serve >/dev/null
    as_agent "$OC_BIN" config set gateway.auth.mode none >/dev/null
    as_agent "$OC_BIN" config set gateway.trustedProxies '["127.0.0.1","::1"]' --strict-json >/dev/null
    ok "Tailscale Serve (tailnet-only); auth=none safe behind loopback bind"
    ;;
  loopback)
    as_agent "$OC_BIN" config set gateway.auth.mode none >/dev/null
    ok "loopback-only; reach via SSH tunnel (ssh -L 18789:127.0.0.1:18789 ...)"
    ;;
  lan-token)
    TOKEN="$(openssl rand -hex 24)"
    as_agent "$OC_BIN" config set gateway.bind lan >/dev/null
    as_agent "$OC_BIN" config set gateway.auth.mode token >/dev/null
    as_agent "$OC_BIN" config set gateway.auth.token "$TOKEN" >/dev/null
    ok "LAN bind WITH token auth. Token: $TOKEN"
    echo "$TOKEN" > "$OC_HOME/.gateway-token"; chmod 600 "$OC_HOME/.gateway-token"; chown "$OC_USER:$OC_USER" "$OC_HOME/.gateway-token"
    ;;
  *) echo "unknown EXPOSURE_MODE: $EXPOSURE_MODE"; exit 1 ;;
esac

# ── config history: git repo + auto-commit watcher + recovery tools ─────────
log "Config history + recovery tooling"
if [[ ! -d "$OC_REPO/.git" ]]; then
  as_agent git init -q -b main "$OC_REPO"
  as_agent git -C "$OC_REPO" config user.email "openclaw@localhost"
  as_agent git -C "$OC_REPO" config user.name  "OpenClaw Config Bot"
fi
if [[ -n "${CONFIG_GIT_REMOTE:-}" ]]; then
  as_agent git -C "$OC_REPO" remote add origin "$CONFIG_GIT_REMOTE" 2>/dev/null \
    || as_agent git -C "$OC_REPO" remote set-url origin "$CONFIG_GIT_REMOTE"
fi

install -m 755 "$REPO_ROOT/bin/openclaw-config-push"    /usr/local/bin/openclaw-config-push
install -m 755 "$REPO_ROOT/bin/openclaw-config-restore" /usr/local/bin/openclaw-config-restore
install -m 755 "$REPO_ROOT/bin/openclaw-config-log"     /usr/local/bin/openclaw-config-log

# Substitute placeholders in the systemd units, then install.
subst() { sed -e "s|@OC_USER@|$OC_USER|g" -e "s|@OC_HOME@|$OC_HOME|g" \
              -e "s|@OC_LIVE@|$OC_LIVE|g" -e "s|@OC_BIN@|$OC_BIN|g" "$1"; }
subst "$REPO_ROOT/systemd/openclaw-gateway.service"      > /etc/systemd/system/openclaw-gateway.service
subst "$REPO_ROOT/systemd/openclaw-config-watch.path"    > /etc/systemd/system/openclaw-config-watch.path
subst "$REPO_ROOT/systemd/openclaw-config-watch.service" > /etc/systemd/system/openclaw-config-watch.service
ok "installed recovery tools + systemd units"

# ── optional: headless browser (Chromium, driven by OpenClaw, non-root) ─────
if [[ "$ENABLE_BROWSER" == "true" ]]; then
  log "Headless browser (Chromium) for OpenClaw automation"
  echo "  (pulls ~several hundred MB; this can take a few minutes with no output)"
  apt-get install -y -qq chromium fonts-liberation >/dev/null 2>&1 \
    || apt-get install -y -qq chromium-browser >/dev/null 2>&1 || true
  CHROME_BIN="$(command -v chromium || command -v chromium-browser || true)"
  if [[ -n "$CHROME_BIN" ]]; then
    ok "Chromium at $CHROME_BIN — OpenClaw's browser control will drive it headless"
    echo "  (verify after start: sudo -u $OC_USER openclaw browser navigate https://example.com)"
  else
    ok "Chromium package not found; install manually and re-check"
  fi
fi

# ── optional: Signal channel (native signal-cli build) ──────────────────────
if [[ "$ENABLE_SIGNAL" == "true" ]]; then
  log "Signal (native signal-cli)"
  SC_VER="$(curl -fsSL https://api.github.com/repos/AsamK/signal-cli/releases/latest | jq -r .tag_name | tr -d v)"
  curl -fsSL "https://github.com/AsamK/signal-cli/releases/download/v${SC_VER}/signal-cli-${SC_VER}-Linux-native.tar.gz" \
    -o /tmp/sigcli.tar.gz
  tar -xzf /tmp/sigcli.tar.gz -C /tmp
  install -m 755 /tmp/signal-cli /opt/signal-cli
  ln -sf /opt/signal-cli /usr/local/bin/signal-cli
  rm -f /tmp/sigcli.tar.gz /tmp/signal-cli
  ok "signal-cli ${SC_VER} installed — register manually: signal-cli -a <+E164> register"
fi

# ── enable services ─────────────────────────────────────────────────────────
log "Enable services"
systemctl daemon-reload
systemctl enable --now openclaw-gateway.service
systemctl enable --now openclaw-config-watch.path

# Verify the gateway actually came up (it takes ~30s to initialize).
sleep 5
if systemctl is-active --quiet openclaw-gateway; then
  ok "gateway active (non-root '$OC_USER'); config watcher enabled"
else
  echo "  WARNING: openclaw-gateway is not active — check: journalctl -u openclaw-gateway -n 50"
fi

# initial config snapshot
as_agent /usr/local/bin/openclaw-config-push || true

# ── exposure follow-up ───────────────────────────────────────────────────────
# Tailscale Serve needs the agent user to be the operator, AND `tailscale up`
# resets the operator — so when there's no pre-auth key, the operator must be
# (re)set AFTER the manual `tailscale up`. Print the exact steps.
if [[ "$EXPOSURE_MODE" == "tailscale" ]] && ! tailscale status >/dev/null 2>&1; then
  cat <<EOF

  ┌─ ACTION REQUIRED ─ Tailscale installed but not logged in ─────────────────
  │ Finish exposing the gateway on your tailnet (run on the Proxmox host):
  │   pct exec <vmid> -- tailscale up --hostname=${CT_HOSTNAME:-$OC_USER}
  │   pct exec <vmid> -- tailscale set --operator=${OC_USER}    # MUST be AFTER 'up'
  │   pct exec <vmid> -- systemctl restart openclaw-gateway
  │ Confirm (allow ~30s for the gateway to register serve):
  │   pct exec <vmid> -- tailscale serve status
  └───────────────────────────────────────────────────────────────────────────
EOF
fi

log "Done"
echo "  Gateway runs as non-root '$OC_USER'. Manage with: sudo systemctl {status,restart} openclaw-gateway"
echo "  Config history: sudo -u $OC_USER openclaw-config-log"
