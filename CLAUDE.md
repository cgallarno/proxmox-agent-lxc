# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Shell provisioner for hardened, unprivileged Proxmox LXC containers running AI agents (OpenClaw or hermes-agent). Two entry points: `provision-lxc.sh` runs on the Proxmox **host** as root; it creates the container, then copies the repo in and calls `container/setup.sh` inside it. The two scripts share state only via environment variables.

## No build step

This is pure shell — no compilation, no package manager, no tests. "Development" means editing `.sh` files and validating with `shellcheck`.

```bash
shellcheck provision-lxc.sh
shellcheck container/setup.sh
shellcheck bin/agent-config-push bin/agent-config-restore bin/agent-config-log
```

## Architecture

### Two-phase provisioning

```
Proxmox host (root)              Container (root)
provision-lxc.sh         →      container/setup.sh
  - create LXC                    - apt packages
  - add TUN passthrough           - create non-root OC_USER
  - tar repo → pct push           - install agent (openclaw or hermes)
  - pct exec setup.sh             - write /etc/agent-lxc.env
                                  - install Tailscale
                                  - configure exposure (openclaw only)
                                  - install systemd units
                                  - install root helpers
```

### /etc/agent-lxc.env — shared runtime state

`setup.sh` writes this file; all three `bin/` scripts source it at runtime. It records `AGENT`, `OC_USER`, `OC_HOME`, `AGENT_CMD`, `AGENT_LIVE`, `AGENT_REPO`, `TRACKED_FILES`, `GIT_SSH_KEY`. It's the single source of truth for agent-agnostic tooling inside the container.

### Systemd units — templates with placeholders

`systemd/agent-gateway.service` and `agent-config-watch.service` contain `@OC_USER@`, `@OC_HOME@`, `@AGENT_CMD@`, `@AGENT_PATH@` placeholders. `setup.sh` renders them via `sed` into `/etc/systemd/system/`. The `.path` watcher is generated dynamically from `$TRACKED_FILES`. Never edit the rendered copies — edit the templates in `systemd/`.

### Config history pattern

`bin/agent-config-push` copies only the allowlisted `$TRACKED_FILES` from the live dir (`$AGENT_LIVE`) into the git repo (`$AGENT_REPO`) and commits. It never touches secrets, sessions, or state files. `agent-config-watch.path` fires it on any change. `agent-config-restore` uses `git show <ref>:<file>` — never modifies the repo working tree.

### Agent differences

| | OpenClaw | hermes-agent |
|---|---|---|
| Install | `npm install -g openclaw` (root, global) | official installer run as `OC_USER` with `--skip-setup` |
| Live config dir | `$OC_HOME/.openclaw/` | `$OC_HOME/.hermes/` |
| Tracked files | `openclaw.json exec-approvals.json cron/jobs.json` | `config.yaml gateway.json` |
| Exposure | Automated (`tailscale`/`loopback`/`lan-token`) | None — no inbound HTTP port |
| Browser | System Chromium via apt | Bundled Playwright Chromium; only system libs installed here |

### Root helpers installed in the container

- **`r<agent>`** (`ropenclaw` / `rhermes`) — `cd $OC_HOME && runuser -u $OC_USER -- env HOME=… PATH=… $AGENT_CMD "$@"`. The `cd` is load-bearing: hermes-agent does git operations in cwd; running from `/root` causes EACCES on `/root/.git`.
- **`as_<OC_USER>`** (`as_openclaw` / `as_hermes`) — same env setup but takes an arbitrary command, not the agent binary.

## Key constraints

- `OC_USER` must never be root — enforced in `provision-lxc.sh` preflight.
- `EXPOSURE_MODE` logic only runs for `AGENT=openclaw`. Hermes has no inbound port.
- TUN passthrough (`lxc.mount.entry: /dev/net/tun`) must be in the host `.conf` **before** container start — it's not hot-pluggable.
- The `.path` watcher watches `$AGENT_LIVE` files; `agent-config-push` writes to `$AGENT_REPO`. These are different directories by design to prevent the watcher from self-triggering.
- Secrets (`credentials/`, `sessions/`, `state.db`, API keys) must never appear in `TRACKED_FILES`.
