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
#               Reached over the desktop's SERVER-SIDE tailnet; prefer keyless
#               Tailscale-SSH, else FLEET_SSH_KEY=/path/to/key (bind-mounted, not baked).
#   USER{1..5}_NAME / _PW / _ACCESS (optional) — up to FIVE additional desktop users
#               beyond core (core stays the admin). Each gets their OWN Guacamole web
#               login (USERn_NAME / USERn_PW), their OWN desktop session, and their OWN
#               persisted /home volume (fedora-desktop-userN). USERn_ACCESS picks which
#               fleet tiles their login shows: none (Desktop only) | dev | host | both.
#               Username: lowercase ^[a-z_][a-z0-9_-]{0,30}$, not core/root.
#               Tip: the interactive `spin-up.sh` wizard ASKS all of this (count 0-5, then
#               per-user name / password / access) and calls this script for you.
#   TS_AUTHKEY  (optional) unattended tailnet join.   IMAGE (optional) local build.
#
#   RDP_PW='…' GUAC_PW='…' [WEB_PORT=8443] [RFB_PW='…'] [FLEET_SSH='…'] \
#     [USER1_NAME=jenny USER1_PW='…' USER1_ACCESS=none] [USER2_NAME=bob USER2_PW='…' USER2_ACCESS=both] \
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
# FLEET_SSH_KEY (optional) — a private key file for the FLEET_SSH browser-SSH tiles
# (else keyless Tailscale-SSH is used). Bind-mounted READ-ONLY; NEVER baked into the
# image (Principle 5). Empty array expands to nothing when unset.
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
# WEB_PORT — the web gateway is the ONLY public door; its host port is changeable
# at spin-up (DEFAULT 8443). Everything else — ssh, mosh, RDP, VNC — is TAILNET-ONLY
# (never published; reached over the tailnet IP / Tailscale SSH).
WEB_PORT="${WEB_PORT:-8443}"

# Secrets reach the entrypoint via a bind-mounted, 0600 secrets.env — NOT `podman
# -e`, which would persist RDP_PW/GUAC_PW in `podman inspect` + /proc/1/environ for
# the container's whole life. The entrypoint SOURCES this into shell vars (never
# exported, so never in PID 1's environ) and unsets them after use — parity with
# the grd lineages, which already moved off `-e`.
SECRETS="$(mktemp)"; chmod 600 "$SECRETS"
{ printf 'RDP_PW=%q\n' "$RDP_PW"
  [ -n "$GUAC_PW" ]    && printf 'GUAC_PW=%q\n' "$GUAC_PW"
  [ -n "$RFB_PW" ]     && printf 'RFB_PW=%q\n'  "$RFB_PW"
  [ -n "$TS_AUTHKEY" ] && printf 'TS_AUTHKEY=%q\n' "$TS_AUTHKEY"
  [ -n "$FLEET_SSH" ]  && printf 'FLEET_SSH=%q\n'  "$FLEET_SSH"
  for _i in 1 2 3 4 5; do
    eval "_un=\${USER${_i}_NAME:-}; _up=\${USER${_i}_PW:-}; _ua=\${USER${_i}_ACCESS:-none}"
    [ -n "$_un" ] && [ -n "$_up" ] && printf 'USER%s_NAME=%q\nUSER%s_PW=%q\nUSER%s_ACCESS=%q\n' "$_i" "$_un" "$_i" "$_up" "$_i" "$_ua"
  done; } > "$SECRETS"

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
    "${KEY_MOUNT[@]}" \
    "${USER_VOLS[@]}" \
    -v fedora-desktop-home:/home/core \
    -v fedora-desktop-state:/var/lib/tailscale \
    -v fedora-desktop-cert:/var/lib/guac-cert \
    -v fedora-desktop-db:/var/lib/mysql \
    -p ${WEB_PORT}:8443 \
    --health-cmd "bash -c '[ \$(curl -sk -o /dev/null -w %{http_code} ${HEALTH_URL}) = 200 ] && exec 3<>/dev/tcp/127.0.0.1/${BACKEND_PORT} && mariadb-admin --socket=/var/lib/mysql/mysql.sock ping'" \
    --health-interval 30s --health-timeout 5s --health-retries 3 --health-start-period 60s \
    "$IMAGE"
rm -f "$SECRETS"   # host copy gone; the bind-mount keeps it readable to PID 1 only (0700 dir)

echo "Started fedora-desktop."
echo "If no TS_AUTHKEY was given: podman logs -f fedora-desktop and open the"
echo "ACTION REQUIRED login.tailscale.com link (one-time per state volume)."
echo
echo "Reach it:"
echo "  web  https://<public-ip>:${WEB_PORT}/guacamole/   (PUBLIC, the only public door; login core / GUAC_PW)"
[ -n "$FLEET_SSH" ] && echo "       + clientless fleet SSH tiles on the SAME door: $(printf '%s' "$FLEET_SSH" | tr ';' ',')   (no VPN needed)"
for _i in 1 2 3 4 5; do
  eval "_un=\${USER${_i}_NAME:-}; _ua=\${USER${_i}_ACCESS:-none}"
  [ -n "$_un" ] && echo "       + user '$_un' — own web login + desktop; fleet access: $_ua"
done
echo "  ssh  ssh core@<tailnet-ip>                 (Tailscale SSH, keyless — TAILNET-ONLY, no public ssh)"
echo "  mosh mosh --ssh='ssh' core@<tailnet-ip>    (over the tailnet — TAILNET-ONLY)"
echo "  RDP  <tailnet-ip>:3389   (TAILNET-ONLY — mstsc / Windows App; login core / RDP_PW)"
echo "  VNC  <tailnet-ip>:5900   (TAILNET-ONLY — only if RFB_PW was set; mirrors the RDP session)"
echo "Desktop terminal -> 'claude' to reach the in-box agent. All ssh/mosh land in tmux 'main'."
