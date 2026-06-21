#!/usr/bin/env bash
# Deploy fedora-desktop (rootless podman). The deploy contract — NEVER hand-roll
# podman run: this carries the runtime --health-cmd (OCI images drop the
# Containerfile HEALTHCHECK), the tun/fuse devices, --shm-size, the restart
# policy, the runtime secrets, and — critically — the PORT PUBLISH SET.
#
#   RDP_PW='…'  (required) core's RDP/system password. xrdp authenticates via PAM;
#               the guacamole gateway single-signs-on into the LOCAL RDP with it.
#   GUAC_PW='…' (guacamole gateway) the Guacamole web-login password (user 'core')
#               at https://<host>:8443/guacamole/.
#   RFB_PW='…'  (novnc gateway: REQUIRED — the noVNC web-door password at
#               https://<host>:8443/vnc.html; guacamole gateway: optional — arms the
#               :5900 tailnet VNC mirror). VncAuth — only the first 8 chars count.
#   TS_AUTHKEY  (optional) unattended tailnet join.
#   IMAGE       (optional) defaults to the local build.
#
#   RDP_PW='…' GUAC_PW='…' [RFB_PW='…'] [TS_AUTHKEY=tskey-…] [IMAGE=…] ./run.sh
#
# ACCESS MODEL (load-bearing — do NOT widen the publish set):
#   PUBLIC internet doors (the ONLY -p publishes):
#     * 8443/tcp  -> the web gateway over TLS  (Guacamole or noVNC — the hardened browser door)
#     * 4444/tcp  -> container :22 sshd       (key-only; keys synced from
#                    github.com/oso-gato.keys at every start)
#     * 61001-62000/udp -> mosh               (roams over the same key-auth ssh)
#   TAILNET-ONLY (deliberately NOT published — reachable only over the tailnet IP):
#     * 3389/tcp  RDP   (native clients: Windows App on iOS/Android, mstsc)
#     * 5900/tcp  VNC   (the optional RFB_PW same-session mirror)
#   Password-auth (RDP/VNC/Guacamole login) therefore never crosses the public
#   internet except inside the TLS-terminated Guacamole door. Tailscale SSH
#   (keyless) on the tailnet IP is the primary maintenance path.
#
# Session survives disconnects (KillDisconnected=false) — reconnect over RDP/web
# and your apps are still open.
set -eu

# WEB_GATEWAY must match the image you built (baked in /etc/fedora-desktop/web-gateway):
#   guacamole (default) → needs GUAC_PW (the Guacamole web-login password).
#   novnc               → needs RFB_PW (the noVNC web-door password = the VNC VncAuth).
WEB_GATEWAY="${WEB_GATEWAY:-guacamole}"
: "${RDP_PW:?set RDP_PW (RDP/system password for core)}"
case "$WEB_GATEWAY" in
  guacamole) : "${GUAC_PW:?set GUAC_PW (Guacamole web login) — or WEB_GATEWAY=novnc + RFB_PW}"
             HEALTH_URL='https://127.0.0.1:8443/guacamole/'; BACKEND_PORT=3389 ;;
  novnc)     : "${RFB_PW:?set RFB_PW (noVNC/VNC web-door password) for the novnc gateway}"
             HEALTH_URL='https://127.0.0.1:8443/vnc.html';   BACKEND_PORT=5900 ;;
  *) echo "WEB_GATEWAY must be guacamole|novnc" >&2; exit 1 ;;
esac
IMAGE="${IMAGE:-localhost/fedora-desktop:latest}"
TS_AUTHKEY="${TS_AUTHKEY:-}"; GUAC_PW="${GUAC_PW:-}"; RFB_PW="${RFB_PW:-}"

# Secrets reach the entrypoint via a bind-mounted, 0600 secrets.env — NOT `podman
# -e`, which would persist RDP_PW/GUAC_PW in `podman inspect` + /proc/1/environ for
# the container's whole life. The entrypoint SOURCES this into shell vars (never
# exported, so never in PID 1's environ) and unsets them after use — parity with
# the grd/krdp lineages, which already moved off `-e`.
SECRETS="$(mktemp)"; chmod 600 "$SECRETS"
{ printf 'RDP_PW=%s\n' "$RDP_PW"
  [ -n "$GUAC_PW" ]    && printf 'GUAC_PW=%s\n' "$GUAC_PW"
  [ -n "$RFB_PW" ]     && printf 'RFB_PW=%s\n'  "$RFB_PW"
  [ -n "$TS_AUTHKEY" ] && printf 'TS_AUTHKEY=%s\n' "$TS_AUTHKEY"; } > "$SECRETS"

podman run -d --name fedora-desktop \
    --hostname fedora-desktop \
    --restart=always \
    --shm-size=1g \
    --cap-add NET_ADMIN \
    --cap-add SYS_ADMIN \
    --device /dev/net/tun \
    --device /dev/fuse \
    --security-opt label=disable \
    -v "$SECRETS":/etc/fedora-desktop/secrets.env:ro \
    -v fedora-desktop-home:/home/core \
    -v fedora-desktop-state:/var/lib/tailscale \
    -v fedora-desktop-cert:/var/lib/guac-cert \
    -p 8443:8443 \
    -p 4444:22 \
    -p 61001-62000:61001-62000/udp \
    --health-cmd "bash -c '[ \$(curl -sk -o /dev/null -w %{http_code} ${HEALTH_URL}) = 200 ] && exec 3<>/dev/tcp/127.0.0.1/${BACKEND_PORT}'" \
    --health-interval 30s --health-timeout 5s --health-retries 3 --health-start-period 60s \
    "$IMAGE"
rm -f "$SECRETS"   # host copy gone; the bind-mount keeps it readable to PID 1 only (0700 dir)

echo "Started fedora-desktop."
echo "If no TS_AUTHKEY was given: podman logs -f fedora-desktop and open the"
echo "ACTION REQUIRED login.tailscale.com link (one-time per state volume)."
echo
echo "Reach it:"
if [ "$WEB_GATEWAY" = "guacamole" ]; then
  echo "  web   https://<public-ip-or-tailnet-ip>:8443/guacamole/   (login: core / GUAC_PW)"
else
  echo "  web   https://<public-ip-or-tailnet-ip>:8443/vnc.html      (noVNC — password: RFB_PW)"
fi
echo "  ssh   ssh -p 4444 core@<public-ip>          (key auth — github.com/oso-gato.keys)"
echo "  ssh   ssh core@<tailnet-ip>                 (Tailscale SSH, keyless)"
echo "  mosh  mosh -p 61001:62000 --ssh='ssh -p 4444' core@<public-ip>"
echo "  RDP   <tailnet-ip>:3389   (TAILNET-ONLY — mstsc / Windows App; login core / RDP_PW)"
echo "  VNC   <tailnet-ip>:5900   (TAILNET-ONLY — only if RFB_PW was set; mirrors the RDP session)"
echo "Desktop terminal -> 'claude' to reach the in-box agent. All ssh/mosh land in tmux 'main'."
