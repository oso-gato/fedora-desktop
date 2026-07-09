#!/usr/bin/env bash
# Deploy fedora-desktop (rootless podman). The deploy contract — NEVER hand-roll
# podman run: this carries the runtime --health-cmd (OCI images drop the
# Containerfile HEALTHCHECK), the tun/fuse devices, --shm-size, the restart
# policy, the runtime secrets, and — critically — the PORT PUBLISH SET.
#
# SECRETS (per door — supplied at spin-up; the host claudebox MUST ASK the operator
# for these, never hardcode them — see "DEPLOY CONTRACT" in README.md):
#   RDP_PW='…'  (REQUIRED) core's system/RDP password — the RDP door (TAILNET-ONLY)
#               AND the loopback RDP the Guacamole web door SSO's into. Use a STRONG
#               password (it is core's login).
#   GUAC_PW='…' (REQUIRED) the PUBLIC Guacamole web-login password. This is the only
#               auth on the only public door → use a STRONG password (the baked
#               guacamole-auth-ban extension adds brute-force lockout on top).
#   RFB_PW='…'  (OPTIONAL) arms the :5900 TAILNET-ONLY VNC mirror for native VNC
#               viewers. VncAuth is weak (8 chars) — fine, since :5900 is tailnet-only.
#   WEB_PORT    (optional) host port for the public web door. DEFAULT 8443.
#   FLEET_SSH   (optional) clientless browser-SSH bastion tiles to OTHER fleet hosts,
#               shown on the SAME public web door — VPN-slot-free fleet access from any
#               device incl. iOS on another VPN (see ZTNA-ACCESS.md). ';'-separated
#               "label host [port] [user]", e.g.
#               FLEET_SSH='dev fedora-dev 22 core;vps erebus 22 core'.
#               Each 'host' is the target's TAILNET node name — the bootstrap host's is
#               BOOTSTRAP_HOSTNAME (default 'erebus'), NOT the repo name 'fedora-bootstrap'
#               (a non-tailnet name resolves to loopback → the tile hits the desktop's OWN
#               key-only sshd → a dead password prompt). Use the 100.x tailnet IP if unsure.
#               Reached over the desktop's SERVER-SIDE tailnet via KEYLESS
#               Tailscale-SSH — the tailnet `ssh` ACL must grant THIS node action
#               `accept` (NOT `check`) to the targets, else the tile hangs on an
#               un-answerable browser re-auth (see ZTNA-ACCESS.md). No key needed.
#   USER{1..5}_NAME / _PW / _ACCESS (optional) — up to FIVE additional desktop users
#               beyond core (core stays the admin). Each gets their OWN Guacamole web
#               login (USERn_NAME / USERn_PW), their OWN desktop session, and their OWN
#               persisted /home volume (fedora-desktop-userN). USERn_ACCESS picks which
#               fleet tiles their login shows: none | all | a comma-list of tile hostnames
#               (e.g. 'fedora-dev,onyx'). Tile label == tailnet hostname; core always gets all.
#               Username: lowercase ^[a-z_][a-z0-9_-]{0,30}$, not core/root.
#               Tip: the interactive `spin-up.sh` wizard ASKS all of this (count 0-5, then
#               per-user name / password / access) and calls this script for you.
#   TS_AUTHKEY  (optional) unattended tailnet join.   IMAGE (optional) local build.
#
#   RDP_PW='…' GUAC_PW='…' [WEB_PORT=8443] [RFB_PW='…'] [FLEET_SSH='…'] \
#     [USER1_NAME=jenny USER1_PW='…' USER1_ACCESS=none] [USER2_NAME=bob USER2_PW='…' USER2_ACCESS=all] \
#     [… up to USER5 …] [TS_AUTHKEY=…] ./run.sh        # or just: ./spin-up.sh  (interactive)
#
# ACCESS MODEL (load-bearing — do NOT widen the publish set):
#   PUBLIC internet door — the ONLY -p publish:
#     * ${WEB_PORT}->8443/tcp  the Apache Guacamole web gateway over TLS. Changeable
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

# The web gateway is Apache Guacamole (the only one). Required: RDP_PW + GUAC_PW
# (the public web login — use a STRONG password; brute-force lockout is enforced by
# the baked guacamole-auth-ban extension). RFB_PW is OPTIONAL: it arms the
# tailnet-only :5900 VNC mirror for native VNC viewers.
: "${RDP_PW:?set RDP_PW (RDP/system password for core)}"
: "${GUAC_PW:?set GUAC_PW (the PUBLIC Guacamole web-login password — use a strong one)}"
HEALTH_URL='https://127.0.0.1:8443/guacamole/'; BACKEND_PORT=3389
IMAGE="${IMAGE:-localhost/fedora-desktop:latest}"
TS_AUTHKEY="${TS_AUTHKEY:-}"; RFB_PW="${RFB_PW:-}"; FLEET_SSH="${FLEET_SSH:-}"
# FLEET_SSH_KEY (optional) — only for a target whose REAL sshd is reachable on :22
# (Tailscale SSH off / a non-tailnet bastion). It does NOT help Tailscale-SSH-fronted
# targets — Tailscale SSH intercepts :22 and ignores the key; those use keyless
# Tailscale-SSH (ACL `accept`, see above). A private key file, bind-mounted READ-ONLY,
# NEVER baked (Principle 5). Empty array expands to nothing when unset.
FLEET_SSH_KEY="${FLEET_SSH_KEY:-}"; KEY_MOUNT=()
[ -n "$FLEET_SSH_KEY" ] && KEY_MOUNT=(-v "$FLEET_SSH_KEY":/etc/fedora-desktop/fleet_ssh_key:ro)
# Multi-user (optional): up to 5 additional desktop users. Each gets its OWN persisted
# /home volume (fedora-desktop-userN) bound at its home path, so the user's vault /
# app-state / running SESSION survive container recreation (without this their home would
# live on the ephemeral layer and be lost). Keep the same username per slot across
# restarts. core's own home volume (below) is unchanged — no migration.
USER_VOLS=()
for _i in 1 2 3 4 5; do
  eval "_un=\${USER${_i}_NAME:-}"
  [ -n "$_un" ] && USER_VOLS+=(-v "fedora-desktop-user${_i}:/home/${_un}")
done
# Optional SHARED collaboration folder (ENABLE_SHARED): a single persisted volume bound at
# /home/shared that the entrypoint group-owns (2770 root:deskshare) + ACLs for read-write
# collab across all desktop users. Bound ONLY when enabled; homes stay 0700 (see entrypoint).
ENABLE_SHARED="${ENABLE_SHARED:-}"; SHARED_VOL=()
[ -n "$ENABLE_SHARED" ] && SHARED_VOL=(-v fedora-desktop-shared:/home/shared)
# WEB_PORT — the web gateway is the ONLY public door; its host port is changeable
# at spin-up (DEFAULT 8443). Everything else — ssh, mosh, RDP, VNC — is TAILNET-ONLY
# (never published; reached over the tailnet IP / Tailscale SSH).
WEB_PORT="${WEB_PORT:-8443}"

# Secrets reach the entrypoint via a podman SECRET mounted at /etc/fedora-desktop/
# secrets.env — NOT `podman -e` (which would persist RDP_PW/GUAC_PW in `podman
# inspect` + /proc/1/environ for the container's whole life), and NOT a bind-mounted
# tempfile: deleting the mktemp source after `podman run` DEFEATED --restart=always
# (podman re-resolves bind sources on every start, so the first crash/restart/reboot
# died on the missing /tmp path — the heal loop could never heal; proven in-box).
# The secret lives in the rootless secret store (survives restarts + host reboots);
# `podman inspect` shows its name/ID only, never the values. The entrypoint SOURCES
# the mounted file into shell vars (never exported, so never in PID 1's environ)
# and unsets them after use. A container keeps its create-time copy across
# replaces; to redeploy with NEW values run `podman rm -f fedora-desktop` first,
# then re-run this script (a bare re-run replaces the stored secret but then
# stops at `podman run` — the container name is already in use).
SECRET_NAME=fedora-desktop-secrets
{ printf 'RDP_PW=%q\n' "$RDP_PW"
  [ -n "$GUAC_PW" ]    && printf 'GUAC_PW=%q\n' "$GUAC_PW"
  [ -n "$RFB_PW" ]     && printf 'RFB_PW=%q\n'  "$RFB_PW"
  [ -n "$TS_AUTHKEY" ] && printf 'TS_AUTHKEY=%q\n' "$TS_AUTHKEY"
  [ -n "$FLEET_SSH" ]  && printf 'FLEET_SSH=%q\n'  "$FLEET_SSH"
  [ -n "$ENABLE_SHARED" ] && printf 'ENABLE_SHARED=%q\n' "$ENABLE_SHARED"
  for _i in 1 2 3 4 5; do
    eval "_un=\${USER${_i}_NAME:-}; _up=\${USER${_i}_PW:-}; _ua=\${USER${_i}_ACCESS:-none}"
    [ -n "$_un" ] && [ -n "$_up" ] && printf 'USER%s_NAME=%q\nUSER%s_PW=%q\nUSER%s_ACCESS=%q\n' "$_i" "$_un" "$_i" "$_up" "$_i" "$_ua"
  done; } | podman secret create --replace "$SECRET_NAME" - >/dev/null

podman run -d --name fedora-desktop \
    --hostname fedora-desktop \
    --pull=newer \
    --restart=always \
    --shm-size=1g \
    --cap-add NET_ADMIN \
    --cap-add SYS_ADMIN \
    --device /dev/net/tun \
    --device /dev/fuse \
    --security-opt label=disable \
    --secret source=${SECRET_NAME},type=mount,target=/etc/fedora-desktop/secrets.env,mode=0400 \
    "${KEY_MOUNT[@]}" \
    "${USER_VOLS[@]}" \
    "${SHARED_VOL[@]}" \
    -v fedora-desktop-home:/home/core \
    -v fedora-desktop-state:/var/lib/tailscale \
    -v fedora-desktop-cert:/var/lib/guac-cert \
    -v fedora-desktop-db:/var/lib/mysql \
    -p ${WEB_PORT}:8443 \
    --health-cmd "bash -c '[ \$(curl -sk -o /dev/null -w %{http_code} ${HEALTH_URL}) = 200 ] && exec 3<>/dev/tcp/127.0.0.1/${BACKEND_PORT} && mariadb-admin --socket=/var/lib/mysql/mysql.sock ping'" \
    --health-interval 30s --health-timeout 5s --health-retries 3 --health-start-period 60s \
    "$IMAGE"

# ---- operator-facing access info (OUTPUT ONLY — no security flag / publish-set / device change) ----
# Public IP for the web URL: prefer THIS host's own routable source IP; only ask the publisher's
# echo service (api.ipify.org) when that source is private/NAT — so a public-IP host makes NO
# external call. Tailnet IP (ssh/RDP/VNC doors) is read from the container once tailscaled is up.
PUBIP="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' || true)"
case "$PUBIP" in
  ''|10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|169.254.*|127.*)
    _pub="$(curl -fsS --max-time 4 https://api.ipify.org 2>/dev/null || true)"; [ -n "$_pub" ] && PUBIP="$_pub" ;;
esac
[ -n "$PUBIP" ] || PUBIP='<public-ip>'
TSIP='<tailnet-ip>'
if [ -n "${TS_AUTHKEY:-}" ]; then          # key given -> node joins fast; read its tailnet IP
  for _ in $(seq 1 12); do
    _t="$(podman exec fedora-desktop tailscale ip -4 2>/dev/null | head -n1 || true)"
    [ -n "$_t" ] && { TSIP="$_t"; break; }; sleep 1
  done
fi

echo "Started fedora-desktop."
if [ -z "${TS_AUTHKEY:-}" ]; then          # token-less -> surface the one-time login URL from the log
  echo "No TS_AUTHKEY given — fetching the one-time Tailscale login URL (this node must join before any SSH fleet tile works)…"
  TSURL=""
  for _ in $(seq 1 30); do
    TSURL="$(podman logs fedora-desktop 2>&1 | grep -om1 'https://login\.tailscale\.com/[A-Za-z0-9/_-]*' || true)"
    [ -n "$TSURL" ] && break; sleep 1
  done
  [ -n "$TSURL" ] && echo "  >>> JOIN THIS NODE TO YOUR TAILNET — open:  $TSURL" \
                  || echo "  (URL not captured yet — run: podman logs -f fedora-desktop | grep login.tailscale.com)"
fi
echo
echo "Reach it:"
echo "  web  https://${PUBIP}:${WEB_PORT}/guacamole/   (PUBLIC, the only public door; login core / GUAC_PW)"
[ -n "$FLEET_SSH" ] && echo "       + clientless fleet SSH tiles on the SAME door: $(printf '%s' "$FLEET_SSH" | tr ';' ',')   (no VPN needed)"
for _i in 1 2 3 4 5; do
  eval "_un=\${USER${_i}_NAME:-}; _ua=\${USER${_i}_ACCESS:-none}"
  [ -n "$_un" ] && echo "       + user '$_un' — own web login + desktop; fleet access: $_ua"
done
echo "  ssh  ssh core@${TSIP}                 (Tailscale SSH, keyless — TAILNET-ONLY, no public ssh)"
echo "  mosh mosh --ssh='ssh' core@${TSIP}    (over the tailnet — TAILNET-ONLY)"
echo "  RDP  ${TSIP}:3389   (TAILNET-ONLY — mstsc / Windows App; login core / RDP_PW)"
echo "  VNC  ${TSIP}:5900   (TAILNET-ONLY — only if RFB_PW was set; mirrors the RDP session)"
echo "Desktop terminal -> 'claude' to reach the in-box agent. All ssh/mosh land in tmux 'main'."
[ "$TSIP" = '<tailnet-ip>' ] && echo "  (the tailnet IP appears once this node joins — via the login URL above, then: podman exec fedora-desktop tailscale ip -4)" || true
