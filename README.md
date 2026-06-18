# proxmox-agent-lxc

Provision a **hardened, headless AI agent** in an **unprivileged** Proxmox LXC
— non-root, Tailscale-connected, with git-backed config history and one-command
recovery. Supports **OpenClaw** and **hermes-agent**. A security-first
counterpart to the common "desktop agent in a privileged container" scripts.

> **Status:** validated end-to-end on Proxmox VE (Debian 13) — fresh
> unprivileged container to a live tailnet-served gateway. Tailscale bring-up
> needs an auth key for full automation; otherwise the installer prints the
> manual `tailscale up` + operator steps. PRs welcome.

## Why another one?

Most agent-on-Proxmox scripts optimize for a quick GUI demo and make choices
that are fine for a toy but wrong for something you actually leave running:

| Concern | Typical "desktop" script | This repo |
|---|---|---|
| Container | **privileged** (`--unprivileged 0`) — container root ≈ host root | **unprivileged** — container root maps to an unprivileged host uid |
| Agent process | runs as **root** | runs as a dedicated **non-root** user |
| Gateway exposure | `bind lan` + no auth | `bind loopback` + **Tailscale Serve** (tailnet-only) |
| Browser | full Chrome as **root** with `--no-sandbox` | **headless Chromium** as the agent user, no VNC |
| Leftover privilege | standing `NOPASSWD:ALL` helper user | none |
| Config | one-shot, no history | **git-backed**, auto-commit on change, one-command restore |
| Recovery / DR | none | restore tool + documented Proxmox backup |

Why it matters: an agent executes commands and (increasingly) processes
**untrusted input** — emails, web pages, messages. That's a prompt-injection
surface. Least privilege is the containment when, not if, something tries to
abuse it. Root + a browser + untrusted input is the combination you don't want.

## Quick start (on the Proxmox host, as root)

```bash
git clone <your-fork> openclaw-lxc-hardened && cd openclaw-lxc-hardened
cp config.example.env config.env
$EDITOR config.env            # set AGENT, OC_USER, EXPOSURE_MODE, TAILSCALE_AUTHKEY, ...
./provision-lxc.sh
```

To install into an **existing** Debian 13 LXC instead, copy the repo inside and
run `container/setup.sh` with the same env vars exported.

## Agent selection

Set `AGENT` in `config.env`:

- **`openclaw`** *(default, validated)* — Node-based [OpenClaw](https://openclaw.ai).
  Fully automated including Tailscale Serve exposure and web dashboard.
- **`hermes`** *(experimental)* — Python-based
  [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent).
  Install (via its official installer, run **non-root** with `--skip-setup`),
  non-root systemd unit, config history, and bundled-Playwright browser are
  automated. **No inbound web port** — verified on a live run that
  `hermes gateway` opens no local HTTP port (it connects outward to messaging
  platforms). Use via CLI/TUI or messaging channels. Tailscale is still
  installed (useful for SSH access and future needs).

Both share the same hardened scaffold: unprivileged LXC, non-root agent user,
Tailscale, git-backed config history, recovery tools.

## What it sets up

- **Agent runtime** under a dedicated non-root `OC_USER`, managed by a hardened
  systemd unit (`NoNewPrivileges`, `ProtectSystem=full`, `PrivateTmp`, writable
  only under the agent home).
- **Tailscale** — always installed regardless of agent or exposure mode.
  Set `TAILSCALE_AUTHKEY` for fully automated bring-up.
- **Exposure mode** (`EXPOSURE_MODE`) — *OpenClaw only*; hermes has no inbound port:
  - `tailscale` *(recommended)* — `bind loopback` + Tailscale Serve, reachable
    only on your tailnet at `https://<magicdns>/`, `auth=none` (safe *only*
    because ingress is loopback + tailnet).
  - `loopback` — bind loopback only; reach via SSH tunnel.
  - `lan-token` — bind LAN **with** a generated token (never wide-open + no-auth).
- **Config history** — live config files are mirrored into a git repo and
  auto-committed on every change by a systemd `.path` watcher; pushed to
  `CONFIG_GIT_REMOTE` if set. Tracked files per agent:
  - OpenClaw: `openclaw.json`, `exec-approvals.json`, `cron/jobs.json`
  - hermes: `config.yaml`, `gateway.json`
- **Recovery** — `agent-config-restore [git-ref]` writes any past version back
  to the live config; `agent-config-log` shows history.
- **Headless browser** *(optional, `ENABLE_BROWSER=true`)* — Chromium for
  OpenClaw's built-in browser automation, or Playwright system libs for
  hermes-agent's bundled Chromium. No VNC, no `--no-sandbox`.
- **Signal** *(optional, `ENABLE_SIGNAL=true`)* — native `signal-cli` binary.

## Day-to-day operations

The container ships **no broad `sudo`**. These root/operator helpers are installed:

- **`r<agent>`** (`ropenclaw` / `rhermes`) — runs the agent binary as the
  non-root user, cwd set to agent home.
- **`as_<user>`** (`as_openclaw` / `as_hermes`) — runs *any* command as the
  agent user with the correct `HOME` and `PATH`. More general than `r<agent>`.
- **`hermes-gateway-control`** *(Hermes only, optional)* — when
  `ENABLE_HERMES_GATEWAY_CONTROL=true`, lets the Hermes user restart/status only
  the provisioner's gateway systemd units via narrow sudo.

### Gateway (start / stop / restart)

The canonical way to manage the gateway in this container is **systemd**,
regardless of agent:

```bash
systemctl status agent-gateway
systemctl restart agent-gateway
systemctl stop agent-gateway
systemctl start agent-gateway
```

> `rhermes gateway restart` tells hermes-agent's internal process manager to
> restart — it may work, but `systemctl restart agent-gateway` is what
> controls the actual unit and is always correct for both agents.

For extra Hermes profiles, run a separate systemd system-service instance:

```bash
systemctl enable --now agent-gateway@gallarno-tech.service
systemctl restart agent-gateway@gallarno-tech.service
systemctl status agent-gateway@gallarno-tech.service
```

Do **not** rely on `hermes --profile gallarno-tech gateway start/restart` inside
this hardened LXC. The agent user is a system account without user linger, so
Hermes' user-service control path cannot reach `systemctl --user` unless you
explicitly enable linger. System instances avoid that whole tiny clown car.

If you want Hermes itself to be able to restart those system units, enable the
Hermes-only narrow helper at provisioning time:

```bash
ENABLE_HERMES_GATEWAY_CONTROL="true"
```

That installs `sudo` only to allow the agent user to run:

```bash
sudo /usr/local/sbin/hermes-gateway-control restart gallarno-tech
sudo /usr/local/sbin/hermes-gateway-control status gallarno-tech
```

The helper validates the action/profile and only targets
`agent-gateway.service` or `agent-gateway@<profile>.service`; it is not a
blank-check `NOPASSWD:ALL` situation, because we are not animals.

Config watcher (auto-commits config changes to git):

```bash
systemctl status agent-config-watch.path
systemctl restart agent-config-watch.path
```

### Running agent commands

```bash
# Both agents — run as non-root agent user
rhermes                        # open interactive TUI
rhermes model                  # pick / change model
rhermes gateway setup          # configure messaging channels (hermes)

ropenclaw config get gateway   # inspect gateway config (OpenClaw only)
ropenclaw config set <key> <val>
```

### Running arbitrary commands as the agent user

```bash
as_hermes signal-cli -a +1234567890 listAccounts
as_hermes git -C ~/.hermes status
as_openclaw env | grep PATH
```

### Config history

```bash
agent-config-log               # show git log of config changes
agent-config-restore           # restore latest from origin/main
agent-config-restore HEAD~2    # restore a specific past version
agent-config-push              # manually push current config to remote
```

### Logs

```bash
journalctl -u agent-gateway -n 100 --no-pager
journalctl -u agent-config-watch -n 50 --no-pager
```

## Security model

- **Unprivileged LXC** is the outer boundary; `nesting=1,keyctl=1` are enabled
  only so Chromium's user-namespace sandbox works inside it.
- **The agent is never root.** Operator tasks stay with host root / your SSH
  login; the agent's privilege is independent of your convenience.
- **Secrets stay out of git.** Only the allowlisted config files are committed.
  Put API keys in an untracked file under the agent home — never inline in the
  tracked config.
- **Exposure never widens without auth.** *(OpenClaw)* Changing `bind` to
  lan/auto or enabling Tailscale Funnel must add `token`/`password` auth in the
  same change.

## Disaster recovery

Git history covers **config only**. The agent's identity, sessions, credentials,
and secrets files are intentionally *not* in git. Cover them with a scheduled
**Proxmox backup** of the container (Datacenter → Backup) to offsite storage —
host-side, captures everything, low maintenance.

## Layout

```
provision-lxc.sh            host-side: create the unprivileged LXC, run setup
container/setup.sh          in-container: install + harden the agent
config.example.env          tunables (copy to config.env)
bin/                        agent-config-{push,restore,log} (both agents)
systemd/                    agent-gateway + agent-config-watch unit templates
```

## License

MIT — see [LICENSE](LICENSE).
