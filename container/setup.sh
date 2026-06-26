#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# setup.sh — runs INSIDE the container (as root) to install + harden an AI
# agent (OpenClaw or hermes-agent). Normally invoked by provision-lxc.sh.
#
# Reads from the environment (provision-lxc.sh exports it):
#   AGENT OC_USER EXPOSURE_MODE TAILSCALE_AUTHKEY CT_HOSTNAME
#   CONFIG_GIT_REMOTE CONFIG_GIT_SSH_KEY ENABLE_BROWSER ENABLE_SIGNAL
#   ENABLE_AGENT_JOURNAL_READ ENABLE_HERMES_GATEWAY_CONTROL
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
ENABLE_AGENT_JOURNAL_READ="${ENABLE_AGENT_JOURNAL_READ:-false}"
ENABLE_HERMES_GATEWAY_CONTROL="${ENABLE_HERMES_GATEWAY_CONTROL:-false}"

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
# util-linux provides runuser on Debian-family minimal containers. The root
# wrappers below depend on it; without this, `as_hermes ...` fails with
# `/usr/local/bin/as_hermes: exec: runuser: not found`.
apt-get install -y -qq curl ca-certificates gnupg git jq util-linux >/dev/null
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

if [[ "$ENABLE_AGENT_JOURNAL_READ" == "true" ]]; then
  usermod -aG systemd-journal "$OC_USER"
  ok "$OC_USER added to systemd-journal group (can read journalctl)"
fi

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
AGENT_PATH=${AGENT_PATH}
GIT_SSH_KEY=${CONFIG_GIT_SSH_KEY:-}
EOF
chmod 644 /etc/agent-lxc.env

# ── Tailscale (always installed for all agents / all exposure modes) ─────────
log "Tailscale"
curl -fsSL https://tailscale.com/install.sh | sh >/dev/null 2>&1
[[ -n "${TAILSCALE_AUTHKEY:-}" ]] && tailscale up --authkey="${TAILSCALE_AUTHKEY}" --hostname="${CT_HOSTNAME:-$OC_USER}" >/dev/null 2>&1 || true
tailscale set --operator="$OC_USER" >/dev/null 2>&1 || true
ok "Tailscale installed; operator=$OC_USER"

# ── exposure (OpenClaw: automated; hermes: manual, printed at end) ──────────
if [[ "$AGENT" == "openclaw" ]]; then
  log "Gateway exposure (mode: $EXPOSURE_MODE)"
  as_agent "$AGENT_CMD" config set gateway.mode local >/dev/null
  as_agent "$AGENT_CMD" config set gateway.bind loopback >/dev/null
  case "$EXPOSURE_MODE" in
    tailscale)
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
install -m 755 "$REPO_ROOT/bin/agent-gateway-status" /usr/local/bin/agent-gateway-status
if [[ "$AGENT" == "hermes" ]]; then
  install -m 755 "$REPO_ROOT/bin/hermes-gateway-control" /usr/local/sbin/hermes-gateway-control
  install -m 755 "$REPO_ROOT/bin/hermes-gateway-control-daemon" /usr/local/sbin/hermes-gateway-control-daemon
fi

# Root convenience wrapper: run the agent as the non-root user. e.g.
# `ropenclaw config get gateway`, `rhermes setup`.
cat > "/usr/local/bin/r${AGENT}" <<EOF
#!/bin/sh
# Run ${AGENT} as the non-root '${OC_USER}' user with its correct HOME/PATH.
# cd first so the agent's cwd is its home, not wherever root invoked us from.
cd ${OC_HOME}
exec runuser -u ${OC_USER} -- env HOME=${OC_HOME} PATH=${AGENT_PATH} ${AGENT_CMD} "\$@"
EOF
chmod 755 "/usr/local/bin/r${AGENT}"
ok "root wrapper installed: r${AGENT} (runs ${AGENT} as ${OC_USER})"

# General-purpose helper: run any command as the agent user with its env.
# e.g. `as_hermes signal-cli ...`, `as_hermes git -C ~/.hermes status`
cat > "/usr/local/bin/as_${OC_USER}" <<EOF
#!/bin/sh
cd ${OC_HOME}
exec runuser -u ${OC_USER} -- env HOME=${OC_HOME} PATH=${AGENT_PATH} "\$@"
EOF
chmod 755 "/usr/local/bin/as_${OC_USER}"
ok "root helper installed: as_${OC_USER} (runs any command as ${OC_USER})"

# Ensure /usr/local/bin is on root's interactive PATH. `pct enter` spawns a
# NON-login shell (skips /etc/profile), so r<agent> / agent-config-* wouldn't be
# found by bare name without this. Cover non-login (.bashrc) + login (profile.d).
PATH_LINE='export PATH="/usr/local/bin:$PATH"'
grep -qxF "$PATH_LINE" /root/.bashrc 2>/dev/null || echo "$PATH_LINE" >> /root/.bashrc
echo "$PATH_LINE" > /etc/profile.d/usr-local-bin.sh
chmod 644 /etc/profile.d/usr-local-bin.sh
ok "ensured /usr/local/bin on root PATH (pct enter + login shells)"

subst() { sed -e "s|@OC_USER@|$OC_USER|g" -e "s|@OC_HOME@|$OC_HOME|g" \
              -e "s|@AGENT_CMD@|$AGENT_CMD|g" -e "s|@AGENT_PATH@|$AGENT_PATH|g" "$1"; }
subst "$REPO_ROOT/systemd/agent-gateway.service"      > /etc/systemd/system/agent-gateway.service
if [[ "$AGENT" == "hermes" && -f "$REPO_ROOT/systemd/agent-gateway@.service" ]]; then
  subst "$REPO_ROOT/systemd/agent-gateway@.service" > /etc/systemd/system/agent-gateway@.service
  if [[ "$ENABLE_HERMES_GATEWAY_CONTROL" == "true" && -f "$REPO_ROOT/systemd/hermes-gateway-control.service" ]]; then
    subst "$REPO_ROOT/systemd/hermes-gateway-control.service" > /etc/systemd/system/hermes-gateway-control.service
  fi
fi
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

# Seed AGENTS.md for hermes so it knows its operating environment without relying
# on prior session memory. Placed in OC_HOME (workspace root hermes checks first).
if [[ "$AGENT" == "hermes" ]]; then
  JOURNAL_NOTE="journalctl requires root or the systemd-journal group."
  [[ "$ENABLE_AGENT_JOURNAL_READ" == "true" ]] && \
    JOURNAL_NOTE="journalctl -u agent-gateway is readable as ${OC_USER} (systemd-journal group)."
  SIGNAL_NOTE=""
  [[ "$ENABLE_SIGNAL" == "true" ]] && \
    SIGNAL_NOTE=$'\n\n## Signal integration\n\nagent-signal.service manages the signal-cli daemon. Create\n'"${AGENT_LIVE}/signal.env"$' with SIGNAL_ACCOUNT and SIGNAL_HTTP_LISTEN\nbefore starting it. agent-gateway.service starts after it when Signal is enabled.'

  cat > "${OC_HOME}/AGENTS.md" <<EOF
# AGENTS.md — Local Operations Context

This Hermes instance runs inside a hardened, unprivileged Proxmox LXC container
provisioned by proxmox-agent-lxc. Read this before taking any infra actions.

## Gateway management

The gateway is a **systemd system service** — NOT a user service.
\`hermes gateway restart\` targets a user systemd session that does not exist
for the \`${OC_USER}\` system account. Do not use it as a control plane here.

Self-inspection (${OC_USER} user can run these):
  systemctl status agent-gateway
  systemctl is-active agent-gateway
  agent-gateway-status              # compact health: gateway + signal + logs

Restart/stop/start normally requires root (operator action):
  systemctl {restart,stop,start} agent-gateway

If ENABLE_HERMES_GATEWAY_CONTROL=true, Hermes can request status/restart via the
root sidecar without sudo, including from gateway sessions with NoNewPrivileges:
  /usr/local/sbin/hermes-gateway-control status
  /usr/local/sbin/hermes-gateway-control restart

For non-default Hermes profiles, use the systemd instance unit instead of
Hermes' user-service control plane:
  systemctl enable --now agent-gateway@PROFILE.service
  systemctl restart agent-gateway@PROFILE.service
  systemctl status agent-gateway@PROFILE.service

Example:
  systemctl enable --now agent-gateway@gallarno-tech.service
  systemctl restart agent-gateway@gallarno-tech.service

If ENABLE_HERMES_GATEWAY_CONTROL=true was set at provisioning time, ${OC_USER}
can use the root sidecar through a restricted Unix socket even from gateway
sessions running under NoNewPrivileges=yes:
  /usr/local/sbin/hermes-gateway-control restart gallarno-tech
  /usr/local/sbin/hermes-gateway-control status gallarno-tech

The sidecar accepts only status/restart requests for agent-gateway.service and
agent-gateway@PROFILE.service. It is not broad sudo and does not expose a shell.

Do not use `hermes --profile PROFILE gateway start/restart` in this LXC unless
you have deliberately configured user linger; it tries to reach systemd --user
and fails for this system account.

## Log access

${JOURNAL_NOTE}
Gateway log file (always readable): ${AGENT_LIVE}/logs/gateway.log
agent-gateway-status shows recent log lines without needing journal access.

## Root helpers (available in operator root shells)

  as_${OC_USER} <cmd>      run any command as ${OC_USER} with correct env+PATH
  r${AGENT} <args>         run ${AGENT} binary as ${OC_USER}
  agent-gateway-status     compact health view
  hermes-gateway-control   Hermes-only status/restart via sidecar (if enabled)
  agent-config-log         git log of tracked config changes
  agent-config-restore     restore config from git history
${SIGNAL_NOTE}
EOF
  chown "${OC_USER}:${OC_USER}" "${OC_HOME}/AGENTS.md"
  ok "seeded ${OC_HOME}/AGENTS.md with local ops context"
fi

# ── optional: headless browser ──────────────────────────────────────────────
if [[ "$ENABLE_BROWSER" == "true" ]]; then
  log "Headless browser"
  if [[ "$AGENT" == "hermes" ]]; then
    # hermes bundles its own Playwright Chromium during install; it only needs
    # the system libraries, which the non-root installer couldn't apt-get.
    echo "  Installing Playwright system libraries (root)..."
    if (cd "$OC_HOME/.hermes/hermes-agent" 2>/dev/null && \
        PATH="$OC_HOME/.hermes/node/bin:$PATH" npx --yes playwright install-deps chromium >/dev/null 2>&1); then
      ok "Playwright system libs installed (hermes drives its bundled Chromium)"
    else
      warn "Couldn't auto-install Playwright deps. Run as root once:"
      echo "      cd $OC_HOME/.hermes/hermes-agent && PATH=$OC_HOME/.hermes/node/bin:\$PATH npx playwright install-deps chromium"
    fi
  else
    echo "  (pulls ~several hundred MB; this can take a few minutes with no output)"
    apt-get install -y -qq chromium fonts-liberation >/dev/null 2>&1 \
      || apt-get install -y -qq chromium-browser >/dev/null 2>&1 || true
    command -v chromium >/dev/null 2>&1 || command -v chromium-browser >/dev/null 2>&1 \
      && ok "Chromium installed (agent drives it headless)" \
      || warn "Chromium not found; install manually"
  fi
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

  # Install signal-cli daemon as a systemd service (hermes only).
  # The service won't start until ${AGENT_LIVE}/signal.env is created with
  # SIGNAL_ACCOUNT=+E164 and SIGNAL_HTTP_LISTEN=127.0.0.1:8080
  if [[ "$AGENT" == "hermes" ]]; then
    subst "$REPO_ROOT/systemd/agent-signal.service" > /etc/systemd/system/agent-signal.service
    systemctl enable agent-signal.service
    # Make gateway wait for signal daemon to be up before starting
    sed -i '/^\[Service\]/i Wants=agent-signal.service' /etc/systemd/system/agent-gateway.service
    sed -i '/^\[Service\]/i After=agent-signal.service'  /etc/systemd/system/agent-gateway.service
    ok "agent-signal.service enabled; agent-gateway.service will start after it"
    warn "Create ${AGENT_LIVE}/signal.env with SIGNAL_ACCOUNT + SIGNAL_HTTP_LISTEN, then: systemctl start agent-signal"
  fi
fi

# ── enable services ─────────────────────────────────────────────────────────
log "Enable services"
systemctl daemon-reload
systemctl enable --now agent-gateway.service
if [[ "$AGENT" == "hermes" && "$ENABLE_HERMES_GATEWAY_CONTROL" == "true" ]]; then
  systemctl enable --now hermes-gateway-control.service
fi
systemctl enable --now agent-config-watch.path
sleep 5
if systemctl is-active --quiet agent-gateway; then
  ok "gateway active (non-root '$OC_USER'); config watcher enabled"
else
  warn "agent-gateway is not active — check: journalctl -u agent-gateway -n 50"
fi
as_agent /usr/local/bin/agent-config-push || true

# ── exposure follow-up ───────────────────────────────────────────────────────
if ! tailscale status >/dev/null 2>&1; then
  cat <<EOF

  ┌─ ACTION REQUIRED ─ Tailscale installed but not logged in ─────────────────
  │   pct exec <vmid> -- tailscale up --hostname=${CT_HOSTNAME:-$OC_USER}
  │   pct exec <vmid> -- tailscale set --operator=${OC_USER}    # AFTER 'up'
EOF
  if [[ "$AGENT" == "openclaw" && "$EXPOSURE_MODE" == "tailscale" ]]; then
    cat <<EOF
  │   pct exec <vmid> -- systemctl restart agent-gateway
  │   pct exec <vmid> -- tailscale serve status                 # allow ~30s
EOF
  fi
  echo "  └───────────────────────────────────────────────────────────────────────────"
fi

if [[ "$AGENT" == "hermes" ]]; then
  cat <<EOF

  ┌─ hermes-agent access ─ messaging-only gateway, no inbound web port ───────
  │ Verified (live test): 'hermes gateway' opens NO local HTTP port — it
  │ connects OUT to messaging platforms, so there is nothing to Tailscale-Serve
  │ and no dashboard to bind. Tailscale IS installed (use it for SSH/LAN access
  │ or future needs). Use Hermes via (no sudo in this LXC — use the r${AGENT}
  │ wrapper):
  │   • Pick a model:  pct enter <vmid> ; r${AGENT} model
  │   • Chat (TUI):    r${AGENT}
  │   • Messaging:     r${AGENT} gateway setup
  └───────────────────────────────────────────────────────────────────────────
EOF
fi

log "Done"
echo "  Agent '$AGENT' runs as non-root '$OC_USER'. Manage: systemctl {status,restart} agent-gateway"
echo "  Run agent commands as root: r${AGENT} <args>   (e.g. r${AGENT} setup, r${AGENT} model)"
echo "  Config history: runuser -u $OC_USER -- agent-config-log"
