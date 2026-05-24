#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# setup.sh — runs INSIDE the container (as root) to install + harden an AI
# agent (OpenClaw or hermes-agent). Normally invoked by provision-lxc.sh.
#
# Reads from the environment (provision-lxc.sh exports it):
#   AGENT OC_USER EXPOSURE_MODE TAILSCALE_AUTHKEY CT_HOSTNAME
#   CONFIG_GIT_REMOTE CONFIG_GIT_SSH_KEY ENABLE_BROWSER ENABLE_SIGNAL
#
# AGENT=openclaw : fully automated, incl. exposure (validated).
# AGENT=hermes   : EXPERIMENTAL — install + non-root hardening + config history
#                  automated; network exposure is left MANUAL (printed at end).
# ============================================================================

AGENT="${AGENT:-openclaw}"
OC_USER="${OC_USER:-openclaw}"
EXPOSURE_MODE="${EXPOSURE_MODE:-tailscale}"
ENABLE_BROWSER="${ENABLE_BROWSER:-true}"
ENABLE_SIGNAL="${ENABLE_SIGNAL:-false}"

OC_HOME="/var/lib/${OC_USER}"
AGENT_REPO="${OC_HOME}/agent-config"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

export LANG=C.UTF-8 LC_ALL=C.UTF-8   # avoid locale warnings in a fresh container

log() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
ok()  { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn(){ printf '  \033[33m!\033[0m %s\n' "$*"; }

[[ $(id -u) -eq 0 ]] || { echo "must run as root inside the container"; exit 1; }
as_agent() { runuser -u "$OC_USER" -- env HOME="$OC_HOME" "$@"; }

case "$AGENT" in
  openclaw|hermes) ;;
  *) echo "unknown AGENT: $AGENT (expected openclaw|hermes)"; exit 1 ;;
esac

# ── base packages ───────────────────────────────────────────────────────────
log "Base packages ($AGENT)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl ca-certificates gnupg git jq >/dev/null
if [[ "$AGENT" == "hermes" ]]; then
  # Pre-install build deps + tools so the non-root hermes installer is
  # self-sufficient (it can't sudo as our nologin agent user).
  apt-get install -y -qq build-essential python3-dev libffi-dev ripgrep ffmpeg >/dev/null
fi
ok "base packages ready"

# ── dedicated non-root agent user ──────────────────────────────────────────
log "Dedicated non-root agent user: $OC_USER"
if ! id "$OC_USER" >/dev/null 2>&1; then
  useradd --system --create-home --home-dir "$OC_HOME" --shell /usr/sbin/nologin "$OC_USER"
fi
install -d -o "$OC_USER" -g "$OC_USER" -m 700 "$AGENT_REPO"
ok "user + repo dir ready ($OC_HOME)"

# ── install the agent (sets AGENT_CMD / AGENT_LIVE / TRACKED_FILES / AGENT_PATH) ──
if [[ "$AGENT" == "openclaw" ]]; then
  log "Install OpenClaw (Node 22)"
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null 2>&1
  apt-get install -y -qq nodejs >/dev/null
  npm install -g openclaw@latest >/dev/null 2>&1
  AGENT_CMD="$(command -v openclaw)"
  AGENT_LIVE="${OC_HOME}/.openclaw"
  TRACKED_FILES="openclaw.json exec-approvals.json cron/jobs.json"
  AGENT_PATH="/usr/local/bin:/usr/bin:/bin"
  ok "OpenClaw at $AGENT_CMD ($("$AGENT_CMD" --version 2>/dev/null | head -1))"
else
  log "Install hermes-agent (official installer, non-root, --skip-setup)"
  echo "  (pulls uv/Python/Node into ${OC_HOME}; can take several minutes)"
  as_agent bash -c 'curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash -s -- --skip-setup' || true
  AGENT_CMD="${OC_HOME}/.local/bin/hermes"
  AGENT_LIVE="${OC_HOME}/.hermes"
  TRACKED_FILES="config.yaml gateway.json"
  AGENT_PATH="${OC_HOME}/.local/bin:${OC_HOME}/.hermes/node/bin:/usr/local/bin:/usr/bin:/bin"
  if [[ -x "$AGENT_CMD" ]]; then
    ok "hermes installed at $AGENT_CMD"
  else
    warn "hermes command not found at $AGENT_CMD — installer may have used a different path; verify with: sudo -u $OC_USER ls $OC_HOME/.local/bin"
  fi
fi

install -d -o "$OC_USER" -g "$OC_USER" -m 700 "$AGENT_LIVE"

# ── path config consumed by the agent-config-* helpers ──────────────────────
cat > /etc/agent-lxc.env <<EOF
AGENT=${AGENT}
OC_USER=${OC_USER}
OC_HOME=${OC_HOME}
AGENT_CMD=${AGENT_CMD}
AGENT_LIVE=${AGENT_LIVE}
AGENT_REPO=${AGENT_REPO}
TRACKED_FILES="${TRACKED_FILES}"
GIT_SSH_KEY=${CONFIG_GIT_SSH_KEY:-}
EOF
chmod 644 /etc/agent-lxc.env

# ── exposure (OpenClaw: automated; hermes: manual, printed at end) ──────────
if [[ "$AGENT" == "openclaw" ]]; then
  log "Gateway exposure (mode: $EXPOSURE_MODE)"
  as_agent "$AGENT_CMD" config set gateway.mode local >/dev/null
  as_agent "$AGENT_CMD" config set gateway.bind loopback >/dev/null
  case "$EXPOSURE_MODE" in
    tailscale)
      curl -fsSL https://tailscale.com/install.sh | sh >/dev/null 2>&1
      [[ -n "${TAILSCALE_AUTHKEY:-}" ]] && tailscale up --authkey="${TAILSCALE_AUTHKEY}" --hostname="${CT_HOSTNAME:-$OC_USER}" >/dev/null 2>&1 || true
      tailscale set --operator="$OC_USER" >/dev/null 2>&1 || true
      as_agent "$AGENT_CMD" config set gateway.tailscale.mode serve >/dev/null
      as_agent "$AGENT_CMD" config set gateway.auth.mode none >/dev/null
      as_agent "$AGENT_CMD" config set gateway.trustedProxies '["127.0.0.1","::1"]' --strict-json >/dev/null
      ok "Tailscale Serve (tailnet-only); auth=none safe behind loopback bind"
      ;;
    loopback)
      as_agent "$AGENT_CMD" config set gateway.auth.mode none >/dev/null
      ok "loopback-only; reach via SSH tunnel"
      ;;
    lan-token)
      TOKEN="$(openssl rand -hex 24)"
      as_agent "$AGENT_CMD" config set gateway.bind lan >/dev/null
      as_agent "$AGENT_CMD" config set gateway.auth.mode token >/dev/null
      as_agent "$AGENT_CMD" config set gateway.auth.token "$TOKEN" >/dev/null
      ok "LAN bind WITH token auth. Token: $TOKEN"
      ;;
    *) echo "unknown EXPOSURE_MODE: $EXPOSURE_MODE"; exit 1 ;;
  esac
elif [[ "$EXPOSURE_MODE" == "tailscale" ]]; then
  # hermes: install Tailscale + set operator now; actual serve is manual (port unknown).
  curl -fsSL https://tailscale.com/install.sh | sh >/dev/null 2>&1 || true
  [[ -n "${TAILSCALE_AUTHKEY:-}" ]] && tailscale up --authkey="${TAILSCALE_AUTHKEY}" --hostname="${CT_HOSTNAME:-$OC_USER}" >/dev/null 2>&1 || true
  tailscale set --operator="$OC_USER" >/dev/null 2>&1 || true
fi

# ── config history: git repo + recovery tools + systemd units ───────────────
log "Config history + recovery tooling"
if [[ ! -d "$AGENT_REPO/.git" ]]; then
  as_agent git init -q -b main "$AGENT_REPO"
  as_agent git -C "$AGENT_REPO" config user.email "agent@localhost"
  as_agent git -C "$AGENT_REPO" config user.name  "Agent Config Bot"
fi
if [[ -n "${CONFIG_GIT_REMOTE:-}" ]]; then
  as_agent git -C "$AGENT_REPO" remote add origin "$CONFIG_GIT_REMOTE" 2>/dev/null \
    || as_agent git -C "$AGENT_REPO" remote set-url origin "$CONFIG_GIT_REMOTE"
fi

install -m 755 "$REPO_ROOT/bin/agent-config-push"    /usr/local/bin/agent-config-push
install -m 755 "$REPO_ROOT/bin/agent-config-restore" /usr/local/bin/agent-config-restore
install -m 755 "$REPO_ROOT/bin/agent-config-log"     /usr/local/bin/agent-config-log

subst() { sed -e "s|@OC_USER@|$OC_USER|g" -e "s|@OC_HOME@|$OC_HOME|g" \
              -e "s|@AGENT_CMD@|$AGENT_CMD|g" -e "s|@AGENT_PATH@|$AGENT_PATH|g" "$1"; }
subst "$REPO_ROOT/systemd/agent-gateway.service"      > /etc/systemd/system/agent-gateway.service
subst "$REPO_ROOT/systemd/agent-config-watch.service" > /etc/systemd/system/agent-config-watch.service

# Generate the .path watcher from the agent's tracked-file list.
{
  echo "[Unit]"
  echo "Description=Watch agent live config; auto-commit changes to the config repo"
  echo
  echo "[Path]"
  for f in $TRACKED_FILES; do echo "PathModified=${AGENT_LIVE}/${f}"; done
  echo "Unit=agent-config-watch.service"
  echo
  echo "[Install]"
  echo "WantedBy=multi-user.target"
} > /etc/systemd/system/agent-config-watch.path
ok "installed recovery tools + systemd units"

# ── optional: headless browser ──────────────────────────────────────────────
if [[ "$ENABLE_BROWSER" == "true" ]]; then
  log "Headless browser (Chromium)"
  echo "  (pulls ~several hundred MB; this can take a few minutes with no output)"
  apt-get install -y -qq chromium fonts-liberation >/dev/null 2>&1 \
    || apt-get install -y -qq chromium-browser >/dev/null 2>&1 || true
  command -v chromium >/dev/null 2>&1 || command -v chromium-browser >/dev/null 2>&1 \
    && ok "Chromium installed (agent drives it headless)" \
    || warn "Chromium not found; install manually"
fi

# ── optional: Signal ─────────────────────────────────────────────────────────
if [[ "$ENABLE_SIGNAL" == "true" ]]; then
  log "Signal (native signal-cli)"
  SC_VER="$(curl -fsSL https://api.github.com/repos/AsamK/signal-cli/releases/latest | jq -r .tag_name | tr -d v)"
  curl -fsSL "https://github.com/AsamK/signal-cli/releases/download/v${SC_VER}/signal-cli-${SC_VER}-Linux-native.tar.gz" -o /tmp/sigcli.tar.gz
  tar -xzf /tmp/sigcli.tar.gz -C /tmp
  install -m 755 /tmp/signal-cli /opt/signal-cli
  ln -sf /opt/signal-cli /usr/local/bin/signal-cli
  rm -f /tmp/sigcli.tar.gz /tmp/signal-cli
  ok "signal-cli ${SC_VER} installed — register manually: signal-cli -a <+E164> register"
fi

# ── enable services ─────────────────────────────────────────────────────────
log "Enable services"
systemctl daemon-reload
systemctl enable --now agent-gateway.service
systemctl enable --now agent-config-watch.path
sleep 5
if systemctl is-active --quiet agent-gateway; then
  ok "gateway active (non-root '$OC_USER'); config watcher enabled"
else
  warn "agent-gateway is not active — check: journalctl -u agent-gateway -n 50"
fi
as_agent /usr/local/bin/agent-config-push || true

# ── exposure follow-up ───────────────────────────────────────────────────────
if [[ "$AGENT" == "openclaw" && "$EXPOSURE_MODE" == "tailscale" ]] && ! tailscale status >/dev/null 2>&1; then
  cat <<EOF

  ┌─ ACTION REQUIRED ─ Tailscale installed but not logged in ─────────────────
  │   pct exec <vmid> -- tailscale up --hostname=${CT_HOSTNAME:-$OC_USER}
  │   pct exec <vmid> -- tailscale set --operator=${OC_USER}    # AFTER 'up'
  │   pct exec <vmid> -- systemctl restart agent-gateway
  │   pct exec <vmid> -- tailscale serve status                 # allow ~30s
  └───────────────────────────────────────────────────────────────────────────
EOF
fi

if [[ "$AGENT" == "hermes" ]]; then
  cat <<EOF

  ┌─ EXPERIMENTAL: hermes-agent network exposure is MANUAL ───────────────────
  │ This repo automated the install, non-root hardening, and config history,
  │ but hermes' bind/port/Tailscale config isn't verified yet. To expose it:
  │   1. Find the gateway's listening port:
  │        pct exec <vmid> -- ss -tlnp | grep -i hermes
  │   2. If it binds 0.0.0.0 it's LAN-reachable — confirm that's acceptable, or
  │      restrict it (firewall / hermes config) to loopback first.
  │   3. Tailnet-only access (operator already set if Tailscale is up):
  │        pct exec <vmid> -- tailscale serve --bg --yes <PORT>
  │   Then verify:  pct exec <vmid> -- tailscale serve status
  │ Report the real port/bind back so we can automate this path.
  └───────────────────────────────────────────────────────────────────────────
EOF
fi

log "Done"
echo "  Agent '$AGENT' runs as non-root '$OC_USER'. Manage: sudo systemctl {status,restart} agent-gateway"
echo "  Config history: sudo -u $OC_USER agent-config-log"
