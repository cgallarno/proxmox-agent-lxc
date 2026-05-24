#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# provision-lxc.sh — create a hardened, UNPRIVILEGED OpenClaw LXC on Proxmox.
#
# Run on the Proxmox HOST as root. Reads ./config.env (copy from
# config.example.env). Creates the container, then runs container/setup.sh
# inside it to install + harden OpenClaw (non-root agent, loopback+Tailscale,
# git-backed config history, optional headless browser / Signal).
#
# NOTE: this provisioner has NOT yet been run end-to-end on a live host — review
# and test on a throwaway VMID before relying on it. The in-container scripts
# mirror a setup validated by hand.
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${1:-$SCRIPT_DIR/config.env}"

c_info(){ echo -e "\033[0;36m[INFO]\033[0m  $*"; }
c_ok(){   echo -e "\033[0;32m[OK]\033[0m    $*"; }
fatal(){  echo -e "\033[0;31m[ERROR]\033[0m $*" >&2; exit 1; }

# ── preflight ───────────────────────────────────────────────────────────────
[[ $(id -u) -eq 0 ]] || fatal "Run as root on the Proxmox host."
command -v pct   >/dev/null || fatal "pct not found — run on a Proxmox host."
command -v pveam >/dev/null || fatal "pveam not found — run on a Proxmox host."
[[ -f "$CONFIG_FILE" ]] || fatal "Config not found: $CONFIG_FILE (copy config.example.env → config.env)"
# shellcheck source=/dev/null
source "$CONFIG_FILE"

[[ "${OC_USER:-root}" != "root" ]] || fatal "OC_USER must not be root."
if [[ "${EXPOSURE_MODE:-}" == "tailscale" && -z "${TAILSCALE_AUTHKEY:-}" ]]; then
  c_info "EXPOSURE_MODE=tailscale but no TAILSCALE_AUTHKEY set — you'll run 'tailscale up' manually later."
fi

# ── detect VMID / storage / template ─────────────────────────────────────────
VMID="${CT_VMID:-}"
if [[ -z "$VMID" ]]; then
  VMID=$(pvesh get /cluster/resources --type vm --output-format json 2>/dev/null \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); ids=[r["vmid"] for r in d if "vmid" in r]; print(max(ids)+1 if ids else 100)' 2>/dev/null || echo 100)
fi
c_ok "VMID: $VMID"

TMPL_STORAGE="${TMPL_STORAGE:-$(pvesh get /storage --output-format json 2>/dev/null \
  | python3 -c 'import json,sys; [print(s["storage"]) or exit() for s in json.load(sys.stdin) if "vztmpl" in s.get("content","")]' 2>/dev/null || echo local)}"
ROOT_STORAGE="${ROOT_STORAGE:-$(pvesh get /storage --output-format json 2>/dev/null \
  | python3 -c 'import json,sys
s=json.load(sys.stdin); c=[x["storage"] for x in s if "rootdir" in x.get("content","") or "images" in x.get("content","")]
print("local-lvm" if "local-lvm" in c else (c[0] if c else "local-lvm"))' 2>/dev/null || echo local-lvm)}"
c_ok "Template storage: $TMPL_STORAGE | Rootfs storage: $ROOT_STORAGE"

pveam update >/dev/null 2>&1 || true
TEMPLATE=$(pveam available --section system 2>/dev/null | grep -oP 'debian-13-standard_\S+' | head -1 || true)
[[ -n "$TEMPLATE" ]] || fatal "No Debian 13 template found (check 'pveam available')."
if ! pveam list "$TMPL_STORAGE" 2>/dev/null | grep -q "$TEMPLATE"; then
  c_info "Downloading $TEMPLATE..."; pveam download "$TMPL_STORAGE" "$TEMPLATE"
fi
c_ok "Template: $TEMPLATE"

# ── create UNPRIVILEGED container ────────────────────────────────────────────
c_info "Creating unprivileged LXC $VMID..."
pct create "$VMID" "${TMPL_STORAGE}:vztmpl/${TEMPLATE}" \
  --hostname "${CT_HOSTNAME:-openclaw}" \
  --rootfs "${ROOT_STORAGE}:${CT_DISK_GB:-16}" \
  --memory "${CT_MEMORY_MB:-4096}" \
  --cores "${CT_CORES:-2}" \
  --net0 "name=eth0,bridge=${CT_BRIDGE:-vmbr0},ip=dhcp" \
  --unprivileged 1 \
  --features nesting=1,keyctl=1 \
  --start 0
c_ok "Container created (unprivileged, nesting+keyctl for chromium sandbox/userns)."

# Tailscale in an unprivileged LXC needs the TUN device.
if [[ "${EXPOSURE_MODE:-}" == "tailscale" ]]; then
  CONF="/etc/pve/lxc/${VMID}.conf"
  grep -q '/dev/net/tun' "$CONF" 2>/dev/null || cat >> "$CONF" <<'TUN'
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
TUN
  c_ok "Added /dev/net/tun passthrough for Tailscale."
fi

pct start "$VMID"; sleep 3

# ── wait for network ─────────────────────────────────────────────────────────
for _ in $(seq 1 30); do
  CT_IP=$(pct exec "$VMID" -- hostname -I 2>/dev/null | awk '{print $1}' || true)
  [[ -n "${CT_IP:-}" && "$CT_IP" != "127.0.0.1" ]] && break; CT_IP=""; sleep 1
done
c_ok "Container IP: ${CT_IP:-unknown}"

# ── push repo + run setup inside the container ───────────────────────────────
c_info "Copying repo into container and running setup..."
TARBALL="/tmp/openclaw-lxc-hardened.$$.tar.gz"
tar -C "$SCRIPT_DIR" -czf "$TARBALL" bin systemd container config.example.env
pct exec "$VMID" -- mkdir -p /opt/openclaw-lxc-hardened
pct push "$VMID" "$TARBALL" /opt/openclaw-lxc-hardened/repo.tar.gz
pct exec "$VMID" -- tar -C /opt/openclaw-lxc-hardened -xzf /opt/openclaw-lxc-hardened/repo.tar.gz
rm -f "$TARBALL"

pct exec "$VMID" -- env \
  AGENT="${AGENT:-openclaw}" \
  OC_USER="${OC_USER}" \
  EXPOSURE_MODE="${EXPOSURE_MODE:-tailscale}" \
  TAILSCALE_AUTHKEY="${TAILSCALE_AUTHKEY:-}" \
  CT_HOSTNAME="${CT_HOSTNAME:-openclaw}" \
  CONFIG_GIT_REMOTE="${CONFIG_GIT_REMOTE:-}" \
  CONFIG_GIT_SSH_KEY="${CONFIG_GIT_SSH_KEY:-}" \
  ENABLE_BROWSER="${ENABLE_BROWSER:-true}" \
  ENABLE_SIGNAL="${ENABLE_SIGNAL:-false}" \
  bash /opt/openclaw-lxc-hardened/container/setup.sh

c_ok "Setup complete."
echo
echo "  Agent     : ${AGENT:-openclaw}"
echo "  Container : $VMID  (${CT_IP:-unknown})"
echo "  Manage    : pct enter $VMID ;  pct stop $VMID ;  pct start $VMID"
echo "  Gateway   : runs as non-root '$OC_USER' (systemctl status agent-gateway)"
if [[ "${AGENT:-openclaw}" == "hermes" ]]; then
  echo "  Access    : MANUAL — see the EXPERIMENTAL exposure block above (hermes port/bind not yet automated)"
else
  case "${EXPOSURE_MODE:-}" in
    tailscale) echo "  Access    : https://<magicdns-name>/ (tailnet-only) — if no auth key, see ACTION REQUIRED above";;
    loopback)  echo "  Access    : ssh -L 18789:127.0.0.1:18789 root@${CT_IP:-<ip>} then http://127.0.0.1:18789/";;
    lan-token) echo "  Access    : http://${CT_IP:-<ip>}:18789/  (token printed above)";;
  esac
fi
