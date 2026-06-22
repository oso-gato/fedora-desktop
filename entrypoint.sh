#!/bin/bash
# fedora-desktop PID 1 (root). MERGED supervisor:
#
#   HARNESS (from fedora-dev/entrypoint.sh):
#     * rsyslog (collects sshd auth events to /var/log/secure for fail2ban)
#     * sshd (key-only; mosh rides on it; tailscale --ssh is the keyless tailnet door)
#     * fail2ban (watches /var/log/secure, bans brute-force IPs on public :4444)
#     * tailscaled (+ tailscale up, unattended via TS_AUTHKEY or interactive banner)
#     * core's rootless podman API socket (CONTAINER_HOST target for the box)
#     * inotify watcher for in-box claudebox-rebuild flag
#     * daily-tick loop -> claudebox-daily.sh (rebuild if idle, else defer)
#     * first-boot live-clone-or-seed of the spec
#     * eager first-boot claudebox assemble (background)
#
#   DESKTOP (from fedora-xrdp/entrypoint.sh):
#     * seed core's RDP/system password (chpasswd) from RDP_PW
#     * Guacamole user-mapping.xml + TLS keystore mint
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

# ---- secrets: sourced from the bind-mounted 0600 secrets.env (run.sh writes it,
# NOT `podman -e`, so RDP_PW/GUAC_PW never land in PID 1's /proc/1/environ or
# `podman inspect`). They become SHELL vars here (never exported), are consumed
# below, then unset — parity with the grd/krdp lineages. (Back-compat: an old
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
# Desktop session needs .Xclients for xrdp. Use the variant's baked session cmd
# (/etc/fedora-desktop/xsession, set per DESKTOP_ENV at build) so a fresh home
# volume launches the RIGHT desktop (XFCE/MATE/LXQt/KDE), not always XFCE.
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
# data. A valid+provisioned user keeps USER{i}_NAME set (the user-mapping reads it);
# an invalid one is unset so it is skipped everywhere.
for _i in 1 2; do
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
  if ! id -u "$_n" >/dev/null 2>&1; then
    # CREATE non-privileged: NO -aG wheel, NO subuid/subgid row (rootless podman stays core-only).
    if useradd -m -u "$((1000 + _i))" -s /bin/bash "$_n"; then
      [ -e "/home/$_n/.bashrc" ] || cp -rT /etc/skel "/home/$_n" 2>/dev/null || true
      printf '%s\n' "$(cat /etc/fedora-desktop/xsession 2>/dev/null || echo startxfce4)" > "/home/$_n/.Xclients"
      chmod +x "/home/$_n/.Xclients"; chown -R "$_n:$_n" "/home/$_n"
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
# DESKTOP: Guacamole web-gateway config + TLS material
# ============================================================================
# ---- Guacamole auth + connection --------------------------------------------
# The web login (user core / GUAC_PW) single-signs-on into the LOCAL RDP session
# (127.0.0.1:3389, core / RDP_PW). RDP is loopback+tailnet-only; only the web port
# is public, so the RDP password never crosses the public door in the clear.
install -d -m 0750 -o tomcat -g tomcat /etc/guacamole
# Web-door audio: OFF by default — this is a low-bandwidth knowledge-work desktop and audio
# is a continuous push stream over the public web hop. ENABLE_AUDIO=true restores it.
# (Guacamole's RDP audio lever is `disable-audio`; audio is ON unless this is set. The old
# `enable-audio` param was a no-op — verified against the Guacamole manual.)
if [ "${ENABLE_AUDIO:-false}" = "true" ]; then
    RDP_AUDIO_PARAM='<!-- audio enabled (libguac-client-rdp default) -->'
else
    RDP_AUDIO_PARAM='<param name="disable-audio">true</param>'
fi
# Build the web-login -> connections map. The desktop RDP tile is ALWAYS present.
# FLEET_SSH (optional) adds clientless browser-SSH tiles to the OTHER fleet hosts,
# turning the one PUBLIC web door into a VPN-slot-free fleet bastion: the user's
# device needs NO VPN/tailnet — Safari -> :8443 -> guacd -> the desktop's
# SERVER-SIDE tailnet reaches dev/host. (Rationale: no client-VPN ZTNA, Twingate
# included, escapes iOS's single-VPN-slot rule; a clientless web door is the only
# path that does — see ZTNA-ACCESS.md.)
#   FLEET_SSH format: ';'-separated entries, each "label host [port] [user]", e.g.
#     FLEET_SSH='dev fedora-dev 22 core;vps fedora-bootstrap 22 core'
#   Auth: prefer KEYLESS Tailscale-SSH (the desktop's tailnet identity authorizes
#   the hop; the target must allow it in the tailnet SSH ACL -> no secret here).
#   Fallback: a runtime private key bind-mounted to /etc/fedora-desktop/fleet_ssh_key
#   (Principle 5 — NEVER baked into a layer); applied to every SSH tile when present.
# XML-escape user-supplied values (& < > ") so a strong GUAC_PW/RDP_PW or a fleet
# host label cannot break the generated user-mapping.xml (malformed XML = auth
# silently fails). `&` first, or the others would double-escape.
xml_escape() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'; }
GUAC_PW_X="$(xml_escape "${GUAC_PW}")"
RDP_PW_X="$(xml_escape "${RDP_PW}")"
ssh_keyparam=""
[ -r /etc/fedora-desktop/fleet_ssh_key ] && \
    ssh_keyparam="<param name=\"private-key\">$(cat /etc/fedora-desktop/fleet_ssh_key)</param>"
{
  printf '<user-mapping>\n'
  printf '  <authorize username="core" password="%s">\n' "${GUAC_PW_X}"
  cat <<RDPCONN
    <connection name="fedora-desktop">
      <protocol>rdp</protocol>
      <param name="hostname">127.0.0.1</param>
      <param name="port">3389</param>
      <param name="username">core</param>
      <param name="password">${RDP_PW_X}</param>
      <param name="ignore-cert">true</param>
      <param name="security">any</param>
      <param name="resize-method">display-update</param>
      <!-- color-depth pinned to 24 to MATCH the boot bootstrap (xrdp-sesrun -b 24):
           xrdp's session policy keys on bpp, so a depth mismatch forks a SECOND
           session and the pre-warm becomes a no-op. Pinning both to 24 makes guacd
           reuse the pre-warmed :10 session, so the web door is live before login. -->
      <param name="color-depth">24</param>
      ${RDP_AUDIO_PARAM}
    </connection>
RDPCONN
  if [ -n "${FLEET_SSH:-}" ]; then
    printf '%s\n' "$FLEET_SSH" | tr ';' '\n' | while IFS=' ' read -r f_label f_host f_port f_user _rest; do
      [ -n "$f_label" ] && [ -n "$f_host" ] || continue
      f_port="${f_port:-22}"; case "$f_port" in (*[!0-9]*|'') f_port=22 ;; esac
      cat <<SSHCONN
    <connection name="ssh-$(xml_escape "$f_label")">
      <protocol>ssh</protocol>
      <param name="hostname">$(xml_escape "$f_host")</param>
      <param name="port">${f_port}</param>
      <param name="username">$(xml_escape "${f_user:-core}")</param>
      ${ssh_keyparam}
    </connection>
SSHCONN
    done
  fi
  printf '  </authorize>\n'
  # ---- per-WORKER authorize blocks (multi-user, fenced from the bastion) -------
  # Each provisioned wiki worker gets their OWN Guacamole web login (their username +
  # password) that SSOs straight into ONLY their own loopback-RDP desktop session.
  # The Dev/VPS bastion SSH tiles live solely in core's block above, so a worker can
  # NEVER reach the fleet bastion (this is what makes "wiki workers have no dev" real
  # at the web layer). color-depth=24 == core's: xrdp keys sessions on <User,BitPerPixel>,
  # so 24 here is what lets each worker's session RESUME across devices. Passwords come
  # from secrets.env and land only in this runtime 0600 file — never an image layer.
  for _w in 1 2; do
    eval "_wn=\${USER${_w}_NAME:-}; _wp=\${USER${_w}_PW:-}"
    [ -n "$_wn" ] && [ -n "$_wp" ] || continue
    _wn_x="$(xml_escape "$_wn")"; _wp_x="$(xml_escape "$_wp")"
    cat <<WUSER
  <authorize username="${_wn_x}" password="${_wp_x}">
    <connection name="desktop-${_wn_x}">
      <protocol>rdp</protocol>
      <param name="hostname">127.0.0.1</param>
      <param name="port">3389</param>
      <param name="username">${_wn_x}</param>
      <param name="password">${_wp_x}</param>
      <param name="ignore-cert">true</param>
      <param name="security">any</param>
      <param name="resize-method">display-update</param>
      <param name="color-depth">24</param>
      ${RDP_AUDIO_PARAM}
    </connection>
  </authorize>
WUSER
  done
  printf '</user-mapping>\n'
} > /etc/guacamole/user-mapping.xml
chown tomcat:tomcat /etc/guacamole/user-mapping.xml
chmod 600 /etc/guacamole/user-mapping.xml
# guacamole.properties (guacd loopback) is written at build; auth-ban extension is
# baked at build into /etc/guacamole/extensions/ (brute-force lockout on :8443).
[ -f /etc/guacamole/guacamole.properties ] || \
    printf 'guacd-hostname: 127.0.0.1\nguacd-port: 4822\n' > /etc/guacamole/guacamole.properties
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
# HARNESS: rsyslog + sshd + fail2ban + tailscaled
# ============================================================================

# ---- rsyslog: collect sshd auth events to /var/log/secure (fail2ban reads it)
/usr/sbin/rsyslogd -n &
rsyslog_pid=$!

# ---- sshd: container :22 (host publishes public :4444 via Quadlet/run.sh) ----
/usr/sbin/sshd

# ---- fail2ban: brute-force protection on the public :4444 path --------------
# Starts after sshd so the log target exists. fail2ban tolerates a missing log
# file at startup (begins watching once it appears).
fail2ban-server -xf start &
fail2ban_pid=$!

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
# port is NOT dropped (policy accept). Own table (never collides with fail2ban's);
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
# guacd (loopback RDP client) + Tomcat serving the .war + the auth-ban extension.
# Fedora's Tomcat needs NAME=tomcat + CATALINA_BASE; JAVA_OPTS points Guacamole at
# /etc/guacamole (guacamole.properties + user-mapping.xml + extensions/auth-ban).
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
# RDP_PW is fully consumed now (chpasswd + any guacamole user-mapping). Drop it.
unset RDP_PW

# ============================================================================
# BOX supervisor: live-spec bootstrap + claudebox machinery (from fedora-dev)
# ============================================================================

# State dir for box lifecycle (session lock, rebuild flag, pending marker, logs)
install -d -m 0755 -o core -g core /home/core/.local/state/claudebox

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
runuser -u core -- bash <<'BOOTSTRAP'
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
    kill -0 "$rsyslog_pid"      2>/dev/null     || { echo "rsyslogd died";         exit 1; }
    kill -0 "$fail2ban_pid"     2>/dev/null     || { echo "fail2ban-server died";  exit 1; }
    kill -0 "$podman_sock_pid"  2>/dev/null     || { echo "podman socket died";    exit 1; }
    kill -0 "$watcher_pid"      2>/dev/null     || { echo "rebuild watcher died";  exit 1; }
    kill -0 "$tick_pid"         2>/dev/null     || { echo "daily tick died";       exit 1; }
    # Desktop — always: the RDP session owner
    pgrep -x xrdp               >/dev/null 2>&1 || { echo "xrdp died";             exit 1; }
    pgrep -x xrdp-sesman        >/dev/null 2>&1 || { echo "xrdp-sesman died";      exit 1; }
    # Desktop — the Guacamole web door (guacd + Tomcat serving the .war)
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
