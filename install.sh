#!/bin/bash
# fedora-desktop base-image install.
#
# TWO HALVES, ONE LAYER:
#   PART A — the fedora-dev HARNESS, lifted VERBATIM (nested rootless podman +
#            key-only sshd + fail2ban + rsyslog + tailscale + the box-bootstrap
#            tooling). claude-code is NOT installed here — it lives in the
#            claudebox (distrobox.ini additional_packages, daily-refreshed).
#   PART B — the XFCE/xrdp DESKTOP: XFCE (X11) + xrdp/xorgxrdp +
#            guacd/Tomcat/Guacamole web door + the app set (Obsidian, VS Code,
#            Firefox, 1Password GUI+CLI, rclone).
#
# Official sources only (BUILD PRINCIPLE 2): (a) Fedora repos via dnf,
# (b) vendor RPM/dnf repo with gpgcheck=1, (c) developer AppImage sha256-logged.
# No COPR / pip / npm / curl-sh / flatpak. No passwords/keys in any layer
# (PRINCIPLE 5) — RDP_PW/GUAC_PW/RFB_PW/TS_AUTHKEY enter only at runtime.
# Sources fact-checked live 2026-06-20.
set -euxo pipefail

DNF="dnf -y --setopt=install_weak_deps=False"

# Build-time values passed from the Containerfile (PRINCIPLE 6). Fail fast if the
# guacamole.war pin + signing-key fingerprint were not threaded through — an empty
# version/fingerprint would silently fetch or "verify" the wrong artifact. (rclone
# + jakartaee-migration are Fedora class-(a) packages now — no version pin needed;
# DESKTOP_ENV carries its own default below; the web gateway is Guacamole-only.)
: "${GUAC_VERSION:?GUAC_VERSION ARG must be passed from Containerfile}"
: "${GUAC_GPG_FP:?GUAC_GPG_FP ARG must be passed from Containerfile}"

# ============================================================================
# PART A — fedora-dev HARNESS (verbatim from fedora-dev/install.sh)
# ============================================================================

# ---- vendor dnf repos -------------------------------------------------------
# Tailscale (official Fedora repo)
curl -fsSL https://pkgs.tailscale.com/stable/fedora/tailscale.repo \
    -o /etc/yum.repos.d/tailscale.repo

# ---- base packages ----------------------------------------------------------
# Tier breakdown (justified in README.md "Base Packages" table):
#   Engine + storage:  podman, shadow-utils, fuse-overlayfs, passt, nftables
#   Login + observe:   openssh-server, mosh, tmux, tailscale
#   Box bootstrap:     distrobox, inotify-tools
#   System plumbing:   sudo, procps-ng, glibc-langpack-en
#   Break-glass:       nano
#
# Everything the in-box agent uses (claude-code, gh, git, openssh-clients, podman
# CLI client, bubblewrap, socat, host-spawn, rclone) lives INSIDE claudebox —
# see distrobox.ini's additional_packages. NOT installed at the base level.
$DNF install \
    podman shadow-utils fuse-overlayfs passt nftables \
    openssh-server mosh tmux tailscale \
    distrobox inotify-tools \
    fail2ban-server rsyslog \
    sudo procps-ng glibc-langpack-en nano

# ---- defensive: restore file caps on newuidmap/newgidmap --------------------
# shadow-utils' RPM scriptlet sets these caps, BUT they can be lost in some
# podman/overlay storage configurations (security.capability xattrs don't
# always survive layer commits). Without these caps, rootless podman setup of
# a nested userns fails with "newuidmap: write to uid_map failed: Operation
# not permitted". Set them explicitly here in OUR layer + verify in entrypoint
# at runtime as a second defense.
setcap cap_setuid+ep /usr/bin/newuidmap
setcap cap_setgid+ep /usr/bin/newgidmap

# ---- user core (password set at RUNTIME only — never in a layer) -----------
# The desktop layer (PART B) seeds core's RDP/system password at runtime via
# chpasswd in the entrypoint — there is NO password in this layer.
useradd -m -u 1000 -s /bin/bash core
usermod -aG wheel core
# Inner subordinate IDs must fit inside the outer rootless 65536-ID map:
# core=1000 plus 10000..64999 < 65536.
echo "core:10000:55000" > /etc/subuid
echo "core:10000:55000" > /etc/subgid

# ---- nested rootless podman (no systemd inside) -----------------------------
install -d -m 0755 /etc/containers
cat > /etc/containers/containers.conf <<'EOF'
[containers]
# No systemd/journald runs in this image, yet podman still DEFAULTS container logs
# to the journald driver (its default whenever it detects a usable systemd journal
# dir — present here even though nothing consumes it). journald logs PLUS the
# file events backend below make `podman logs --follow`/attach unsupported — which
# made the FIRST `distrobox enter` (it follows distrobox-init's output) fail with
# "using --follow with the journald --log-driver but without the journald
# --events-backend (file) is not supported". The assemble retry loop recovered, but
# only after a failed attempt + backoff. k8s-file logs make first-enter clean.
log_driver = "k8s-file"

[engine]
cgroup_manager = "cgroupfs"
events_logger = "file"
EOF
cat > /etc/containers/storage.conf <<'EOF'
[storage]
driver = "overlay"

[storage.options.overlay]
mount_program = "/usr/bin/fuse-overlayfs"
mountopt = "nodev,fsync=0"
EOF
cat > /etc/containers/registries.conf <<'EOF'
unqualified-search-registries = ["registry.fedoraproject.org", "docker.io"]
EOF
# No systemd/PAM session manager: provide XDG_RUNTIME_DIR for rootless podman.
cat > /etc/profile.d/xdg-runtime.sh <<'EOF'
if [ "$(id -u)" = "1000" ]; then
    export XDG_RUNTIME_DIR=/run/user/1000
fi
EOF

# ---- surface the Tailscale interactive login on remote logins until the node
# is on the tailnet. A fresh state volume has no persisted identity, so the
# one-time browser join has to happen somewhere — and a freshly-deployed box has
# no shell without either the public :4444 ssh door or the tailnet. Print the
# live login URL on each interactive login until connected. Runs BEFORE the tmux
# attach below (tmux redraws the screen and would hide it); sorts first by filename.
cat > /etc/profile.d/zz-tailscale-login.sh <<'EOF'
# Show the Tailscale login URL on interactive logins while not yet connected.
# Silent once BackendState=Running (identity persists on the fedora-desktop-state
# volume, so this only nags until the one-time join is done).
case $- in *i*) ;; *) return ;; esac
[ -t 0 ] || return
command -v tailscale >/dev/null 2>&1 || return
_ts_state=$(tailscale status --json 2>/dev/null | sed -n 's/.*"BackendState": *"\([^"]*\)".*/\1/p')
if [ -n "$_ts_state" ] && [ "$_ts_state" != "Running" ]; then
    _ts_url=$(tailscale status --json 2>/dev/null | sed -n 's/.*"AuthURL": *"\([^"]*\)".*/\1/p')
    printf '\n\033[1;33m  Tailscale is not connected (state: %s).\033[0m\n' "$_ts_state"
    if [ -n "$_ts_url" ]; then
        printf '     Open this in a browser to join the tailnet (one-time):\n       \033[4m%s\033[0m\n' "$_ts_url"
    else
        printf '     No login URL yet - run:  tailscale up --ssh --hostname=fedora-desktop\n'
    fi
    printf '     Tailnet SSH works once you approve it; this notice then disappears.\n\n'
    read -rt 60 -p '     Press Enter to continue to your shell... ' _ts_ack || true
fi
unset _ts_state _ts_url _ts_ack 2>/dev/null || true
EOF

# ---- every interactive remote login lands in the persistent tmux workspace ----
# Each login gets its OWN session inside the shared "main" group: the windows
# (the work) are shared across every client, but each client's geometry and
# redraw state stay INDEPENDENT. That kills the multi-client geometry race —
# under one shared session (window-size=latest) a newly-attaching client of a
# different size forces the shared window to its geometry and paints every other
# client onto a foreign row/column grid, which is the garble seen on Prompt 3 /
# WebSSH and the initial garble on native terminals. Session groups give shared
# windows + per-session size (tmux(1): "Sessions in the same group share the
# same set of windows ... the current and previous window ... remain
# independent"). The per-connection "c<pid>" session self-destroys on disconnect
# (destroy-unattached); the work persists in the detached "main" base session.
cat > /etc/profile.d/zz-tmux-attach.sh <<'EOF'
# ssh + mosh logins each get their own session in the shared "main" group.
case $- in *i*) ;; *) return ;; esac
if [ -z "${TMUX:-}" ] && command -v tmux >/dev/null && { [ -n "${SSH_TTY:-}" ] || [ -t 0 ]; }; then
    tmux has-session -t main 2>/dev/null || tmux new-session -d -s main 2>/dev/null || true
    exec tmux new-session -t main -s "c$$" \; set-option destroy-unattached on
fi
EOF

# ---- tmux server config: per-client geometry isolation + clean repaint ----
# default-terminal: a present, 256-colour-correct TERM for programs inside tmux
# (the compiled default is the bare "screen"). window-size=smallest + aggressive-
# resize: if two clients ever view the SAME window at once, fit it to the smaller
# one so neither is painted on a foreign grid (no garble; the larger screen just
# letterboxes) — with the session-group attach above, the common one-client-per-
# window case is already full-size. client-attached/-resized -> refresh-client:
# force a full server-driven repaint on every attach AND resize, so a client that
# would not self-redraw (xterm.js / WebSSH) still receives a complete clean frame.
cat > /etc/tmux.conf <<'EOF'
set -g default-terminal "tmux-256color"
set -g window-size smallest
setw -g aggressive-resize on
set-hook -g client-attached 'refresh-client'
set-hook -g client-resized  'refresh-client'
EOF

# ---- sshd (key-only; reachable via tailnet :22 AND host-published public :4444)
# Host keys live on the root-owned tailscale state volume (NOT under core's
# home — core owns that tree and could swap keys) and are generated at runtime.
# Public ssh on port 4444 is published by the Quadlet/run.sh; container sshd
# listens on 22. Keys for core are synced from github.com/oso-gato.keys by the
# entrypoint at every container start (cached on the home volume so GitHub
# being briefly unreachable doesn't lock the operator out).
cat > /etc/ssh/sshd_config.d/99-fedora-desktop.conf <<'EOF'
PasswordAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
MaxAuthTries 3
PermitRootLogin no
AllowUsers core
HostKey /var/lib/tailscale/hostkeys/ssh_host_ed25519_key
# AUTHPRIV so rsyslog captures auth events to /var/log/secure for fail2ban.
SyslogFacility AUTHPRIV
LogLevel VERBOSE
EOF
rm -f /etc/ssh/ssh_host_*_key*   # never ship host keys in a published image

# ---- fail2ban — brute-force mitigation for the public-ssh :4444 path ----
# We install the LEAF `fail2ban-server` (see Base Packages), NOT the `fail2ban`
# metapackage: the metapackage HARD-pulls fail2ban-firewalld->firewalld +
# fail2ban-sendmail->esmtp (an unused firewall + MTA), and install_weak_deps=False
# does NOT block hard Requires. fail2ban-server is the daemon + the nftables ban action;
# it bans via `nftables[type=multiport]` (the `nft` binary; nftables is a base package). This
# image is nft-only — tailscaled programs its rules via the nftables Netlink API (no binary
# needed) and netavark defaults to nftables on Fedora 41+, so no iptables is installed.
# fail2ban watches /var/log/secure (rsyslog writes there from sshd's AUTHPRIV
# facility), bans IPs that fail too many key-auth attempts via nftables.
# Tailnet CGNAT (100.64.0.0/10) is ignoreip'd — tailnet identity is already
# authenticated by Tailscale; we don't want a misbehaving tailnet device to
# ever land on a banned-IP list.
install -d -m 0755 /etc/fail2ban/jail.d
cat > /etc/fail2ban/jail.d/sshd-fedora-desktop.local <<'EOF'
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5
backend = auto
ignoreip = 127.0.0.1/8 ::1 100.64.0.0/10
banaction = nftables[type=multiport]

[sshd]
enabled = true
port = 22
logpath = /var/log/secure
EOF

# ============================================================================
# PART B — the XFCE/xrdp DESKTOP
# ============================================================================

# ---- vendor dnf repos for the desktop app set (gpgcheck=1) -----------------
# VS Code (Microsoft yum repo)
cat > /etc/yum.repos.d/vscode.repo <<'EOF'
[code]
name=Visual Studio Code
baseurl=https://packages.microsoft.com/yumrepos/vscode
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
EOF

# 1Password (GUI + CLI) — official 1Password dnf repo, repo_gpgcheck=1 too
cat > /etc/yum.repos.d/1password.repo <<'EOF'
[1password]
name=1Password Stable Channel
baseurl=https://downloads.1password.com/linux/rpm/stable/$basearch
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://downloads.1password.com/linux/keys/1password.asc
EOF

# ---- minimal XFCE + X plumbing + Electron runtime + remote-access stack -----
# (Fedora repos, leaf packages, install_weak_deps=False — PRINCIPLE 3.)
#   Remote access:   xrdp xorgxrdp openh264 (RDP door + the Xorg :10 session);
#                    tigervnc-x11-server (hard dep of xrdp) = the x0vncserver VNC
#                    head (native VNC :5900, tailnet-only). The browser door is
#                    Apache Guacamole only (guacd/libguac/tomcat + the .war).
#                    rclone (Fedora class-a) = the cloud-sync engine.
#   XFCE desktop:    xfce4-session xfwm4 xfce4-panel xfdesktop xfce4-terminal Thunar
#   X/Electron deps: dbus-x11 xorg-x11-xauth xdpyinfo xterm mesa-dri-drivers
#                    mesa-libgbm fonts adwaita-icon-theme nss atk at-spi2-atk
#                    cups-libs gtk3 alsa-lib libnotify libsecret xdg-utils
#                    gnome-keyring openssl (keytool/TLS keystore mint)
#   Apps (Fedora):   firefox
#   Apps (vendor):   code (MS repo) 1password 1password-cli (1Password repo)
# NOTE: claude-code is DELIBERATELY NOT here (lives in claudebox). onedrive is
# DELIBERATELY NOT here (rclone-only cloud, per policy/CLAUDE.md NON-VAULT CLOUD).

# ---- DESKTOP ENVIRONMENT selector (ARG DESKTOP_ENV — the xrdp variant build) -
# Swap ONLY the DE leaf set + the X session-start; the xrdp/Guacamole/app stack
# below is shared across all xrdp variants. Minimal LEAF packages, NO @group
# (PRINCIPLE 3). Names verified against the Fedora 44 live repos (2026-06-20).
: "${DESKTOP_ENV:=xfce}"
case "$DESKTOP_ENV" in
  xfce) DE_PKGS="xfce4-session xfwm4 xfce4-panel xfdesktop xfce4-terminal Thunar xfce4-settings"; XSESSION="startxfce4" ;;
  *) echo "FATAL: unknown DESKTOP_ENV='$DESKTOP_ENV' (want: xfce — the sole xrdp DE; LXQt/KDE/MATE were dropped)" >&2; exit 1 ;;
esac
echo ">>> fedora-desktop variant: DESKTOP_ENV=$DESKTOP_ENV | DE='$DE_PKGS' | session='$XSESSION'"

# ---- WEB GATEWAY (the public browser door) — Apache Guacamole ONLY -----------
# The SOLE public desktop door is the TLS web gateway on :8443, fronting the
# xrdp-owned Xorg :10 session via guacd -> loopback RDP :3389 -> HTML5. Guacamole
# is the ONLY web gateway: it authenticates the public door with a STRONG,
# arbitrary-length password (GUAC_PW). **noVNC was REMOVED fleet-wide** — the web
# gateway is a PUBLIC (non-tailnet) door, and noVNC's VNC VncAuth (only 8 chars
# effective) is unacceptable there. guacd/libguac + Fedora Tomcat +
# tomcat-jakartaee-migration are class-(a); only the guacamole.war web client is
# class-(c) (GPG-verified below); gnupg2 = the gpg CLI for that check.
# libguac-client-ssh (class-(a)) adds OPTIONAL clientless browser-SSH tiles to the
# OTHER fleet hosts (the FLEET_SSH bastion path — see entrypoint.sh + ZTNA-ACCESS.md):
# from any device (incl. iOS on another VPN) Safari -> :8443 -> guacd -> the
# SERVER-SIDE tailnet, so no VPN slot is consumed on the client. Inert unless
# FLEET_SSH is set at runtime.
WEB_PKGS="guacd libguac-client-rdp libguac-client-ssh tomcat tomcat-jakartaee-migration gnupg2"
echo ">>> fedora-desktop web gateway: Apache Guacamole (only) | pkgs='$WEB_PKGS'"

# DB-backed auth: TOTP 2FA (Google Authenticator) REQUIRES a database — the file
# user-mapping cannot store the per-user TOTP enrollment seed. So the public door
# moves from file-auth to MariaDB-backed auth (guacamole-auth-jdbc) + the TOTP
# extension (guacamole-auth-totp), keeping auth-ban on top. MariaDB + the JDBC driver
# are Fedora class-(a) LEAF packages (verified `dnf repoquery --requires`: mariadb-server
# hard-Requires only mariadb/mariadb-common/mariadb-errmsg/coreutils/iproute/which + the
# systemd shared-lib — the SAME RPM-level systemd dep sshd/fail2ban carry in PART A, NOT
# a systemd-as-PID-1 requirement; mariadbd runs under the supervised-bash watchdog like
# every other daemon here. mysql-selinux is a conditional dep on selinux-policy-targeted,
# which this SELinux-disabled container does not run). The two Guacamole extensions are
# class-(c) (GPG-verified below, same pinned Apache key as the .war/auth-ban).
DB_PKGS="mariadb-server mariadb mariadb-java-client"
echo ">>> fedora-desktop DB-backed auth: MariaDB + Guacamole jdbc/totp | pkgs='$DB_PKGS'"

# rclone is the cloud-sync engine, now from Fedora's OWN repo (class-a) — the
# unsigned developer rpm was dropped per the zero-base check (Fedora packages it).
$DNF install \
    xrdp xorgxrdp openh264 \
    ${WEB_PKGS} \
    ${DB_PKGS} \
    ${DE_PKGS} \
    rclone \
    dbus-x11 xorg-x11-xauth xdpyinfo xterm \
    mesa-dri-drivers mesa-libgbm \
    dejavu-sans-fonts google-noto-sans-fonts adwaita-icon-theme \
    nss atk at-spi2-atk cups-libs gtk3 alsa-lib libnotify libsecret \
    xdg-utils gnome-keyring openssl acl \
    firefox \
    code 1password 1password-cli

# (rclone — the ONLY cloud-sync engine, NON-vault GDrive + OneDrive, NO abraunegg
# onedrive daemon — is installed from Fedora's own repo in the $DNF block above
# [class-a]. bin/cloud-sync.sh drives mount + bisync.)

# ---- Obsidian: developer AppImage, LATEST at build (sha256 logged) ----------
# Source class (c): the Obsidian developer ships no rpm. Resolve the latest
# release tag from the developer's GitHub releases API, fetch, log the sha256
# into the build output, extract to /opt, drop a .desktop. Primary interface to
# the vault Claude Code reads/writes.
OBSIDIAN_VERSION=$(curl -fsSL https://api.github.com/repos/obsidianmd/obsidian-releases/releases/latest \
    | grep -oP '"tag_name":\s*"v\K[0-9.]+')
echo "Resolved Obsidian latest: ${OBSIDIAN_VERSION}"
curl -fsSL -o /tmp/Obsidian.AppImage \
    "https://github.com/obsidianmd/obsidian-releases/releases/download/v${OBSIDIAN_VERSION}/Obsidian-${OBSIDIAN_VERSION}.AppImage"
sha256sum /tmp/Obsidian.AppImage   # recorded in the build log for every build
chmod +x /tmp/Obsidian.AppImage
( cd /tmp && ./Obsidian.AppImage --appimage-extract >/dev/null )
mv /tmp/squashfs-root /opt/obsidian
chmod -R a+rX /opt/obsidian
rm /tmp/Obsidian.AppImage
cat > /usr/share/applications/obsidian.desktop <<EOF
[Desktop Entry]
Name=Obsidian
Exec=/opt/obsidian/obsidian --no-sandbox %u
Icon=/opt/obsidian/obsidian.png
Type=Application
Categories=Office;
MimeType=x-scheme-handler/obsidian;
X-AppImage-Version=${OBSIDIAN_VERSION}
EOF

# ---- Electron apps need --no-sandbox in a rootless container -----------------
# Obsidian's .desktop above already carries it; fix up the vendor-shipped
# 1Password .desktop (it ships without the flag) so its launcher works too.
for app in 1password; do
    desk="/usr/share/applications/${app}.desktop"
    [ -f "$desk" ] && sed -i 's|^Exec=\(\S*\)|Exec=\1 --no-sandbox|' "$desk" || true
done

# ---- WEB GATEWAY: guacamole path — the Apache guacamole.war web client -------
# PRINCIPLE 2(c): the web client has NO class-(a)/(b) source (Fedora ships only
# the C server guacd/libguac and RETIRED guacamole-client as un-buildable Java,
# its dead.package explicitly endorsing the prebuilt .war; Apache publishes only
# the .war + source + Docker). It is the SOLE class-(c) artifact on this path:
# fetched from Apache's OWN host over TLS, GPG-VERIFIED against the PINNED Apache
# release-signing key (GUAC_GPG_FP) — fail-closed — then converted javax->jakarta
# with FEDORA'S OWN tomcat-jakartaee-migration jar (class-a) for Tomcat 10.1.
curl -fsSL -o /tmp/guacamole.war \
    "https://downloads.apache.org/guacamole/${GUAC_VERSION}/binary/guacamole-${GUAC_VERSION}.war"
curl -fsSL -o /tmp/guacamole.war.asc \
    "https://downloads.apache.org/guacamole/${GUAC_VERSION}/binary/guacamole-${GUAC_VERSION}.war.asc"
curl -fsSL -o /tmp/guac-KEYS "https://downloads.apache.org/guacamole/KEYS"
export GNUPGHOME="$(mktemp -d)"
gpg --quiet --import /tmp/guac-KEYS
gpg --status-fd 1 --verify /tmp/guacamole.war.asc /tmp/guacamole.war 2>/dev/null \
    | grep -q "VALIDSIG ${GUAC_GPG_FP}" \
    || { echo "FATAL: guacamole.war GPG verify failed / not signed by pinned key ${GUAC_GPG_FP}" >&2; exit 1; }
echo "guacamole.war: GOOD signature from pinned Apache key ${GUAC_GPG_FP}"
rm -rf "$GNUPGHOME"; unset GNUPGHOME
# Fedora's CLI wrapper sets the classpath — the packaged jakartaee-migration.jar
# is a THIN jar (java -jar fails on a missing commons-compress); javax2jakarta
# runs it with the right classpath.
javax2jakarta /tmp/guacamole.war /var/lib/tomcat/webapps/guacamole.war
rm -f /tmp/guacamole.war /tmp/guacamole.war.asc /tmp/guac-KEYS
install -d -m 0750 -o tomcat -g tomcat /etc/guacamole
# guacd loopback + TIGHTENED auth-ban (3 failed attempts -> 15-min IP ban, stricter than
# the 5/5-min default): the brute-force backstop behind spin-up.sh's strong-passphrase floor.
printf 'guacd-hostname: 127.0.0.1\nguacd-port: 4822\nban-max-invalid-attempts: 3\nban-address-duration: 900\n' > /etc/guacamole/guacamole.properties
# TLS connector :8443 for the web door (PKCS12 keystore minted at runtime; entrypoint).
sed -i 's|</Service>|    <Connector port="8443" protocol="org.apache.coyote.http11.Http11NioProtocol" SSLEnabled="true" maxThreads="50" scheme="https" secure="true">\n        <SSLHostConfig><Certificate certificateKeystoreFile="/var/lib/guac-cert/keystore.p12" certificateKeystorePassword="container-local" type="RSA"/></SSLHostConfig>\n    </Connector>\n  </Service>|' /etc/tomcat/server.xml

# ---- guacamole-auth-ban: brute-force lockout on the PUBLIC :8443 door --------
# A SECOND class-(c) Apache Guacamole artifact (same pinned key), GPG-verified
# fail-closed: bans a source IP after repeated failed logins. Backend-INDEPENDENT
# (in-memory) — works with the file user-mapping, NO database. GUACAMOLE_HOME is
# /etc/guacamole (JAVA_OPTS in entrypoint), so the extension JAR lives in
# /etc/guacamole/extensions/. This is what makes a single strong GUAC_PW a
# defensible PUBLIC door (a password alone, with no lockout, is brute-forceable).
curl -fsSL -o /tmp/guac-ban.tgz \
    "https://downloads.apache.org/guacamole/${GUAC_VERSION}/binary/guacamole-auth-ban-${GUAC_VERSION}.tar.gz"
curl -fsSL -o /tmp/guac-ban.tgz.asc \
    "https://downloads.apache.org/guacamole/${GUAC_VERSION}/binary/guacamole-auth-ban-${GUAC_VERSION}.tar.gz.asc"
curl -fsSL -o /tmp/guac-KEYS "https://downloads.apache.org/guacamole/KEYS"
export GNUPGHOME="$(mktemp -d)"; gpg --quiet --import /tmp/guac-KEYS
gpg --status-fd 1 --verify /tmp/guac-ban.tgz.asc /tmp/guac-ban.tgz 2>/dev/null \
    | grep -q "VALIDSIG ${GUAC_GPG_FP}" \
    || { echo "FATAL: guacamole-auth-ban GPG verify failed / not signed by pinned key ${GUAC_GPG_FP}" >&2; exit 1; }
echo "guacamole-auth-ban: GOOD signature from pinned Apache key ${GUAC_GPG_FP}"
rm -rf "$GNUPGHOME"; unset GNUPGHOME
install -d -m 0750 -o tomcat -g tomcat /etc/guacamole/extensions
tar -xzf /tmp/guac-ban.tgz -C /tmp
install -m 0640 -o tomcat -g tomcat \
    "/tmp/guacamole-auth-ban-${GUAC_VERSION}/guacamole-auth-ban-${GUAC_VERSION}.jar" \
    "/etc/guacamole/extensions/guacamole-auth-ban-${GUAC_VERSION}.jar"
rm -rf /tmp/guac-ban.tgz /tmp/guac-ban.tgz.asc /tmp/guac-KEYS "/tmp/guacamole-auth-ban-${GUAC_VERSION}"
# auth-ban is TIGHTENED above (3 attempts / 15-min ban, vs the 5/5-min default) in
# guacamole.properties — the brute-force backstop behind spin-up.sh's passphrase floor.

# ---- DB-backed auth: guacamole-auth-jdbc (MySQL) + guacamole-auth-totp -------
# TOTP 2FA stores a per-user enrollment seed, which the file user-mapping cannot
# hold — so the public door is DB-backed (MariaDB) with the TOTP extension layered
# on. BOTH extensions are class-(c) Apache Guacamole artifacts from the SAME pinned-key
# channel as the .war/auth-ban: fetched over TLS from Apache's own host, GPG-verified
# against GUAC_GPG_FP, FAIL-CLOSED. The identical fetch+verify+extract pattern as the
# .war/auth-ban, factored here into one helper (jdbc + totp both use it).
guac_verify_tarball() {  # <basename.tar.gz> <out.tgz> — fetch + GPG-verify (fail-closed) + extract to /tmp
    _bn="$1"; _out="$2"
    curl -fsSL -o "$_out"        "https://downloads.apache.org/guacamole/${GUAC_VERSION}/binary/${_bn}"
    curl -fsSL -o "${_out}.asc"  "https://downloads.apache.org/guacamole/${GUAC_VERSION}/binary/${_bn}.asc"
    curl -fsSL -o /tmp/guac-KEYS "https://downloads.apache.org/guacamole/KEYS"
    GNUPGHOME="$(mktemp -d)"; export GNUPGHOME; gpg --quiet --import /tmp/guac-KEYS
    gpg --status-fd 1 --verify "${_out}.asc" "$_out" 2>/dev/null \
        | grep -q "VALIDSIG ${GUAC_GPG_FP}" \
        || { echo "FATAL: ${_bn} GPG verify failed / not signed by pinned key ${GUAC_GPG_FP}" >&2; exit 1; }
    echo "${_bn}: GOOD signature from pinned Apache key ${GUAC_GPG_FP}"
    rm -rf "$GNUPGHOME"; unset GNUPGHOME
    tar -xzf "$_out" -C /tmp
    rm -f "$_out" "${_out}.asc" /tmp/guac-KEYS
}
install -d -m 0750 -o tomcat -g tomcat /etc/guacamole/extensions /etc/guacamole/lib

# guacamole-auth-jdbc: install ONLY the MySQL extension jar, and STASH the 001 schema
# for the entrypoint to load at first boot. We DELIBERATELY do NOT ship (and the
# entrypoint never loads) 002-create-admin-user.sql — it creates the guacadmin/guacadmin
# default admin, a public backdoor. (The entrypoint ALSO deletes any guacadmin entity
# and fails closed if one survives — belt-and-suspenders.)
guac_verify_tarball "guacamole-auth-jdbc-${GUAC_VERSION}.tar.gz" /tmp/guac-jdbc.tgz
install -m 0640 -o tomcat -g tomcat \
    "/tmp/guacamole-auth-jdbc-${GUAC_VERSION}/mysql/guacamole-auth-jdbc-mysql-${GUAC_VERSION}.jar" \
    "/etc/guacamole/extensions/guacamole-auth-jdbc-mysql-${GUAC_VERSION}.jar"
install -d -m 0755 /usr/local/share/guacamole-schema
install -m 0644 \
    "/tmp/guacamole-auth-jdbc-${GUAC_VERSION}/mysql/schema/001-create-schema.sql" \
    /usr/local/share/guacamole-schema/001-create-schema.sql
rm -rf "/tmp/guacamole-auth-jdbc-${GUAC_VERSION}"
echo "guacamole-auth-jdbc-mysql: extension installed; 001 schema stashed (002 admin-user intentionally OMITTED)"

# guacamole-auth-totp: the 2FA extension (TOTP / Google Authenticator). On first login
# Guacamole shows the seed as a QR; the per-user secret is stored base32 in the DB
# (guacamole_user_attribute, attribute_name guac-totp-key-*). No pre-provisioning.
guac_verify_tarball "guacamole-auth-totp-${GUAC_VERSION}.tar.gz" /tmp/guac-totp.tgz
install -m 0640 -o tomcat -g tomcat \
    "/tmp/guacamole-auth-totp-${GUAC_VERSION}/guacamole-auth-totp-${GUAC_VERSION}.jar" \
    "/etc/guacamole/extensions/guacamole-auth-totp-${GUAC_VERSION}.jar"
rm -rf "/tmp/guacamole-auth-totp-${GUAC_VERSION}"
echo "guacamole-auth-totp: 2FA extension installed"

# JDBC driver: Guacamole loads JDBC drivers from $GUACAMOLE_HOME/lib (=/etc/guacamole/lib).
# mariadb-java-client (class-(a)) installs its jar at the rpm-owned /usr/lib/java path;
# `install` fails the build (fail-closed) if that path is absent.
install -m 0640 -o tomcat -g tomcat \
    /usr/lib/java/mariadb-java-client.jar \
    /etc/guacamole/lib/mariadb-java-client.jar
echo "mariadb JDBC driver staged into /etc/guacamole/lib"

# MariaDB daemon config. Named zz- so it sorts AFTER Fedora's mariadb-server.cnf and
# wins: loopback ONLY (Principle 7 — 3306 is NEVER published); name resolution +
# query-log + binlog OFF (no password in any log — Principle 5). Socket stays the
# Fedora default /var/lib/mysql/mysql.sock. (The xrdp entrypoint also passes these as
# explicit mariadbd flags; this file gives the same defaults to any implicit client.)
cat > /etc/my.cnf.d/zz-fedora-desktop.cnf <<'CNF'
[mysqld]
bind-address=127.0.0.1
skip-name-resolve
general-log=0
skip-log-bin
CNF

# ---- xrdp: XFCE session, session persistence, GFX H.264-first ---------------
# Bake the variant's X session-start so the entrypoint's first-boot fallback (on a
# fresh home volume) launches the RIGHT desktop, not always XFCE.
mkdir -p /etc/fedora-desktop
printf '%s\n' "$XSESSION" > /etc/fedora-desktop/xsession
# /etc/fedora-desktop/xsession is the SOLE source of truth for the X session-start.
# /home/core is a declared VOLUME, so a build-time ~/.Xclients write is shadowed by
# a fresh named volume at runtime; entrypoint.sh (re)writes ~/.Xclients from this
# file on first boot (chmod +x + chown included). Do NOT re-add a build-time
# .Xclients write here — it is dead on any volume-backed deploy and risks
# desyncing from the DESKTOP_ENV selector.
# KillDisconnected=false: keep the session alive across client disconnects — the
# whole point of a roaming workstation (reconnect over RDP/web and your apps are
# still open). Mirrored in entrypoint's notes.
sed -i 's/^#\?KillDisconnected=.*/KillDisconnected=false/' /etc/xrdp/sesman.ini
# max_bpp=24: cap color depth so even a NATIVE RDP client (mstsc/FreeRDP over the
# tailnet) negotiating 16/32 bpp is forced to 24. xrdp keys each user's session on
# <User,BitPerPixel> (sesman Policy=Default), so a depth mismatch forks a SECOND
# session and breaks the cross-device / multi-user RESUME guarantee. The Guacamole
# path already pins color-depth=24; this fences the native-RDP path to match.
sed -i 's/^#\?max_bpp=.*/max_bpp=24/' /etc/xrdp/xrdp.ini
# Activate the Xorg/xorgxrdp backend. Fedora ships /etc/xrdp/xrdp.ini with the [Xorg]
# connection section COMMENTED OUT and only [Xvnc] active, so a stock install silently
# serves the Xvnc (libvnc) backend — NOT the xorgxrdp Xorg :10 session this lineage is built
# for, and NOT what the gfx.toml H.264 tuning, openh264, or the `xrdp-sesrun -t Xorg` pre-warm
# assume. (xrdp-sesrun reads sesman.ini, where [Xorg] IS enabled, so the pre-warm DOES create
# an Xorg session — but with [Xorg] commented here, incoming Guacamole/RDP connections take the
# only-active [Xvnc] section and fork a SEPARATE Xvnc session, orphaning the pre-warm and giving
# users Xvnc.) Uncomment the [Xorg] stanza (through code=20) and pin autorun=Xorg so EVERY
# incoming connection attaches to the xorgxrdp backend. HOST-VALIDATED: core+u1 each paint
# their own /usr/libexec/Xorg :1x session (validation/xrdp-headless-spike.sh RDP_BACKEND=xorg;
# Xorg procs=2 / Xvnc procs=0).
sed -i '/^#\[Xorg\]/,/^#code=/{s/^#//}' /etc/xrdp/xrdp.ini
sed -i 's/^autorun=.*/autorun=Xorg/' /etc/xrdp/xrdp.ini
if [ -f /etc/xrdp/gfx.toml ]; then
    sed -i 's/^order *=.*/order = [ "H.264", "RFX" ]/' /etc/xrdp/gfx.toml
    sed -i 's/^h264_encoder *=.*/h264_encoder = "OpenH264"/' /etc/xrdp/gfx.toml || true
fi

# ---- XFCE runtime tuning for the headless, no-GPU, still-image web door ------
# Baked as /etc/xdg xfconf DEFAULTS (apply on a fresh /home volume; a user can still
# override). The load-bearing lever is COMPOSITING OFF: xfwm4 already auto-disables it
# under the llvmpipe software renderer, but we PIN it so it is deterministic across
# xfwm4 versions — no XRender shadows/transparency => no full-frame readback churn for
# guacd to re-encode over the intra-frame still-image door. Plus a flat, animation-free
# theme and a SOLID desktop colour (no photographic wallpaper => smaller initial
# dirty-region encode on connect). XFCE is GTK3, so it rides the already-installed GTK
# stack (Firefox/Electron) — no second toolkit resident at runtime (vs LXQt's Qt6/KF6).
# The XFCE PolicyKit agent (xfce-polkit — a hard-dep of xfce4-session, not directly chosen) is
# DEAD in this lineage: the no-systemd xrdp harness runs no polkitd / system D-Bus, so it can
# only autostart, fail to register an authentication agent, and pop an "XFCE PolicyKit Agent"
# error dialog at every login. polkit privilege-escalation is non-functional BY DESIGN here
# (see the desktop note above), so mask the dead autostart for ALL users.
if [ -f /etc/xdg/autostart/xfce-polkit.desktop ]; then
  printf 'Hidden=true\n' >> /etc/xdg/autostart/xfce-polkit.desktop
fi
XFCONF=/etc/xdg/xfce4/xfconf/xfce-perchannel-xml
install -d -m 0755 "$XFCONF"
cat > "$XFCONF/xfwm4.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfwm4" version="1.0">
  <property name="general" type="empty">
    <property name="use_compositing" type="bool" value="false"/>
  </property>
</channel>
XML
cat > "$XFCONF/xsettings.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xsettings" version="1.0">
  <property name="Net" type="empty">
    <property name="ThemeName" type="string" value="Adwaita"/>
    <property name="IconThemeName" type="string" value="Adwaita"/>
    <property name="EnableEventSounds" type="bool" value="false"/>
  </property>
  <property name="Gtk" type="empty">
    <property name="EnableAnimations" type="bool" value="false"/>
  </property>
</channel>
XML
# Solid desktop colour, no wallpaper image. NOTE: xfdesktop keys the backdrop on the
# RANDR monitor name; under xorgxrdp this is commonly "monitor0" but HOST-VALIDATE — if
# the live output name differs, the solid colour is a trivial per-user setting. The
# compositing-off above is monitor-INDEPENDENT and is the real runtime lever.
cat > "$XFCONF/xfce4-desktop.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-desktop" version="1.0">
  <property name="backdrop" type="empty">
    <property name="single-workspace-mode" type="bool" value="true"/>
    <property name="single-workspace-number" type="int" value="0"/>
    <property name="screen0" type="empty">
      <property name="monitor0" type="empty">
        <property name="workspace0" type="empty">
          <property name="image-style" type="int" value="0"/>
          <property name="color-style" type="int" value="0"/>
          <property name="rgba1" type="array">
            <value type="double" value="0.16"/>
            <value type="double" value="0.18"/>
            <value type="double" value="0.22"/>
            <value type="double" value="1.0"/>
          </property>
        </property>
      </property>
    </property>
  </property>
</channel>
XML

dbus-uuidgen --ensure
dnf clean all
rm -rf /var/cache/dnf /var/cache/libdnf5
