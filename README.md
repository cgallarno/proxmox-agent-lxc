# openclaw-lxc-hardened

Provision a **hardened, headless [OpenClaw](https://openclaw.ai) agent** in an
**unprivileged** Proxmox LXC — non-root, tailnet-only, with git-backed config
history and one-command recovery. A security-first counterpart to the common
"desktop OpenClaw in a privileged container" scripts.

> **Status:** validated end-to-end on Proxmox VE (Debian 13 / OpenClaw 2026.5.x)
> — fresh unprivileged container to a live tailnet-served gateway. Tailscale
> bring-up needs an auth key for full automation; otherwise the installer prints
> the manual `tailscale up` + operator steps. PRs welcome.

## Why another one?

Most OpenClaw-on-Proxmox scripts optimize for a quick GUI demo and make choices
that are fine for a toy but wrong for something you actually leave running:

| Concern | Typical "desktop" script | This repo |
|---|---|---|
| Container | **privileged** (`--unprivileged 0`) — container root ≈ host root | **unprivileged** — container root maps to an unprivileged host uid |
| Agent process | runs as **root** | runs as a dedicated **non-root** user |
| Gateway exposure | `bind lan` + `dangerouslyAllowHostHeaderOriginFallback` | `bind loopback` + **Tailscale Serve** (tailnet-only); no origin downgrade |
| Browser | full Chrome as **root** with `--no-sandbox`, exposed via VNC/noVNC | **headless Chromium** as the agent user, driven by OpenClaw, no VNC |
| Leftover privilege | standing `NOPASSWD:ALL` helper user | none |
| Config | one-shot, no history | **git-backed**, auto-commit on change, one-command restore |
| Recovery / DR | none | restore tool + documented Proxmox backup |

Why it matters: an OpenClaw agent executes commands and (increasingly) processes
**untrusted input** — emails, web pages, messages. That's a prompt-injection
surface. Least privilege is the containment when, not if, something tries to
abuse it. Root + a browser + untrusted input is the combination you don't want.

## Quick start (on the Proxmox host, as root)

```bash
git clone <your-fork> openclaw-lxc-hardened && cd openclaw-lxc-hardened
cp config.example.env config.env
$EDITOR config.env            # set OC_USER, EXPOSURE_MODE, TAILSCALE_AUTHKEY, ...
./provision-lxc.sh
```

To install into an **existing** Debian 13 LXC instead, copy the repo inside and
run `container/setup.sh` with the same env vars exported.

## What it sets up

- OpenClaw (latest) on Node 22, gateway running as the non-root `OC_USER` under
  a hardened systemd unit (`NoNewPrivileges`, `ProtectSystem=full`, `PrivateTmp`,
  writable only under the agent home).
- **Exposure mode** (`EXPOSURE_MODE`):
  - `tailscale` *(recommended)* — `bind loopback` + Tailscale Serve, reachable
    only on your tailnet at `https://<magicdns>/`, `auth=none` (safe *only*
    because ingress is loopback + tailnet). Set `TAILSCALE_AUTHKEY` for a fully
    automated bring-up; without it you'll run `tailscale up` manually, then
    **re-set the operator** (`tailscale up` resets it) and restart the gateway —
    the installer prints the exact commands.
  - `loopback` — bind loopback only; reach via SSH tunnel.
  - `lan-token` — bind LAN **with** a generated token (never wide-open + no-auth).
- **Config history** — the live config (`openclaw.json`, `exec-approvals.json`,
  `cron/jobs.json`) is mirrored into a git repo and auto-committed on every
  change by a systemd `.path` watcher; pushed to `CONFIG_GIT_REMOTE` if set.
- **Recovery** — `openclaw-config-restore [git-ref]` writes any past version back
  to the live config; `openclaw-config-log` shows history.
- **Headless browser** *(optional)* — Chromium for OpenClaw's built-in browser
  automation (`openclaw browser navigate|snapshot|click|pdf|…`). Great for
  news-gathering/summarization and API-less sites. No VNC, no `--no-sandbox`.
- **Signal** *(optional)* — native `signal-cli` build for the Signal channel.

## Security model

- **Unprivileged LXC** is the outer boundary; `nesting=1,keyctl=1` are enabled
  only so Chromium's user-namespace sandbox works *inside* it.
- **The agent is never root.** Operator tasks stay with host root / your SSH
  login; the agent's privilege is independent of your convenience.
- **Secrets stay out of git.** Only three allowlisted files are committed; put
  API keys / tokens in an untracked file under the agent home and reference them
  via OpenClaw SecretRefs — never inline in `openclaw.json`.
- **Exposure never widens without auth.** Changing `bind` to lan/auto or enabling
  Tailscale Funnel must add `token`/`password` in the same change.

## Disaster recovery

Git history covers **config only**. The agent's identity, sessions, credentials,
and any secrets file are intentionally *not* in git. Cover them with a scheduled
**Proxmox backup** of the container (Datacenter → Backup) to offsite storage —
host-side, captures everything, low maintenance.

## Layout

```
provision-lxc.sh            host-side: create the unprivileged LXC, run setup
container/setup.sh          in-container: install + harden OpenClaw
config.example.env          tunables (copy to config.env)
bin/                        openclaw-config-{push,restore,log}
systemd/                    gateway + config-watch unit templates (@PLACEHOLDERS@)
```

## License

No license file yet — add one before publishing (MIT is a reasonable default for
this kind of tooling).
