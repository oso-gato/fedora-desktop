#!/usr/bin/env bash
# fedora-desktop — GRD lineage first-boot config (systemd oneshot, runs ONCE).
# ============================================================================
# Seeds core's password, syncs key-only ssh, mints TLS, configures GRD (RDP+VNC)
# + the Apache Guacamole web door (user-mapping -> GRD's loopback RDP), and leaves
# the headless GNOME-Wayland session + the claudebox to core's lingering
# systemd --user manager. HEADLESS — no monitor/GPU/seat required.
#
# Secrets reach this oneshot via the unit's EnvironmentFile (run.sh.grd writes
# /etc/fedora-desktop/secrets.env from the podman -e vars before this runs, OR
# podman passes them into PID 1's env which the unit imports).
#
# Required runtime secrets (PRINCIPLE 5):
#   RDP_PW  — ALWAYS: core's system + GRD RDP password (the Guacamole web door
#             single-signs-on into the loopback RDP with it).
#   GUAC_PW — ALWAYS: the Guacamole web-login password on the PUBLIC :8443 door
#             (use a STRONG password; brute-force lockout via guacamole-auth-ban).
#   RFB_PW  — OPTIONAL: arms the tailnet-only GRD VNC :5900 mirror for native VNC
#             viewers (falls back to RDP_PW when unset).
set -eu
: "${RDP_PW:?RDP_PW must be set (core system + GRD RDP password) — see run.sh.grd}"
: "${GUAC_PW:?GUAC_PW must be set (the public Guacamole web-login password) — see run.sh.grd}"
# GRD VNC (:5900, tailnet-only) is an optional mirror: armed by RFB_PW when set,
# else falls back to the RDP_PW so native VNC viewers still have a usable password.
# GRD/FreeRDP cap the VNC password at 8 chars (MAX_VNC_PASSWORD_SIZE in grd-ctl.c). The
# strong RDP_PW (often a multi-word passphrase) MUST NOT be reused for VNC — that reuse is
# exactly what raised "Password is too long" and aborted the whole grd-setup under set -e.
# The :5900 VNC mirror is OPTIONAL: arm it only when RFB_PW is set AND <=8 chars; otherwise
# leave VNC disabled (the public door is Guacamole-over-RDP regardless; native VNC is a
# tailnet-only extra). RDP's set-credentials has no such length limit.
VNC_PW="${RFB_PW:-}"
GRD_VNC=0
if [ -n "$VNC_PW" ]; then
    if [ "${#VNC_PW}" -le 8 ]; then GRD_VNC=1
    else echo "[grd] RFB_PW is ${#VNC_PW} chars; GRD VNC caps at 8 — :5900 mirror NOT armed (RDP unaffected)" >&2; fi
fi

# ---- core's system/GRD password (runtime only — never in a layer) -----------
echo "core:${RDP_PW}" | chpasswd

# ---- key-only ssh: sync core's authorized_keys from github.com/oso-gato.keys -
runuser -u core -- bash -c '
    mkdir -p ~/.ssh && chmod 700 ~/.ssh
    t=$(mktemp)
    if curl -fsSL --max-time 10 https://github.com/oso-gato.keys -o "$t" && [ -s "$t" ]; then
        mv "$t" ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
    else rm -f "$t"; fi'

# ---- tailnet-only by CONSTRUCTION (defense-in-depth; parity with the xrdp lineage) --
# The web gateway (:8443) is the ONLY public door. ssh (:22), mosh (UDP 61001-62000),
# RDP (:3389) and VNC (:5900) are TAILNET-ONLY: run.sh.grd publishes only the web port,
# and THIS nft rule drops those ports on every interface except lo (loopback: guacd) and
# tailscale0 (the tailnet) — so a future `-p 22`/`-p 3389` slip can't expose GRD's
# RDP/VNC or sshd to the public internet. Own table (never collides with fail2ban's);
# `iifname` matches by name so it loads before tailscale0 exists; best-effort (needs
# NET_ADMIN, granted by run.sh.grd) and `|| echo` keeps it NON-FATAL under `set -e`.
# Byte-identical to the xrdp entrypoint's guard — previously this lineage shipped NONE
# (NET-01 / DOC-05: "tailnet-only by construction" was an xrdp-only backstop).
nft -f - <<'NFT' 2>/dev/null || echo "[net-guard] tailnet-guard skipped (no NET_ADMIN / nft?)"
table inet fd_tailnet_guard {
  chain input {
    type filter hook input priority -10; policy accept;
    iifname "lo" accept
    iifname "tailscale0" accept
    tcp dport { 22, 3389, 5900 } drop
    udp dport 61001-62000 drop
  }
}
NFT

# ---- TLS material on the cert volume ---------------------------------------
# GRD's RDP requires TLS (PEM cert+key — always). The Guacamole web door uses a
# Tomcat PKCS12 keystore. Both persist on /var/lib/guac-cert.
install -d -m 0751 /var/lib/guac-cert   # 0751: core traverses the tomcat-owned dir to read its RDP key
if [ ! -f /var/lib/guac-cert/grd-cert.pem ]; then
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=fedora-desktop-grd" \
        -keyout /var/lib/guac-cert/grd-key.pem -out /var/lib/guac-cert/grd-cert.pem
    chown core:core /var/lib/guac-cert/grd-*.pem; chmod 600 /var/lib/guac-cert/grd-key.pem
fi
if [ ! -f /var/lib/guac-cert/keystore.p12 ]; then
    keytool -genkeypair -alias guac -keyalg RSA -keysize 2048 -validity 3650 \
        -dname "CN=fedora-desktop-grd" -storetype PKCS12 \
        -keystore /var/lib/guac-cert/keystore.p12 -storepass container-local
    chown tomcat:tomcat /var/lib/guac-cert/keystore.p12; chmod 640 /var/lib/guac-cert/keystore.p12
fi
# ---- Guacamole web door: DB-backed auth (MariaDB) + TOTP 2FA -----------------
# TOTP REQUIRES a database; provisioning uses the SHARED single-source helper
# bin/guac-db-provision.sh — the four must-dos live there once, byte-identical to the
# xrdp lineage. grd specifics: the desktop RDP tile uses security=tls (GRD's RDP is
# TLS) and does NOT pin bpp (Wayland; no xrdp <User,BitPerPixel> session-key concern).
# grd is single-user (core) with no FLEET_SSH / extra users -> the helper provisions
# just core (web login GUAC_PW -> GRD's loopback RDP as core/RDP_PW).
rm -f /etc/guacamole/user-mapping.xml   # must-do #2: a file-auth map would bypass TOTP
if [ "${ENABLE_AUDIO:-false}" = "true" ]; then RDP_DISABLE_AUDIO=0; else RDP_DISABLE_AUDIO=1; fi
# MariaDB runs as mariadb.service, ordered before this oneshot (install-grd.sh). Resolve
# the client, wait for the socket defensively, then provision (FAIL CLOSED if not ready).
MCLIENT="$(command -v mariadb || command -v mysql)"
MADMIN="$(command -v mariadb-admin || command -v mysqladmin)"
DBSOCK=/var/lib/mysql/mysql.sock   # Fedora's default socket — mariadb.service binds it here
MYSQL_ROOT() { "$MCLIENT" --socket="$DBSOCK" "$@"; }   # OS-root -> DB-root via unix_socket auth
_db_ready=0
for _i in $(seq 1 60); do
    if "$MADMIN" --socket="$DBSOCK" ping >/dev/null 2>&1; then _db_ready=1; break; fi
    sleep 1
done
[ "$_db_ready" = 1 ] || { echo "FATAL: MariaDB (mariadb.service) not ready for provisioning" >&2; exit 1; }
RDP_SECURITY=tls
RDP_PIN_BPP=0
. /usr/local/share/fedora-dev/bin/guac-db-provision.sh
guac_db_provision
unset GUAC_PW

# ---- GRD config: enable RDP (TLS, loopback+tailnet) + VNC (tailnet) ----------
# grdctl is per-user; run as core under its (lingering) user runtime. RDP serves
# :3389 (Guacamole fronts it on loopback; native RDP clients reach it on the
# tailnet); VNC serves :5900 (tailnet). The config contract is below; bringing
# up core's `systemd --user` gnome-remote-desktop-headless.service + the headless
# GNOME-Wayland session is HOST-VALIDATED (needs cgroup-v2 delegation).
cat > /tmp/grd-setup.sh <<'GRDEOF'
set -u
export XDG_RUNTIME_DIR=/run/user/1000
fail=0
grdctl --headless rdp set-tls-cert /var/lib/guac-cert/grd-cert.pem || { echo '[grd] rdp set-tls-cert FAILED'; fail=1; }
grdctl --headless rdp set-tls-key  /var/lib/guac-cert/grd-key.pem  || { echo '[grd] rdp set-tls-key FAILED';  fail=1; }
grdctl --headless rdp set-credentials core "$GRD_RDP_PW" || { echo '[grd] rdp set-credentials FAILED'; fail=1; }
grdctl --headless rdp enable || { echo '[grd] rdp enable FAILED'; fail=1; }
if [ "${GRD_VNC:-0}" = 1 ]; then
    grdctl --headless vnc set-auth-method password || { echo '[grd] vnc set-auth-method FAILED'; fail=1; }
    grdctl --headless vnc set-password "$GRD_VNC_PW" || { echo '[grd] vnc set-password FAILED'; fail=1; }
    grdctl --headless vnc enable || { echo '[grd] vnc enable FAILED'; fail=1; }
else
    grdctl --headless vnc disable 2>/dev/null || true   # no valid RFB_PW -> leave the VNC mirror off
fi
grdctl --headless status || true   # journal-visible proof of the applied config
exit $fail
GRDEOF
# Per-command guards (NOT `set -e` + one coarse "deferred"): one failing grdctl step no
# longer aborts the rest, and the journal names WHICH step failed. grdctl persists config to
# GKeyFile even with no running user service (live-verified: RDP enable/cert/creds DO stick),
# so this is config-complete; bringing up the headless GNOME-Wayland SESSION behind :3389
# (the actual painted desktop) remains HOST-VALIDATED — see THE SESSION (FAILURE 2) note.
runuser -u core -- env GRD_RDP_PW="$RDP_PW" GRD_VNC_PW="$VNC_PW" GRD_VNC="$GRD_VNC" \
    XDG_RUNTIME_DIR=/run/user/1000 bash /tmp/grd-setup.sh \
    || echo "[grd] one or more grdctl steps failed — see the [grd] lines above + 'grdctl status'"
rm -f /tmp/grd-setup.sh

echo "fedora-desktop-grd configured: GRD RDP(:3389,TLS)+VNC(:5900) + Guacamole web(:8443)."
echo "Headless GNOME-Wayland session + the claudebox come up under core's systemd --user"
echo "(loginctl linger is set; host-validated on a cgroup-delegating host)."
