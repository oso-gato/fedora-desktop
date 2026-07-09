#!/bin/bash
# fedora-desktop PID 1 (root). MERGED supervisor:
#
#   HARNESS (from fedora-dev/entrypoint.sh):
#     * sshd (key-only; mosh rides on it; tailscale --ssh is the keyless tailnet door)
#     * tailscaled (+ tailscale up, unattended via TS_AUTHKEY or interactive banner)
#     * core's rootless podman API socket (CONTAINER_HOST target for the box)
#     * inotify watcher for in-box claudebox-rebuild flag
#     * daily-tick loop -> claudebox-daily.sh (rebuild if idle, else defer)
#     * first-boot live-clone-or-seed of the spec
#     * eager first-boot claudebox assemble (background)
#
#   DESKTOP (the XFCE/xrdp desktop layer):
#     * seed core's RDP/system password (chpasswd) from RDP_PW
#     * MariaDB (loopback) + Guacamole DB-auth/TOTP provisioning + TLS keystore mint
#     * xrdp-sesman + xrdp (RDP :3389, tailnet-only)
#     * guacd + Tomcat/Guacamole (web door TLS :8443, the SOLE public desktop port)
#     * optional RFB_PW x0vncserver same-session mirror (:5900, tailnet-only)
#
#   KNOWLEDGE-WORK helpers (authored separately under bin/, invoked here):
#     * bin/cloud-sync.sh    (rclone mount + delete-guarded bisync; non-vault)
#     * bin/vault-gitsync.sh (periodic commit + pull --rebase + push of the vault)
#   Both run as core, backgrounded + watchdog-supervised, and TOLERATE ABSENCE /
#   an unset enabling flag gracefully (the box still boots without them).
#
# Supervises all critical services in a pgrep + kill-0 watchdog loop; the outer
# --restart=always heals on any death. Fails fast if RDP_PW/GUAC_PW are missing.
set -eu

# Graceful shutdown: when the host's container-refresh.sh `podman stop`s us, we
# get SIGTERM. Propagate it to our process group so sshd closes connections
# cleanly, tailscaled deregisters cleanly, xrdp/tomcat/guacd + supervised
# children exit cleanly, rather than getting SIGKILLed after the podman-stop
# timeout.
trap 'kill -TERM 0 2>/dev/null; exit 0' TERM INT

# ---- secrets: sourced from the secret-mounted 0400 secrets.env (run.sh creates
# the podman secret it mounts,
# NOT `podman -e`, so RDP_PW/GUAC_PW never land in PID 1's /proc/1/environ or
# `podman inspect`). They become SHELL vars here (never exported), are consumed
# below, then unset — parity with the grd lineages. (Back-compat: an old
# `-e`-style invocation still works — the vars are already in the environ and this
# source is simply skipped.)
[ -r /etc/fedora-desktop/secrets.env ] && . /etc/fedora-desktop/secrets.env

# ---- fail fast on the desktop's required runtime secrets (PRINCIPLE 5) ------
# RDP_PW  — ALWAYS: core's system/RDP password (xrdp authenticates via PAM; the
#           Guacamole web door single-signs-on into the loopback RDP with it).
# GUAC_PW — ALWAYS: the Guacamole web-login password on the PUBLIC :8443 door. This
#           is the only auth on the only public door — use a STRONG password
#           (brute-force lockout is enforced by the guacamole-auth-ban extension).
# RFB_PW  — OPTIONAL: arms the tailnet-only x0vncserver :5900 mirror for native VNC
#           viewers (VncAuth, weak/8-char — fine since :5900 is tailnet-only).
: "${RDP_PW:?RDP_PW must be set (core system/RDP password) — see run.sh}"
: "${GUAC_PW:?GUAC_PW must be set (the public Guacamole web-login password) — see run.sh}"

# CORE_PASSWORD (the old fedora-dev var) is no longer meaningful — the desktop's
# RDP_PW IS core's system password now. Ignore a stale CORE_PASSWORD if set.
unset CORE_PASSWORD 2>/dev/null || true

# ---- seed core's system/RDP password (runtime only — never in a layer) ------
echo "core:${RDP_PW}" | chpasswd

# ---- home volume may be empty on first run ----------------------------------
if [ ! -e /home/core/.bashrc ]; then
    cp -rT /etc/skel /home/core
fi
# Desktop session needs .Xclients for xrdp. Use the baked session cmd
# (/etc/fedora-desktop/xsession, set at build) so a fresh home volume launches the
# baked desktop (XFCE — the sole xrdp variant) via its startxfce4 entry.
if [ ! -e /home/core/.Xclients ]; then
    printf '%s\n' "$(cat /etc/fedora-desktop/xsession 2>/dev/null || echo startxfce4)" > /home/core/.Xclients
    chmod +x /home/core/.Xclients
fi
# Recursive chown — non-recursive leaves the cp'd dotfiles root-owned, which
# breaks any non-sudo edit by core inside or outside the box.
chown -R core:core /home/core
# Data separation (multi-user): 0700 so NO other desktop user can read core's vault
# or gh/OAuth tokens. All users share this container's kernel — DAC perms are the
# fence, not a sandbox (disclosed in CLAUDE.md).
chmod 700 /home/core

# ============================================================================
# MULTI-USER: optional non-privileged "knowledge wiki worker" accounts
# ============================================================================
# core stays the ADMIN (wheel + claudebox + rootless podman = full dev). Up to TWO
# extra users may be injected at SPIN-UP via secrets.env (USER1_NAME/USER1_PW,
# USER2_NAME/USER2_PW — Principle 5: runtime only, never a layer). They are "wiki
# workers": a full XFCE desktop + the apps, but NO dev — NOT in wheel, no sudo, and
# NO /etc/subuid row, so they cannot run rootless podman or reach the claudebox.
# Each gets their OWN persisted /home/<user> volume (run.sh) + their OWN Guacamole
# web login (built below), fenced from the Dev/VPS fleet-bastion tiles. Idempotent:
# /home persists, so on restart we re-apply password + non-priv posture, never clobber
# data. A valid+provisioned user keeps USER{i}_NAME set (the DB provisioning reads it);
# an invalid one is unset so it is skipped everywhere.
for _i in 1 2 3 4 5; do
  eval "_n=\${USER${_i}_NAME:-}; _p=\${USER${_i}_PW:-}"
  if [ -z "$_n" ] || [ -z "$_p" ]; then eval "unset USER${_i}_NAME USER${_i}_PW"; continue; fi
  case "$_n" in
    core|root|tomcat|daemon|bin|sys|nobody)
      echo "[users] refusing reserved name '$_n'"; eval "unset USER${_i}_NAME USER${_i}_PW"; continue ;;
  esac
  if ! printf '%s' "$_n" | grep -Eq '^[a-z_][a-z0-9_-]{0,30}$'; then
    echo "[users] invalid username '$_n' — need ^[a-z_][a-z0-9_-]{0,30}$ — skipping"
    eval "unset USER${_i}_NAME USER${_i}_PW"; continue
  fi
  # Normalize this user's FLEET access grant: 'none' | 'all' | comma-list of fleet labels
  # (tailnet hostnames, per spin-up's per-host picker). This selects which bastion tiles the
  # user's web login shows (the DB provisioning reads USER{i}_ACCESS below; grant = bastion reach,
  # lands as core on the target). Sanitize to [A-Za-z0-9._,-] (drop spaces / anything risky);
  # empty -> none. guac-db-provision exact-matches each label, fail-closed.
  eval "_a=\${USER${_i}_ACCESS:-none}"
  _a="$(printf '%s' "$_a" | tr -cd 'A-Za-z0-9._,-')"; [ -n "$_a" ] || _a=none
  eval "USER${_i}_ACCESS=\$_a"
  if ! id -u "$_n" >/dev/null 2>&1; then
    # CREATE non-privileged: NO -aG wheel, NO subuid/subgid row (rootless podman stays core-only).
    # Pin a per-user private group at GID 8000+i (a RESERVED range) so the PERSISTED /home/<user>
    # volume's ownership is DETERMINISTIC across recreations — useradd without -g auto-allocates a GID
    # that drifts when the user set changes. UID stays 1000+i (those are free). GID is 8000+i, NOT
    # 1000+i, because the 1Password packages BAKE groups at gid 1001/1002/1003 (onepassword/-mcp/-cli):
    # `groupadd -g 1001` would collide and `useradd -g 1001` would put the user in the onepassword group
    # -> `chown name:name` then dies on the unknown group name and crashes PID 1 under set -e. 8000+i is
    # clear of core(1000)/1Password(1001-3)/deskshare(6000). Home stays 0700: stable ownership only.
    groupadd -g "$((8000 + _i))" "$_n" 2>/dev/null || true
    if useradd -m -u "$((1000 + _i))" -g "$((8000 + _i))" -s /bin/bash "$_n"; then
      [ -e "/home/$_n/.bashrc" ] || cp -rT /etc/skel "/home/$_n" 2>/dev/null || true
      printf '%s\n' "$(cat /etc/fedora-desktop/xsession 2>/dev/null || echo startxfce4)" > "/home/$_n/.Xclients"
      # NUMERIC + non-fatal chown: never resolve a group NAME (a failed groupadd must not crash PID 1).
      chmod +x "/home/$_n/.Xclients"; chown -R "$((1000 + _i)):$((8000 + _i))" "/home/$_n" 2>/dev/null || true
    else
      echo "[users] useradd '$_n' failed — skipping"; eval "unset USER${_i}_NAME USER${_i}_PW"; continue
    fi
  fi
  # ALWAYS (idempotent): set/rotate password, enforce non-priv + 0700 home.
  echo "$_n:$_p" | chpasswd
  gpasswd -d "$_n" wheel >/dev/null 2>&1 || true   # defensive: NEVER wheel
  chmod 700 "/home/$_n"
  echo "[users] provisioned non-dev wiki worker '$_n' (uid $(id -u "$_n"))"
done

# ---- optional SHARED collaboration folder (ENABLE_SHARED) -------------------
# A single 2770 root:deskshare volume at /home/shared that every desktop user (core + each
# provisioned USERn) can read/write — with a DEFAULT POSIX ACL forcing group rwx on new files
# so collaboration is FULL read-write regardless of each user's umask (host-validated:
# validation/user-volumes-spike.sh). Homes stay 0700: deskshare is a SUPPLEMENTARY group only,
# never anyone's primary/home group, so the per-user vault/token isolation is untouched. The
# /home/shared volume is bound by run.sh ONLY when ENABLE_SHARED is set; here we group-own +
# ACL it and add the members. Idempotent (the volume + group may already exist on restart).
if [ -n "${ENABLE_SHARED:-}" ]; then
    groupadd -g 6000 deskshare 2>/dev/null || true
    install -d -m 2770 -o root -g deskshare /home/shared
    chown root:deskshare /home/shared; chmod 2770 /home/shared
    # default ACL -> new files inherit group rwx (umask-independent); access ACL on the dir too.
    setfacl -d -m group:deskshare:rwx /home/shared 2>/dev/null || true
    setfacl    -m group:deskshare:rwx /home/shared 2>/dev/null || true
    _members="core"
    for _i in 1 2 3 4 5; do eval "_n=\${USER${_i}_NAME:-}"; [ -n "$_n" ] && _members="$_members $_n"; done
    for _m in $_members; do usermod -aG deskshare "$_m" 2>/dev/null || true; done
    echo "[shared] /home/shared enabled (group deskshare; members: $_members)"
fi

# ---- rootless podman needs a runtime dir (no systemd/PAM session manager) ---
install -d -m 0700 -o core -g core /run/user/1000

# ---- defensive: restore newuidmap/newgidmap file caps if overlay stripped them
# Build-time setcap (install.sh) doesn't always survive layer commits in every
# podman storage configuration; the security.capability xattr can be lost. We
# verify + restore at boot. Idempotent: no-op when caps are already present.
for bin in /usr/bin/newuidmap /usr/bin/newgidmap; do
    [ -x "$bin" ] || continue
    if ! getcap "$bin" | grep -q "cap_set"; then
        case "$bin" in
            */newuidmap) setcap cap_setuid+ep "$bin" ;;
            */newgidmap) setcap cap_setgid+ep "$bin" ;;
        esac
        echo "[caps] restored on $bin"
    fi
done

# ---- persistent ssh host keys on the root-owned state volume ----------------
install -d -m 0700 /var/lib/tailscale/hostkeys
if [ ! -f /var/lib/tailscale/hostkeys/ssh_host_ed25519_key ]; then
    ssh-keygen -t ed25519 -N "" -f /var/lib/tailscale/hostkeys/ssh_host_ed25519_key
fi
mkdir -p /run/sshd

# ---- sync core's ssh authorized_keys from github.com/oso-gato.keys ---------
# Key-only sshd auth. Fetch from GitHub each boot, cache on the home volume.
# If GitHub is briefly unreachable AND a cached file exists, keep the cache.
# If GitHub is unreachable AND no cache: public ssh key-auth is closed until
# next reachable sync — Tailscale SSH (keyless) remains the operator's path in.
runuser -u core -- bash -c '
    set -u
    mkdir -p ~/.ssh
    chmod 0700 ~/.ssh
    tmp=$(mktemp)
    if curl -fsSL --max-time 10 https://github.com/oso-gato.keys -o "$tmp" && [ -s "$tmp" ]; then
        mv "$tmp" ~/.ssh/authorized_keys
        chmod 0600 ~/.ssh/authorized_keys
        echo "[ssh-keys] synced from github.com/oso-gato.keys ($(wc -l < ~/.ssh/authorized_keys) keys)"
    else
        rm -f "$tmp"
        if [ -s ~/.ssh/authorized_keys ]; then
            echo "[ssh-keys] GitHub unreachable; keeping cached ~/.ssh/authorized_keys"
        else
            echo "[ssh-keys] WARNING: GitHub unreachable AND no cached keys — public ssh closed; use Tailscale SSH to recover"
        fi
    fi
'

# ============================================================================
# DESKTOP: Guacamole web-gateway — DB-backed auth (MariaDB) + TOTP 2FA
# ============================================================================
# The public :8443 door authenticates against MariaDB (guacamole-auth-jdbc) with
# TOTP 2FA (guacamole-auth-totp) layered on, behind the auth-ban IP lockout. TOTP
# REQUIRES a database (the file user-mapping cannot store the per-user enrollment
# seed). Each web login SSOs into that identity's own loopback-RDP desktop (core ->
# RDP_PW; each extra user -> their own password); the RDP password never crosses the
# public door (RDP is loopback/tailnet-only). Defense-in-depth: a STRONG password
# (spin-up's diceware floor) AND TOTP — TOTP is phishable and its seed lives in this
# same DB, so the password stays a load-bearing, independent barrier; it is NOT
# relaxed just because 2FA is on.
install -d -m 0750 -o tomcat -g tomcat /etc/guacamole

# MUST-DO: the built-in file-auth provider is ALWAYS active when user-mapping.xml
# exists, and it does NOT enforce TOTP — a surviving file would be a live no-2FA
# bypass. Remove any stale copy (e.g. left by a previous file-auth image) every boot.
rm -f /etc/guacamole/user-mapping.xml

# Audio: OFF by default (low-bandwidth desktop; audio is a continuous push stream).
# Guacamole's lever is `disable-audio` (audio ON unless set); ENABLE_AUDIO=true restores.
if [ "${ENABLE_AUDIO:-false}" = "true" ]; then RDP_DISABLE_AUDIO=0; else RDP_DISABLE_AUDIO=1; fi

# Resolve MariaDB tool names (Fedora renamed mysql*->mariadb*; keep a mysql* fallback).
MARIADBD="$(command -v mariadbd || command -v mysqld || echo /usr/sbin/mariadbd)"
MADMIN="$(command -v mariadb-admin || command -v mysqladmin)"
MINSTALL="$(command -v mariadb-install-db || command -v mysql_install_db)"
MUPGRADE="$(command -v mariadb-upgrade || command -v mysql_upgrade || echo '')"
MCLIENT="$(command -v mariadb || command -v mysql)"
DBSOCK=/var/lib/mysql/mysql.sock   # Fedora's default socket (datadir-local) — same on all lineages
MYSQL_ROOT() { "$MCLIENT" --socket="$DBSOCK" "$@"; }   # OS-root -> DB-root via unix_socket auth

# ---- MariaDB: loopback DB engine under the supervised-bash watchdog (no systemd) ---
# datadir = the /var/lib/mysql persistent volume (control-plane: declared in run.sh /
# the Quadlet). Bound to 127.0.0.1 ONLY — Principle 7: 3306 is NEVER published. The
# query log + binlog stay OFF so a password never lands in a log. /run/mariadb is the
# pid-file dir (created by tmpfiles on the systemd lineages; we make it here for xrdp).
install -d -m 0755 -o mysql -g mysql /run/mariadb
chown mysql:mysql /var/lib/mysql 2>/dev/null || true
chmod 0750 /var/lib/mysql 2>/dev/null || true
if [ ! -d /var/lib/mysql/mysql ]; then
    echo "[db] first boot: initializing MariaDB datadir"
    "$MINSTALL" --user=mysql --datadir=/var/lib/mysql \
        --auth-root-authentication-method=socket >/var/log/mariadb-install.log 2>&1
fi
runuser -u mysql -- "$MARIADBD" \
    --datadir=/var/lib/mysql --socket="$DBSOCK" \
    --bind-address=127.0.0.1 --port=3306 --skip-name-resolve --general-log=0 --skip-log-bin \
    >/var/log/mariadbd.log 2>&1 &
# wait for readiness; FAIL CLOSED if the engine never answers.
_db_ready=0
for _i in $(seq 1 60); do
    if "$MADMIN" --socket="$DBSOCK" ping >/dev/null 2>&1; then _db_ready=1; break; fi
    sleep 1
done
[ "$_db_ready" = 1 ] || { echo "FATAL: MariaDB did not become ready" >&2; exit 1; }
echo "[db] MariaDB up on 127.0.0.1:3306 (loopback only)"
# Cross-version datadir upgrade: a monthly --no-cache base rebuild can land a NEWER MariaDB on an
# EXISTING /var/lib/mysql volume, whose system tables then need upgrading. The systemd lineage runs
# this via mariadb.service's ExecStartPost=mariadb-check-upgrade; the no-systemd watchdog has no
# equivalent, so run it idempotently here (it self-skips when the datadir is already current, keyed
# on mysql_upgrade_info). NON-FATAL — a failed/again-current upgrade must never block the desktop.
[ -n "$MUPGRADE" ] && "$MUPGRADE" --socket="$DBSOCK" >/var/log/mariadb-upgrade.log 2>&1 || true

# ---- provision Guacamole DB-auth + TOTP via the shared single-source helper -------
# bin/guac-db-provision.sh (COPY'd to /usr/local/share/fedora-dev/bin/) is the ONE
# place the four TOTP/DB must-dos live, byte-identical across both lineages
# (xrdp here; grd source the same file). xrdp specifics: RDP security 'any' + pin
# 24bpp (the cross-device session-RESUME invariant). MYSQL_ROOT + DBSOCK were defined
# during the MariaDB bring-up above; the helper generates the loopback DB_PW itself.
RDP_SECURITY=any
RDP_PIN_BPP=1
. /usr/local/share/fedora-dev/bin/guac-db-provision.sh
guac_db_provision
unset GUAC_PW
# ---- TLS keystore (PKCS12) for Tomcat's :8443 connector ---------------------
if [ ! -f /var/lib/guac-cert/keystore.p12 ]; then
    install -d -m 0750 -o tomcat -g tomcat /var/lib/guac-cert
    keytool -genkeypair -alias guac -keyalg RSA -keysize 2048 -validity 3650 \
        -dname "CN=fedora-desktop" -storetype PKCS12 \
        -keystore /var/lib/guac-cert/keystore.p12 -storepass container-local
    chown tomcat:tomcat /var/lib/guac-cert/keystore.p12
    chmod 640 /var/lib/guac-cert/keystore.p12
fi

# ============================================================================
# HARNESS: sshd + tailscaled
# ============================================================================

# ---- sshd: container :22 (host publishes public :4444 via Quadlet/run.sh) ----
/usr/sbin/sshd

# ---- tailscaled --------------------------------------------------------------
/usr/sbin/tailscaled --state=/var/lib/tailscale/tailscaled.state \
    --socket=/var/run/tailscale/tailscaled.sock &
for _ in $(seq 1 30); do
    tailscale status >/dev/null 2>&1 && break
    [ -S /var/run/tailscale/tailscaled.sock ] && break
    sleep 1
done

if [ -n "${TS_AUTHKEY:-}" ]; then
    until tailscale up --ssh --auth-key="${TS_AUTHKEY}" --hostname=fedora-desktop; do
        echo "[tailscale] up failed, retrying in 5s"; sleep 5
    done
    echo "==== TAILNET JOINED ===="
else
    (
        until tailscale up --ssh --hostname=fedora-desktop 2>&1 | sed 's/^/[tailscale] /'; do
            sleep 5
        done
        echo "==== TAILNET JOINED ===="
    ) &
    echo "=================================================================="
    echo " ACTION REQUIRED: open the login.tailscale.com URL printed above"
    echo " (podman logs -f fedora-desktop). One-time per tailscale state volume."
    echo "=================================================================="
fi

# ---- tailnet-only by CONSTRUCTION (defense-in-depth) ------------------------
# The web gateway (:8443) is the ONLY public door. ssh (:22), mosh (UDP
# 61001-62000), RDP (:3389) and VNC (:5900) are TAILNET-ONLY: run.sh publishes only
# the web port, and THIS nft rule drops those ports on every interface except lo
# (loopback: guacd) and tailscale0 (the tailnet) — so a future `-p 22`
# / `-p 3389` slip can't expose key/password auth to the public internet. The web
# port is NOT dropped (policy accept). Own dedicated nft table;
# `iifname` matches by name so it loads before tailscale0 exists; best-effort
# (needs NET_ADMIN), never fatal to PID 1.
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

# ============================================================================
# DESKTOP: xrdp (RDP session owner) + the Guacamole web door + VNC head
# ============================================================================

# ---- xrdp (RDP :3389, tailnet-only) — owns the Xorg :10 session -------------
mkdir -p /var/run/xrdp
/usr/sbin/xrdp-sesman --nodaemon &
sesman_pid=$!
sleep 1
/usr/sbin/xrdp --nodaemon &
xrdp_pid=$!

# ---- boot-time session bootstrap --------------------------------------------
# Pre-create the Xorg :10 session so the Guacamole web door (and the optional VNC
# mirror) are live BEFORE any RDP login. xrdp-sesrun asks sesman to start core's
# session; KillDisconnected=false keeps it alive across this bootstrap client's
# disconnect. Best-effort, retried until :10 appears, NEVER fatal to PID 1. Password
# is read from fd 0 (-F 0) — never on the command line.
( for _i in $(seq 1 8); do
    [ -e /tmp/.X11-unix/X10 ] && { echo "[bootstrap] session :10 is up"; break; }
    printf '%s' "$RDP_PW" | xrdp-sesrun -F 0 -t Xorg -g 1920x1080 -b 24 core \
        >>/var/log/xrdp-sesrun.log 2>&1 || true
    sleep 3
  done ) &

# ---- the WEB door on TLS :8443 — Apache Guacamole ---------------------------
# guacd (loopback RDP client) + Tomcat serving the .war + the jdbc/totp/auth-ban
# extensions. Fedora's Tomcat needs NAME=tomcat + CATALINA_BASE; JAVA_OPTS points
# Guacamole at /etc/guacamole (guacamole.properties + lib/ JDBC driver + extensions/).
# DB-readiness gate: never start the web door if MariaDB isn't answering (Guacamole
# would fail every login into a hard lockout). The watchdog covers steady-state.
"$MADMIN" --socket="$DBSOCK" ping >/dev/null 2>&1 \
    || { echo "FATAL: MariaDB not ready at web-door start" >&2; exit 1; }
/usr/sbin/guacd -b 127.0.0.1
# guacd daemonizes; track it by name in the watchdog (no usable PID from -b).
export NAME=tomcat CATALINA_BASE=/usr/share/tomcat
runuser -u tomcat -- env NAME=tomcat CATALINA_BASE=/usr/share/tomcat \
    JAVA_OPTS="-Dguacamole.home=/etc/guacamole" \
    bash /usr/libexec/tomcat/server start >/var/log/tomcat-console.log 2>&1 &

# ---- same-session VNC head: x0vncserver scrapes the xorgxrdp :10 display -----
# OPTIONAL tailnet VNC mirror for native VNC viewers (arm by setting RFB_PW). :5900
# is TAILNET-ONLY, NEVER published. VncAuth: only the first 8 chars of RFB_PW are
# effective — fine for a tailnet-only door (the PUBLIC door is Guacamole only).
# The boot-time bootstrap (above) pre-creates :10. The respawn loop's PID is tracked by
# the watchdog (x0vnc_pid) so a LOOP death trips --restart=always; run.sh's health
# probe also checks the live :5900 backend, not just the door page.
if [ -n "${RFB_PW:-}" ]; then
    printf '%s' "$RFB_PW" | runuser -u core -- vncpasswd -f > /home/core/.vncpasswd_rfb
    chown core:core /home/core/.vncpasswd_rfb && chmod 600 /home/core/.vncpasswd_rfb
    unset RFB_PW
    ( while true; do
        if [ -e /tmp/.X11-unix/X10 ]; then
            runuser -u core -- env HOME=/home/core \
                x0vncserver -display :10 -rfbport 5900 \
                -SecurityTypes VncAuth -PasswordFile /home/core/.vncpasswd_rfb \
                -AcceptSetDesktopSize >/var/log/x0vncserver.log 2>&1 || true
            echo "x0vncserver exited; retrying in 3s"
        fi
        sleep 3
      done ) &
    x0vnc_pid=$!
    echo "VNC head armed: :5900 (tailnet-only native-VNC mirror of the :10 RDP session)"
fi
# RDP_PW is fully consumed now (chpasswd + the DB RDP-connection params). Drop it.
unset RDP_PW

# ============================================================================
# BOX supervisor: live-spec bootstrap + claudebox machinery (from fedora-dev)
# ============================================================================

# State + spec dirs for the box, CORE-owned. List EACH level explicitly: `install -d`
# leaves an intermediate parent it has to create (here /home/core/.local) owned by the
# CALLER (root), not by -o core — and the live-spec seed below runs as `core` and writes
# /home/core/.local/share. A root-owned .local makes that `mkdir` "Permission denied",
# which (via the outer set -e on the runuser call) killed PID 1 and took the whole
# DESKTOP down on a fresh home volume. Creating .local + .local/share core-owned up front
# fixes it. (chmod 700 /home/core earlier still lets core, the owner, traverse/create here.)
install -d -m 0755 -o core -g core \
    /home/core/.local /home/core/.local/share \
    /home/core/.local/state /home/core/.local/state/claudebox

# ---- live-spec bootstrap (first boot only) ---------------------------------
# Clone the fedora-desktop repo to /home/core/.local/share/fedora-dev/ — the
# LIVE source of truth for distrobox.ini and the box scripts. (Path kept as
# `fedora-dev` because the box machinery — claudebox-*.sh, the wrappers — reads
# that fixed path; only the GitHub remote differs.) It persists on the home
# volume across container recreations, so mid-cycle distrobox.ini edits SURVIVE
# the monthly base-image refresh.
#
# Fallback: if GitHub is unreachable after 5 retries, copy from the baked seed
# WITHOUT git-init (a seeded-no-git state). The box rebuild, daily tick, and
# inotify watcher all keep working (they read files, not git); propose-and-commit
# is blocked until converted — see CONVERT-TO-GIT.md dropped alongside.
runuser -u core -- bash <<'BOOTSTRAP' || echo "[live-spec] bootstrap returned nonzero — NON-FATAL for the desktop (the web door stays up). The claudebox/live-spec is unavailable until repaired (see errors above). On fedora-desktop the DESKTOP is primary; a dev-box seed/clone failure must NOT crash it."
set -u
live=/home/core/.local/share/fedora-dev
seed=/usr/local/share/fedora-dev
mkdir -p "$(dirname "$live")"

if [ -d "$live/.git" ]; then
    echo "[live-spec] git clone already present at $live"
elif [ -f "$live/.seeded-no-git" ]; then
    echo "[live-spec] seeded-no-git state present; agent must convert to clone (see CONVERT-TO-GIT.md)"
else
    cloned=0
    for attempt in 1 2 3 4 5; do
        if git clone --depth 1 https://github.com/oso-gato/fedora-desktop "$live" 2>/dev/null; then
            cloned=1; break
        fi
        echo "[live-spec] clone attempt $attempt failed; retrying in $((attempt*5))s"
        sleep $((attempt*5))
    done
    if [ "$cloned" = 1 ]; then
        ( cd "$live" \
          && git config --local user.email "claudebox@fedora-desktop.local" \
          && git config --local user.name  "claudebox" )
        echo "[live-spec] cloned from GitHub + git identity initialized"
    else
        echo "[live-spec] GitHub unreachable after 5 attempts — seeding files only (no git)"
        mkdir -p "$live"
        cp -rT "$seed" "$live"
        date -Iseconds > "$live/.seeded-no-git"
        cat > "$live/CONVERT-TO-GIT.md" <<'NOTE'
# This live spec was seeded from the baked image because GitHub was
# unreachable at first boot.

The box-rebuild, daily-tick, and inotify-watcher all work in this state —
they read files, not git. What's BLOCKED until you convert: the
propose-and-commit cycle (`git commit` + `gh pr create`).

To convert to a real git clone, ONCE the box has internet to GitHub:

    cd ~/.local/share/fedora-dev
    rm -f .seeded-no-git CONVERT-TO-GIT.md
    git init
    git remote add origin https://github.com/oso-gato/fedora-desktop
    git fetch --depth 1 origin main
    git reset --hard origin/main
    git config --local user.email "claudebox@fedora-desktop.local"
    git config --local user.name  "claudebox"

After this the propose-and-commit flow works normally.
NOTE
    fi
fi
BOOTSTRAP

# ---- supervised: rootless podman API socket (CONTAINER_HOST target) --------
# The box's `podman` CLI talks to this socket to drive fedora-desktop's engine.
# The socket's parent dir must exist first: `podman system service` binds an
# explicit unix path and does NOT mkdir its parent.
install -d -m 0700 -o core -g core /run/user/1000/podman
runuser -u core -- podman system service --time=0 \
    unix:///run/user/1000/podman/podman.sock &
podman_sock_pid=$!

# ---- supervised: inotify watcher for in-box rebuild flag -------------------
# When Claude inside the box runs `claudebox-rebuild`, it writes a flag to
# ~/.local/state/claudebox/rebuild.request. inotifywait MONITOR mode keeps the
# inotify fd open across events. box-rebuild.sh self-serializes via flock.
runuser -u core -- bash -c '
mkdir -p /home/core/.local/state/claudebox
inotifywait -m -q -e create /home/core/.local/state/claudebox/ --format "%f" 2>/dev/null \
    | while IFS= read -r fname; do
        [ "$fname" = "rebuild.request" ] || continue
        rm -f /home/core/.local/state/claudebox/rebuild.request
        setsid nohup bash /home/core/.local/share/fedora-dev/box-rebuild.sh \
            > /home/core/.local/state/claudebox/rebuild.log 2>&1 < /dev/null &
    done
' &
watcher_pid=$!

# ---- supervised: daily-tick loop -------------------------------------------
# Wall-clock scheduling at ~04:00 local time — survives container restarts.
# claudebox-daily.sh probes the session lock: idle -> rebuild now,
# active -> drop rebuild.pending (the `claude` wrapper fires it on exit).
runuser -u core -- bash -c '
while true; do
    now=$(date +%s)
    today4=$(date -d "today 04:00" +%s)
    if [ "$today4" -gt "$now" ]; then
        next=$today4
    else
        next=$(date -d "tomorrow 04:00" +%s)
    fi
    sleep $((next - now))
    setsid nohup bash /home/core/.local/share/fedora-dev/claudebox-daily.sh \
        > /home/core/.local/state/claudebox/daily.log 2>&1 < /dev/null &
done
' &
tick_pid=$!

# ---- eager first-boot claudebox assemble (one-shot, background) -----------
# Doesn't block sshd or the desktop — you can connect immediately; `claude` will
# tail this if you try to enter the box before assemble completes.
runuser -u core -- bash -c '
    if [ ! -e /home/core/.local/state/claudebox/.assembled ]; then
        echo "[first-boot] assembling claudebox in the background..."
        bash /home/core/.local/share/fedora-dev/claudebox-assemble.sh \
            > /home/core/.local/state/claudebox/first-assemble.log 2>&1 < /dev/null \
            && echo "[first-boot] claudebox ready" \
            || echo "[first-boot] assemble FAILED — see ~/.local/state/claudebox/first-assemble.log"
    fi
' &

# ============================================================================
# KNOWLEDGE-WORK helpers: cloud-sync + vault-gitsync (run as core, supervised)
# ============================================================================
# These scripts live in the LIVE spec at ~/.local/share/fedora-dev/bin/ (baked
# into /usr/local/share/fedora-dev/bin/ as the first-boot seed). They are
# authored separately. We launch each in a respawn loop ONLY if present, and
# track a PID per helper so the watchdog can re-launch the loop if the loop
# itself dies. A missing script (or an unset enabling flag the script itself
# checks) is tolerated: the supervisor records it and moves on — the box still
# boots cleanly without cloud/vault sync configured.
LIVE_BIN=/home/core/.local/share/fedora-dev/bin

start_helper() {
    # $1 = script basename. Echoes a PID of a respawn-loop, or empty if absent.
    local name="$1" path="$LIVE_BIN/$1"
    if [ ! -f "$path" ]; then
        echo "[helper] $name not present yet — skipping (box still boots; add it via the live spec)" >&2
        return 0
    fi
    runuser -u core -- bash -c '
        export XDG_RUNTIME_DIR=/run/user/1000
        path="$1"; name="$2"
        while true; do
            bash "$path" >>"/home/core/.local/state/claudebox/${name}.log" 2>&1 || true
            echo "[helper] $name exited; respawning in 30s" \
                >>"/home/core/.local/state/claudebox/${name}.log"
            sleep 30
        done
    ' _ "$path" "$name" &
    echo $!
}

cloud_sync_pid=$(start_helper cloud-sync.sh    || true)
vault_sync_pid=$(start_helper vault-gitsync.sh || true)

echo "fedora-desktop up (web gateway: Apache Guacamole):"
echo "  web   https://<public-ip>:<WEB_PORT>/guacamole/  (TLS — the ONLY public door; strong GUAC_PW + auth-ban lockout)"
echo "  ssh   tailnet :22 (Tailscale SSH, keyless) — TAILNET-ONLY"
echo "  mosh  over the tailnet ssh — TAILNET-ONLY"
echo "  RDP   :3389  / VNC :5900  — TAILNET-ONLY (never published)"
echo "  engine $(podman --version)"

# ============================================================================
# Single watchdog: ALL critical services. Exit nonzero on any death so the
# outer --restart=always heals the whole box.
# ============================================================================
while sleep 30; do
    # Harness
    pgrep -x tailscaled         >/dev/null 2>&1 || { echo "tailscaled died";       exit 1; }
    pgrep -x sshd               >/dev/null 2>&1 || { echo "sshd died";             exit 1; }
    kill -0 "$podman_sock_pid"  2>/dev/null     || { echo "podman socket died";    exit 1; }
    kill -0 "$watcher_pid"      2>/dev/null     || { echo "rebuild watcher died";  exit 1; }
    kill -0 "$tick_pid"         2>/dev/null     || { echo "daily tick died";       exit 1; }
    # Desktop — always: the RDP session owner
    pgrep -x xrdp               >/dev/null 2>&1 || { echo "xrdp died";             exit 1; }
    pgrep -x xrdp-sesman        >/dev/null 2>&1 || { echo "xrdp-sesman died";      exit 1; }
    # Desktop — the Guacamole web door (MariaDB + guacd + Tomcat serving the .war)
    pgrep -x mariadbd       >/dev/null 2>&1 || { echo "mariadbd died";         exit 1; }
    pgrep -x guacd          >/dev/null 2>&1 || { echo "guacd died";            exit 1; }
    pgrep -f catalina       >/dev/null 2>&1 || { echo "tomcat/catalina died";  exit 1; }
    # the optional tailnet VNC mirror (x0vncserver respawn loop). Only tracked
    # when armed (RFB_PW was set).
    if [ -n "${x0vnc_pid:-}" ] && ! kill -0 "$x0vnc_pid" 2>/dev/null; then
        echo "x0vncserver respawn-loop died"; exit 1
    fi
    # Knowledge-work helpers: re-launch the respawn-loop if it died, but do NOT
    # crash the box if a helper is simply not configured (PID empty = absent).
    if [ -n "${cloud_sync_pid:-}" ] && ! kill -0 "$cloud_sync_pid" 2>/dev/null; then
        echo "[helper] cloud-sync respawn-loop died; restarting it"
        cloud_sync_pid=$(start_helper cloud-sync.sh || true)
    fi
    if [ -n "${vault_sync_pid:-}" ] && ! kill -0 "$vault_sync_pid" 2>/dev/null; then
        echo "[helper] vault-gitsync respawn-loop died; restarting it"
        vault_sync_pid=$(start_helper vault-gitsync.sh || true)
    fi
done
