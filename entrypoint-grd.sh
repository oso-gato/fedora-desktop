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
# Secrets reach this oneshot via the unit EnvironmentFile at
# /etc/fedora-desktop/secrets.env (a podman SECRET run.sh.grd creates + mounts
# there). PRINCIPLE 5 — runtime only, never a layer.
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
# Seed /etc/skel into core's home if a fresh bound /home/core volume left it empty (useradd never ran
# for core — uid 1000 is baked at build). Re-chown so the copied dotfiles aren't root-owned. Parity xrdp.
[ -e /home/core/.bashrc ] || { cp -rT /etc/skel /home/core 2>/dev/null || true; chown -R core:core /home/core 2>/dev/null || true; }
# Admin-home isolation: re-assert 0700 on core's home every boot (BINDING — CLAUDE.md "every
# home is 0700 incl core's; both lineages identically"). On a multi-user box this keeps core's
# vault / gh+OAuth / 1Password creds unreadable by uid-1001+ workers. Parity xrdp entrypoint.sh.
chmod 700 /home/core 2>/dev/null || true
# Parallel arrays. uid + port are keyed on the USERn NUMBER (1000+n / base+n), NOT the
# array index, so they MATCH guac-db-provision's per-user port even with gaps (e.g.
# USER1 + USER3 set, no USER2). core is index 0: uid 1000, port RDP_BASE_PORT.
USERNAMES=(core); USERPWS=("$RDP_PW"); USERUIDS=(1000); USERPORTS=("$RDP_BASE_PORT")
for _n in 1 2 3 4 5; do
    eval "_un=\${USER${_n}_NAME:-}; _up=\${USER${_n}_PW:-}"
    # UNSET on every reject path: the SHARED provisioner (guac-db-provision.sh) reads the RAW
    # USERn_NAME/_PW env, so a rejected user left set would still get a PHANTOM web login. Parity xrdp.
    [ -n "$_un" ] && [ -n "$_up" ] || { eval "unset USER${_n}_NAME USER${_n}_PW"; continue; }
    case "$_un" in core|root|gdm|gnome-remote-desktop|tomcat|mysql|daemon|bin|sys|nobody) echo "[grd] refusing reserved username '$_un'" >&2; eval "unset USER${_n}_NAME USER${_n}_PW"; continue;; esac
    echo "$_un" | grep -qE '^[a-z_][a-z0-9_-]{0,30}$' || { echo "[grd] invalid username '$_un' — skipped" >&2; eval "unset USER${_n}_NAME USER${_n}_PW"; continue; }
    # Never reset a SYSTEM account's password: refuse any pre-existing name resolving to uid<1000
    # (the reserved-name list above can't enumerate every distro/package system user).
    if id "$_un" >/dev/null 2>&1 && [ "$(id -u "$_un")" -lt 1000 ]; then
        echo "[grd] refusing system account '$_un' (uid<1000)" >&2; eval "unset USER${_n}_NAME USER${_n}_PW"; continue
    fi
    if ! id "$_un" >/dev/null 2>&1; then
        # Pin a per-user private group at GID 8000+n (RESERVED range, NOT 1000+n — the 1Password
        # packages bake groups at gid 1001/1002/1003) + UID 1000+n so the PERSISTED /home/<user>
        # volume's ownership is deterministic across recreations. Parity with the xrdp lineage.
        groupadd -g "$((8000 + _n))" "$_un" 2>/dev/null || true
        # GUARD useradd under set -eu: one failure must NOT abort the whole oneshot — extra users are
        # non-fatal (core + the other users still serve). Parity with the xrdp lineage.
        if useradd -m -u "$((1000 + _n))" -g "$((8000 + _n))" -s /bin/bash "$_un"; then
            # Own the BOUND per-user /home volume (root-owned mount; useradd -m won't chown a pre-existing
            # mountpoint). NUMERIC chown — never resolve a group name. grd was missing this entirely. 0700.
            chown -R "$((1000 + _n)):$((8000 + _n))" "/home/$_un" 2>/dev/null || true
            # useradd -m SKIPS a pre-existing bind-mount mountpoint, leaving an empty home — seed skel,
            # then re-chown numeric so the copied dotfiles aren't root-owned. Parity with the xrdp lineage.
            [ -e "/home/$_un/.bashrc" ] || cp -rT /etc/skel "/home/$_un" 2>/dev/null || true
            chown -R "$((1000 + _n)):$((8000 + _n))" "/home/$_un" 2>/dev/null || true
        else
            echo "[grd] useradd '$_un' failed — skipping" >&2; eval "unset USER${_n}_NAME USER${_n}_PW"; continue
        fi
    fi
    # chpasswd non-fatal for EXTRA users (set -eu) — honor the "extra users non-fatal" contract.
    echo "${_un}:${_up}" | chpasswd || { echo "[grd] chpasswd '$_un' failed — skipping" >&2; eval "unset USER${_n}_NAME USER${_n}_PW"; continue; }
    gpasswd -d "$_un" wheel >/dev/null 2>&1 || true   # defensive: NEVER wheel (idempotent, parity with xrdp)
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
    # BOUNDED 6×5s retry (~30s cap) — NOT xrdp's unbounded `until`: tomcat.service Requires= this
    # oneshot, so an unbounded loop on a bad key would deadlock the public web door forever.
    _ts_ok=0
    for _t in 1 2 3 4 5 6; do
        tailscale up --ssh --auth-key="${TS_AUTHKEY}" --hostname=fedora-desktop-grd && { _ts_ok=1; break; }
        echo "[tailscale] up attempt $_t failed, retrying 5s" >&2; sleep 5
    done
    [ "$_ts_ok" = 1 ] || echo "[tailscale] up failed after retries (bad/expired TS_AUTHKEY?) — fleet tiles + tailnet RDP stay unreachable until 'tailscale up' succeeds" >&2
else
    # No key: kick the interactive web-login in the BACKGROUND (so this oneshot + tomcat don't block
    # on a browser). SINGLE attempt — keyless `tailscale up` BLOCKS until the operator completes the
    # login URL, so there is nothing to retry (and `| sed` masks its exit anyway: no pipefail set).
    ( tailscale up --ssh --hostname=fedora-desktop-grd 2>&1 | sed 's/^/[tailscale] /' ) &
    echo "[tailscale] no TS_AUTHKEY — open the login.tailscale.com URL in the journal to join (one-time per state volume)" >&2
fi

# ---- tailnet-only by CONSTRUCTION (defense-in-depth; parity with the xrdp lineage) --
# The nft tailnet-guard (drops ssh/mosh/RDP/VNC on every iface but lo + tailscale0) now
# lives in the always-on fedora-desktop-grd-netguard.service oneshot (ordered Before
# sshd/tailscaled, with NO Requires=mariadb — see install-grd.sh), so the tailnet-only
# boundary holds even if THIS DB-gated firstboot oneshot never runs. Moved out of here
# to honor the xrdp-parity "guard present whenever a listener is" invariant.

# ---- Tomcat TLS keystore for the public :8443 web door ----------------------
install -d -m 0750 -o tomcat -g tomcat "$CERTDIR"   # tomcat must own+traverse to read keystore.p12 on a FRESH /var/lib/guac-cert volume (parity xrdp)
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
# Cross-version datadir self-heal: a monthly --no-cache base rebuild can land a NEWER MariaDB on an
# EXISTING /var/lib/mysql volume whose system tables then need upgrading. Run it idempotently here
# (self-skips when already current, keyed on mysql_upgrade_info) BEFORE provisioning. NON-FATAL — a
# failed/again-current upgrade must never block the web door. Parity with the xrdp lineage.
MUPGRADE="$(command -v mariadb-upgrade || command -v mysql_upgrade || echo '')"
[ -n "$MUPGRADE" ] && "$MUPGRADE" --socket="$DBSOCK" >/var/log/mariadb-upgrade.log 2>&1 || true
RDP_SECURITY=any
RDP_PIN_BPP=0
RDP_PORT_PER_USER=1
. /usr/local/share/fedora-dev/bin/guac-db-provision.sh
guac_db_provision
unset GUAC_PW

# ---- per-user GRD headless sessions (variant 1) — the SPIKE's TWO-PASS shape ------
# THE LOAD-BEARING ORDERING (host-proven in validation/grd-headless-spike.sh, and the one
# thing the earlier single-pass loop got wrong): `systemctl enable --now gnome-headless-
# session@$u` returns as soon as the SYSTEM unit is active — but that unit only kicks gdm's
# CreateUserDisplay, which then ASYNCHRONOUSLY brings up the user's `systemd --user` manager
# and its session bus at /run/user/$uid/bus. grdctl --headless persists via GSettings/dconf,
# which writes THROUGH that bus; run it before the bus exists and the write either fails or
# lands in a throwaway dconf db the real session never reads → the daemon binds a wrong/
# negotiated port → Guacamole dials a dead port → BLACK desktop, silently. The spike avoided
# this by enabling ALL sessions, sleeping 25s ONCE, then configuring grdctl per user. We do
# the same two passes but POLL each user bus (strictly better than a blind sleep).

# Pass-1 helper: spawn one user's headless autologin session (gdm CreateUserDisplay, no greeter).
start_grd_session() {   # <user>
    local u="$1"
    loginctl enable-linger "$u" >/dev/null 2>&1 || true
    systemctl enable --now "gnome-headless-session@${u}.service" 2>/dev/null \
        || echo "[grd] $u: gnome-headless-session@ failed to start (see journalctl)" >&2
}
# Settle helper: poll up to ~40s for the user's session bus to appear (replaces sleep 25).
wait_user_bus() {   # <user> <uid> — poll until the session bus actually ANSWERS, not just exists
    # The bus SOCKET can appear before the user's `systemd --user` dbus is answering, and grdctl
    # writes config through dconf-over-that-bus — so probe a real round-trip (`busctl --user list`),
    # not just the socket file, before returning ready. ~40s bounded; timeout is non-fatal.
    local u="$1" uid="$2" _w
    for _w in $(seq 1 40); do
        if [ -S "/run/user/$uid/bus" ] && runuser -u "$u" -- env XDG_RUNTIME_DIR="/run/user/$uid" \
             DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" busctl --user list >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    return 1
}
# Pass-2 helper: configure + start GRD inside the (now-up) user session bus. Returns the
# rdp-enable status so the caller can fail CLOSED on core. Values pass via ENV into a
# SINGLE-quoted body so passwords with shell metachars are safe.
configure_grd_user() {   # <user> <uid> <port> <rdp_pw>  → exit 0 iff `rdp enable` + daemon start OK
    local u="$1" uid="$2" port="$3" pw="$4" cert="/home/$1/.grd-cert"
    install -d -m 0700 -o "$u" -g "$u" "$cert"
    if [ ! -f "$cert/cert.pem" ]; then
        runuser -u "$u" -- openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
            -subj "/CN=fedora-desktop-grd-$u" -keyout "$cert/key.pem" -out "$cert/cert.pem" 2>/dev/null \
            && chmod 600 "$cert/key.pem" || echo "[grd] $u: TLS mint FAILED" >&2
    fi
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
        grdctl --headless rdp enable || { echo "[grd] $GU rdp enable FAILED"; exit 1; }
        systemctl --user restart gnome-remote-desktop-headless.service 2>/dev/null \
            || systemctl --user start gnome-remote-desktop-headless.service \
            || { echo "[grd] $GU headless.service FAILED"; exit 1; }
        grdctl --headless status || true
        exit 0'
}

# Pass 1: spawn EVERY user's headless session (lets gdm bring up concurrent CreateUserDisplay
# sessions in parallel — the proven multi-user behavior — instead of serializing one at a time).
for _i in "${!USERNAMES[@]}"; do start_grd_session "${USERNAMES[$_i]}"; done
# Settle: wait for each user's session bus before any grdctl write.
for _i in "${!USERNAMES[@]}"; do
    wait_user_bus "${USERNAMES[$_i]}" "${USERUIDS[$_i]}" \
        || echo "[grd] ${USERNAMES[$_i]}: session bus /run/user/${USERUIDS[$_i]}/bus never appeared — grdctl config may not persist" >&2
done
# Pass 2: configure GRD per user. Track CORE (index 0) specifically; for ADDITIONAL users drop a
# per-port readiness marker under /run/fedora-desktop-grd keyed on the per-user RDP port (3389+n).
# Consumer: an operator/diagnostic probe today (`podman exec <c> ls /run/fedora-desktop-grd`); the
# container healthcheck does NOT yet read it — wiring the multi-port probe into run.sh.grd is the
# follow-up CONTROL-PLANE PR (run.sh.grd is control-plane, shipped standalone). Extra users NON-FATAL.
mkdir -p /run/fedora-desktop-grd 2>/dev/null || true
_core_grd_ok=0
for _i in "${!USERNAMES[@]}"; do
    _port="${USERPORTS[$_i]}"
    if configure_grd_user "${USERNAMES[$_i]}" "${USERUIDS[$_i]}" "$_port" "${USERPWS[$_i]}"; then
        if [ "$_i" = 0 ]; then _core_grd_ok=1; else touch "/run/fedora-desktop-grd/user-$_port.ready" 2>/dev/null || true; fi
    else
        echo "[grd] ${USERNAMES[$_i]}: GRD headless RDP did NOT enable (see [grd] lines above)" >&2
        [ "$_i" = 0 ] || rm -f "/run/fedora-desktop-grd/user-$_port.ready"   # absent marker => probe sees a dead port
    fi
done
# FAIL CLOSED on core: a dead core desktop must NOT be served behind a green box. tomcat.service
# Requires= this oneshot, so exit 1 keeps :8443 down → the box never reports (healthy) → the host
# rollback catches it — instead of the old fail-OPEN that exited 0 over a black desktop. Extra-user
# failures are logged but non-fatal (core + the other users still serve).
[ "$_core_grd_ok" = 1 ] || { echo "FATAL: core's GRD headless RDP failed to enable — refusing to serve a black desktop behind a healthy web door (likely the session/bus race; see journalctl -u 'gnome-headless-session@core' and the [grd] lines above)" >&2; exit 1; }

echo "fedora-desktop-grd configured: GRD SYSTEM-FREE headless (variant 1) for users: ${USERNAMES[*]}"
echo "Each user = a gdm-spawned headless autologin GNOME session served by"
echo "gnome-remote-desktop-headless on its own loopback RDP port (core :3389, USERn :338n+)."
echo "Apache Guacamole fronts each port as the single public :8443 web door (GUAC_PW + TOTP)."
