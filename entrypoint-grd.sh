#!/usr/bin/env bash
# fedora-desktop — GRD lineage first-boot config (systemd oneshot, runs ONCE).
# ============================================================================
# Variant-1 "GNOME-50 turnkey" headless build — HOST-VALIDATED via
# validation/grd-headless-spike.sh (single-user AND multi-user, on erebus 2026-06-24):
#   per Linux user, gdm spawns a headless AUTOLOGIN session via
#   gnome-headless-session@<user> (GDM CreateUserDisplay, NO greeter) → a real
#   class=user logind session (portals + keyring work); the user's
#   gnome-remote-desktop-headless.service serves NLA RDP on a DISTINCT loopback port;
#   a SINGLE credential SSOs straight to that user's painted desktop; Apache Guacamole
#   fronts each user's loopback port as the public :8443 door.
#
# Secrets reach this oneshot via the unit EnvironmentFile (run.sh.grd writes
# /etc/fedora-desktop/secrets.env). PRINCIPLE 5 — runtime only, never a layer.
#   RDP_PW   — ALWAYS: core's system + GRD RDP credential (Guacamole SSOs core with it)
#   GUAC_PW  — ALWAYS: core's PUBLIC Guacamole web-login password (+TOTP, +auth-ban)
#   USER{1..5}_NAME/_PW/_ACCESS — OPTIONAL additional desktop users (multi-user)
#   RFB_PW   — IGNORED (mode v1 native VNC mirror is a follow-up; --headless can expose it)
set -eu
: "${RDP_PW:?RDP_PW must be set (core system + GRD RDP password) — see run.sh.grd}"
: "${GUAC_PW:?GUAC_PW must be set (the public Guacamole web-login password) — see run.sh.grd}"
[ -n "${RFB_PW:-}" ] && echo "[grd] RFB_PW set but native VNC is a v1 follow-up — ignoring" >&2 || true

CERTDIR=/var/lib/guac-cert
RDP_BASE_PORT=3389            # core=:3389, USER1=:3390, … (loopback; Guacamole fronts each)

# ---- core + optional additional desktop users (multi-user) ------------------
# core (uid 1000) is the admin. USER{1..5} are non-privileged desktop users created
# idempotently from spin-up secrets (NOT in wheel, no subuid → no podman/claudebox).
echo "core:${RDP_PW}" | chpasswd
# Parallel arrays. uid + port are keyed on the USERn NUMBER (1000+n / base+n), NOT the
# array index, so they MATCH guac-db-provision's per-user port even with gaps (e.g.
# USER1 + USER3 set, no USER2). core is index 0: uid 1000, port RDP_BASE_PORT.
USERNAMES=(core); USERPWS=("$RDP_PW"); USERUIDS=(1000); USERPORTS=("$RDP_BASE_PORT")
for _n in 1 2 3 4 5; do
    eval "_un=\${USER${_n}_NAME:-}; _up=\${USER${_n}_PW:-}"
    [ -n "$_un" ] && [ -n "$_up" ] || continue
    case "$_un" in core|root|gdm|gnome-remote-desktop|tomcat|mysql) echo "[grd] refusing reserved username '$_un'" >&2; continue;; esac
    echo "$_un" | grep -qE '^[a-z_][a-z0-9_-]{0,30}$' || { echo "[grd] invalid username '$_un' — skipped" >&2; continue; }
    if ! id "$_un" >/dev/null 2>&1; then
        # Pin GID == UID == 1000+n (per-user private group) so the PERSISTED /home/<user> volume's
        # ownership is deterministic across recreations — parity with the xrdp lineage.
        groupadd -g "$((1000 + _n))" "$_un" 2>/dev/null || true
        useradd -m -u "$((1000 + _n))" -g "$((1000 + _n))" -s /bin/bash "$_un"
        # Own the BOUND per-user /home volume: a fresh named volume's mount root is root-owned and
        # useradd -m won't chown a pre-existing mountpoint, so without this the user can't write ~.
        # The xrdp lineage already does this (entrypoint.sh); grd was MISSING it. Home stays 0700.
        chown -R "$_un:$_un" "/home/$_un" 2>/dev/null || true
    fi
    echo "${_un}:${_up}" | chpasswd
    chmod 700 "/home/$_un" 2>/dev/null || true   # 0700 per-user isolation (idempotent, parity with xrdp)
    loginctl enable-linger "$_un" >/dev/null 2>&1 || true
    USERNAMES+=("$_un"); USERPWS+=("$_up"); USERUIDS+=("$((1000 + _n))"); USERPORTS+=("$((RDP_BASE_PORT + _n))")
done
loginctl enable-linger core >/dev/null 2>&1 || true

# ---- optional SHARED collaboration folder (ENABLE_SHARED) — parity with xrdp ----
# A single 2770 root:deskshare volume at /home/shared every desktop user can read/write, with a
# DEFAULT POSIX ACL forcing group rwx on new files (umask-independent full read-write collab;
# host-validated, validation/user-volumes-spike.sh). Homes stay 0700: deskshare is SUPPLEMENTARY
# only, never a primary/home group. Volume bound by run.sh.grd only when ENABLE_SHARED is set.
if [ -n "${ENABLE_SHARED:-}" ]; then
    groupadd -g 6000 deskshare 2>/dev/null || true
    install -d -m 2770 -o root -g deskshare /home/shared
    chown root:deskshare /home/shared; chmod 2770 /home/shared
    setfacl -d -m group:deskshare:rwx /home/shared 2>/dev/null || true
    setfacl    -m group:deskshare:rwx /home/shared 2>/dev/null || true
    for _m in "${USERNAMES[@]}"; do usermod -aG deskshare "$_m" 2>/dev/null || true; done
    echo "[shared] /home/shared enabled (group deskshare; members: ${USERNAMES[*]})"
fi

# ---- key-only ssh: sync core's authorized_keys from github.com/oso-gato.keys -
runuser -u core -- bash -c '
    mkdir -p ~/.ssh && chmod 700 ~/.ssh
    t=$(mktemp)
    if curl -fsSL --max-time 10 https://github.com/oso-gato.keys -o "$t" && [ -s "$t" ]; then
        mv "$t" ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
    else rm -f "$t"; fi'

# ---- tailnet join: Tailscale SSH + the fleet-tile uplink ---------------------
# tailscaled runs as tailscaled.service (install-grd). Bring the node UP so (a) ssh/RDP
# are reachable over the tailnet and (b) guacd can reach the FLEET_SSH bastion tiles on the
# dev box + host over THIS node's tailnet. Unattended via TS_AUTHKEY (synchronous, bounded —
# never loop forever on a bad key); without a key, kick off the interactive login in the
# BACKGROUND so this oneshot (and Tomcat, which Requires= it) does not block on a browser.
for _i in $(seq 1 30); do
    tailscale status >/dev/null 2>&1 && break
    [ -S /var/run/tailscale/tailscaled.sock ] && break
    sleep 1
done
if [ -n "${TS_AUTHKEY:-}" ]; then
    tailscale up --ssh --auth-key="${TS_AUTHKEY}" --hostname=fedora-desktop-grd \
        || echo "[tailscale] up failed (bad/expired TS_AUTHKEY?) — fleet tiles + tailnet RDP stay unreachable until 'tailscale up' succeeds" >&2
else
    ( tailscale up --ssh --hostname=fedora-desktop-grd 2>&1 | sed 's/^/[tailscale] /' ) &
    echo "[tailscale] no TS_AUTHKEY — open the login.tailscale.com URL in the journal to join (one-time per state volume)" >&2
fi

# ---- tailnet-only by CONSTRUCTION (defense-in-depth; parity with the xrdp lineage) --
# The web gateway (:8443) is the ONLY public door. ssh (:22), mosh, and EVERY GRD RDP
# port (:3389-:3394, one per user) are TAILNET-ONLY: run.sh.grd publishes only the web
# port, and this nft rule drops those ports on every interface except lo + tailscale0.
nft -f - <<'NFT' 2>/dev/null || echo "[net-guard] tailnet-guard skipped (no NET_ADMIN / nft?)"
table inet fd_tailnet_guard {
  chain input {
    type filter hook input priority -10; policy accept;
    iifname "lo" accept
    iifname "tailscale0" accept
    tcp dport { 22, 3389-3394, 5900 } drop
    udp dport 61001-62000 drop
  }
}
NFT

# ---- Tomcat TLS keystore for the public :8443 web door ----------------------
install -d -m 0751 "$CERTDIR"
if [ ! -f "$CERTDIR/keystore.p12" ]; then
    keytool -genkeypair -alias guac -keyalg RSA -keysize 2048 -validity 3650 \
        -dname "CN=fedora-desktop-grd" -storetype PKCS12 \
        -keystore "$CERTDIR/keystore.p12" -storepass container-local
    chown tomcat:tomcat "$CERTDIR/keystore.p12"; chmod 640 "$CERTDIR/keystore.p12"
fi

# ---- Guacamole web door: DB-backed auth (MariaDB) + TOTP 2FA -----------------
# Shared single-source helper (byte-identical four must-dos with the xrdp lineage).
# grd specifics: RDP_SECURITY=any — GRD's RDP front door is NLA-authenticated (NOT the
# Guacamole 'tls'/RDSTLS mode), so the connection must NEGOTIATE (host-validated in the
# spike with /sec:nla). RDP_PIN_BPP=0 (Wayland; no xrdp <User,BitPerPixel> key).
# RDP_PORT_PER_USER=1 — each user's tile dials its OWN loopback port (core 3389, USERn 3389+n).
rm -f /etc/guacamole/user-mapping.xml   # must-do #2: a file-auth map would bypass TOTP
if [ "${ENABLE_AUDIO:-false}" = "true" ]; then RDP_DISABLE_AUDIO=0; else RDP_DISABLE_AUDIO=1; fi
MCLIENT="$(command -v mariadb || command -v mysql)"
MADMIN="$(command -v mariadb-admin || command -v mysqladmin)"
DBSOCK=/var/lib/mysql/mysql.sock
MYSQL_ROOT() { "$MCLIENT" --socket="$DBSOCK" "$@"; }
_db_ready=0
for _i in $(seq 1 60); do
    if "$MADMIN" --socket="$DBSOCK" ping >/dev/null 2>&1; then _db_ready=1; break; fi
    sleep 1
done
[ "$_db_ready" = 1 ] || { echo "FATAL: MariaDB (mariadb.service) not ready for provisioning" >&2; exit 1; }
RDP_SECURITY=any
RDP_PIN_BPP=0
RDP_PORT_PER_USER=1
. /usr/local/share/fedora-dev/bin/guac-db-provision.sh
guac_db_provision
unset GUAC_PW

# ---- per-user GRD headless sessions (variant 1, exactly the spike-proven steps) --
# For each user: GDM spawns the headless autologin session, GRD --headless serves it on
# the user's OWN loopback port (negotiation OFF so the port is deterministic), and the
# single RDP credential is that user's RDP_PW/USERn_PW. Per-command guards: one failing
# step names itself and does NOT abort the oneshot (which would block Tomcat → :8443).
setup_grd_user() {   # <user> <uid> <port> <rdp_pw>
    local u="$1" uid="$2" port="$3" pw="$4" cert="/home/$1/.grd-cert"
    install -d -m 0700 -o "$u" -g "$u" "$cert"
    if [ ! -f "$cert/cert.pem" ]; then
        runuser -u "$u" -- openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
            -subj "/CN=fedora-desktop-grd-$u" -keyout "$cert/key.pem" -out "$cert/cert.pem" 2>/dev/null \
            && chmod 600 "$cert/key.pem" || echo "[grd] $u: TLS mint FAILED" >&2
    fi
    systemctl enable --now "gnome-headless-session@${u}.service" 2>/dev/null \
        || echo "[grd] $u: gnome-headless-session@ failed to start (see journalctl)" >&2
    # configure + start GRD inside the user's own session bus. Values pass via ENV into a
    # SINGLE-quoted body (no outer-shell interpolation) so passwords with shell metachars
    # (quotes, $, spaces) are safe. Per-command guards keep one failure from aborting.
    runuser -u "$u" -- env XDG_RUNTIME_DIR="/run/user/$uid" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
        GU="$u" GP="$pw" GPORT="$port" GCERT="$cert" bash -c '
        grdctl --headless rdp set-tls-cert "$GCERT/cert.pem" || echo "[grd] $GU rdp set-tls-cert FAILED"
        grdctl --headless rdp set-tls-key  "$GCERT/key.pem"  || echo "[grd] $GU rdp set-tls-key FAILED"
        grdctl --headless rdp set-credentials "$GU" "$GP"    || echo "[grd] $GU rdp set-credentials FAILED"
        grdctl --headless rdp set-port "$GPORT" 2>/dev/null \
            || gsettings set org.gnome.desktop.remote-desktop.rdp port "$GPORT" 2>/dev/null || true
        grdctl --headless rdp disable-port-negotiation 2>/dev/null \
            || gsettings set org.gnome.desktop.remote-desktop.rdp negotiate-port false 2>/dev/null || true
        grdctl --headless rdp enable || echo "[grd] $GU rdp enable FAILED"
        systemctl --user restart gnome-remote-desktop-headless.service 2>/dev/null \
            || systemctl --user start gnome-remote-desktop-headless.service || echo "[grd] $GU headless.service FAILED"
        grdctl --headless status || true' \
        || echo "[grd] $u: grdctl --headless setup reported a failure (see [grd] lines above)"
}

for _i in "${!USERNAMES[@]}"; do
    setup_grd_user "${USERNAMES[$_i]}" "${USERUIDS[$_i]}" "${USERPORTS[$_i]}" "${USERPWS[$_i]}"
done

echo "fedora-desktop-grd configured: GRD SYSTEM-FREE headless (variant 1) for users: ${USERNAMES[*]}"
echo "Each user = a gdm-spawned headless autologin GNOME session served by"
echo "gnome-remote-desktop-headless on its own loopback RDP port (core :3389, USERn :338n+)."
echo "Apache Guacamole fronts each port as the single public :8443 web door (GUAC_PW + TOTP)."
