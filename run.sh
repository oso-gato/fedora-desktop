#!/usr/bin/env bash
# Deploy fedora-desktop (rootless podman). The deploy contract — NEVER hand-roll
# podman run: this carries the runtime --health-cmd (OCI images drop the
# Containerfile HEALTHCHECK), the tun/fuse devices, --shm-size, the restart
# policy, the runtime secrets, and — critically — the PORT PUBLISH SET.
#
# SECRETS (per door — supplied at spin-up; the host claudebox MUST ASK the operator
# for these, never hardcode them — see "DEPLOY CONTRACT" in README.md):
#   RDP_PW='…'  (REQUIRED) core's system/RDP password — the RDP door (TAILNET-ONLY)
#               AND, for the guacamole gateway, the loopback RDP the web door SSO's
#               into. Use a STRONG password (it is core's login).
#   GUAC_PW='…' (guacamole gateway — REQUIRED) the PUBLIC web-login password. This
#               is the only auth on the only public door → use a STRONG password.
#   RFB_PW='…'  (novnc gateway → REQUIRED, it IS the public web-door auth; guacamole
#               gateway → OPTIONAL, arms the :5900 TAILNET VNC mirror). VNC VncAuth
#               is WEAK (only the first 8 chars count) — fine for the TAILNET-only
#               VNC, but for a PUBLIC door prefer guacamole (GUAC_PW) over novnc.
#   WEB_PORT    (optional) host port for the public web door. DEFAULT 8443.
#   TS_AUTHKEY  (optional) unattended tailnet join.   IMAGE (optional) local build.
#
#   WEB_GATEWAY=guacamole RDP_PW='…' GUAC_PW='…' [WEB_PORT=8443] [RFB_PW='…'] [TS_AUTHKEY=…] ./run.sh
#   WEB_GATEWAY=novnc     RDP_PW='…' RFB_PW='…'  [WEB_PORT=8443] [TS_AUTHKEY=…] ./run.sh
#
# ACCESS MODEL (load-bearing — do NOT widen the publish set):
#   PUBLIC internet door — the ONLY -p publish:
#     * ${WEB_PORT}->8443/tcp  the web gateway over TLS (Guacamole/noVNC). Changeable
#                  at spin-up via WEB_PORT (default 8443). This is the sole public surface.
#   TAILNET-ONLY (NEVER published; reachable only over the tailnet IP, and dropped on
#   non-tailscale0/non-loopback by an in-container nft guard — true by construction):
#     * 22/tcp    ssh   — Tailscale SSH (keyless, tailnet identity) or ssh-key over the tailnet
#     * mosh (udp)      — over the tailnet ssh
#     * 3389/tcp  RDP   — native clients (mstsc / Windows App), login core / RDP_PW
#     * 5900/tcp  VNC   — the optional RFB_PW same-session mirror
#   So the ONLY thing exposed to the public internet is the TLS web gateway; ssh/mosh/
#   RDP/VNC are tailnet-only. Tailscale SSH on the tailnet IP is the primary maintenance path.
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
# WEB_PORT — the web gateway is the ONLY public door; its host port is changeable
# at spin-up (DEFAULT 8443). Everything else — ssh, mosh, RDP, VNC — is TAILNET-ONLY
# (never published; reached over the tailnet IP / Tailscale SSH).
WEB_PORT="${WEB_PORT:-8443}"

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
    -p ${WEB_PORT}:8443 \
    --health-cmd "bash -c '[ \$(curl -sk -o /dev/null -w %{http_code} ${HEALTH_URL}) = 200 ] && exec 3<>/dev/tcp/127.0.0.1/${BACKEND_PORT}'" \
    --health-interval 30s --health-timeout 5s --health-retries 3 --health-start-period 60s \
    "$IMAGE"
rm -f "$SECRETS"   # host copy gone; the bind-mount keeps it readable to PID 1 only (0700 dir)

echo "Started fedora-desktop."
echo "If no TS_AUTHKEY was given: podman logs -f fedora-desktop and open the"
echo "ACTION REQUIRED login.tailscale.com link (one-time per state volume)."
echo
echo "Reach it:"
echo "  web  (PUBLIC, the only public door)"
if [ "$WEB_GATEWAY" = "guacamole" ]; then
  echo "    https://<public-ip>:${WEB_PORT}/guacamole/   (login: core / GUAC_PW — use a STRONG password)"
else
  echo "    https://<public-ip>:${WEB_PORT}/vnc.html      (noVNC — password: RFB_PW; NOTE: VNC VncAuth is"
  echo "    weak/8-char — prefer WEB_GATEWAY=guacamole for a public door)"
fi
echo "  ssh  ssh core@<tailnet-ip>                 (Tailscale SSH, keyless — TAILNET-ONLY, no public ssh)"
echo "  mosh mosh --ssh='ssh' core@<tailnet-ip>    (over the tailnet — TAILNET-ONLY)"
echo "  RDP  <tailnet-ip>:3389   (TAILNET-ONLY — mstsc / Windows App; login core / RDP_PW)"
echo "  VNC  <tailnet-ip>:5900   (TAILNET-ONLY — only if RFB_PW was set; mirrors the RDP session)"
echo "Desktop terminal -> 'claude' to reach the in-box agent. All ssh/mosh land in tmux 'main'."
