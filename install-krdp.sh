#!/usr/bin/env bash
# fedora-desktop — KRDP lineage install (systemd-PID-1).
# ============================================================================
# Minimal Plasma 6 Wayland desktop + KRdp (RDP) + krfb (VNC) + the Apache Guacamole
# web door (fronting KRdp's loopback RDP) + the fedora-dev harness re-expressed as
# systemd units + the four apps. MINIMAL LEAF packages (install_weak_deps=False,
# PRINCIPLE 3): the Plasma hard-dep closure (plasma-desktop -> kio-extras -> samba-*
# for smb://; the kf6-* framework set) is the IRREDUCIBLE cost of a real KDE desktop
# (disclosed in CLAUDE.md), not bloat-by-choice. HEADLESS prerequisite (CLAUDE.md):
# no monitor/GPU/seat — kwin_wayland --virtual / krfb-virtualmonitor (software GL).
set -euxo pipefail
DNF="dnf -y --setopt=install_weak_deps=False"

# ---- WEB GATEWAY (the public browser door) — Apache Guacamole ONLY ------------
# The SOLE public desktop door is the TLS web gateway on :8443, fronting KRdp's
# loopback RDP :3389 via guacd -> HTML5. Guacamole is the ONLY web gateway: it
# authenticates the public door with a STRONG, arbitrary-length password (GUAC_PW).
# **noVNC was REMOVED fleet-wide** — the web gateway is a PUBLIC (non-tailnet) door,
# and noVNC's VNC VncAuth (only 8 chars effective) is unacceptable there. guacd/
# libguac + Fedora Tomcat + tomcat-jakartaee-migration are class-(a); only the
# guacamole.war web client is class-(c) (GPG-verified below); gnupg2 = the gpg CLI.
: "${GUAC_VERSION:?GUAC_VERSION ARG must be passed from Containerfile}"
: "${GUAC_GPG_FP:?GUAC_GPG_FP ARG must be passed from Containerfile}"
WEB_PKGS="guacd libguac-client-rdp tomcat tomcat-jakartaee-migration gnupg2"
echo ">>> fedora-desktop-krdp web gateway: Apache Guacamole (only) | pkgs='$WEB_PKGS'"
# DB-backed auth (TOTP 2FA REQUIRES a database). MariaDB + JDBC driver are Fedora
# class-(a) leaf packages; the two Guacamole extensions are class-(c) (GPG-verified
# below). On this systemd lineage MariaDB runs as mariadb.service (not supervised-bash).
DB_PKGS="mariadb-server mariadb mariadb-java-client"
echo ">>> fedora-desktop-krdp DB-backed auth: MariaDB + Guacamole jdbc/totp | pkgs='$DB_PKGS'"

# ---- vendor dnf repos (class b, gpgcheck=1) — shared with the xrdp+grd lineages
curl -fsSL https://pkgs.tailscale.com/stable/fedora/tailscale.repo -o /etc/yum.repos.d/tailscale.repo
cat > /etc/yum.repos.d/vscode.repo <<'EOF'
[code]
name=Visual Studio Code
baseurl=https://packages.microsoft.com/yumrepos/vscode
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
EOF
cat > /etc/yum.repos.d/1password.repo <<'EOF'
[1password]
name=1Password Stable Channel
baseurl=https://downloads.1password.com/linux/rpm/stable/$basearch
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://downloads.1password.com/linux/keys/1password.asc
EOF

# ============================================================================
# ONE minimal leaf transaction.
# ============================================================================
$DNF install \
    systemd systemd-pam \
    podman shadow-utils fuse-overlayfs passt nftables \
    openssh-server mosh tmux distrobox inotify-tools \
    fail2ban-server rsyslog sudo procps-ng glibc-langpack-en nano \
    tailscale \
    plasma-workspace kwin plasma-desktop konsole dolphin \
    krdp krfb kpipewire \
    pipewire pipewire-libs pipewire-pulseaudio wireplumber \
    xdg-desktop-portal xdg-desktop-portal-kde \
    xorg-x11-server-Xwayland mesa-dri-drivers mesa-libgbm openssl \
    libsecret google-noto-sans-fonts dejavu-sans-fonts \
    ${WEB_PKGS} \
    ${DB_PKGS} \
    firefox rclone \
    code 1password 1password-cli
# claude-code is DELIBERATELY NOT here (lives in the claudebox). onedrive is NOT
# here (rclone-only). Plasma's kf6-* framework set + plasma-desktop's kio-extras
# -> samba-* ride in as hard requires — disclosed in CLAUDE.md, irreducible.
# App-runtime libs the xrdp lineage installs as explicit leaves (gtk3/nss/atk/
# at-spi2-atk/cups-libs/alsa-lib/libnotify/xdg-utils/adwaita-icon-theme/dbus) ride
# in TRANSITIVELY via the Plasma closure (disclosed in CLAUDE.md). Two that do NOT
# and are listed explicitly: `libsecret` (the Secret Service CLIENT lib 1Password/
# VS Code link — kf6-kwallet, pulled by Plasma, is the org.freedesktop.secrets
# PROVIDER) and `pipewire-pulseaudio` (the Pulse shim for the ENABLE_AUDIO path).

# ---- core (uid 1000) + subuid/subgid for nested rootless podman -------------
useradd -u 1000 -m -s /bin/bash core
printf 'core:10000:55000\n' > /etc/subuid
printf 'core:10000:55000\n' > /etc/subgid
usermod -aG wheel core
setcap cap_setuid+ep /usr/bin/newuidmap || true
setcap cap_setgid+ep /usr/bin/newgidmap || true

# ---- harness as systemd units ----------------------------------------------
systemctl enable sshd.service rsyslog.service fail2ban.service tailscaled.service
# core's LINGERING user manager hosts the nested rootless podman socket + the
# daily-refreshed claudebox + the Plasma Wayland session (KRdp/krfb run inside
# it). loginctl needs a running logind (absent at build) -> write the linger
# marker directly (idempotent).
mkdir -p /var/lib/systemd/linger && touch /var/lib/systemd/linger/core

# ---- Obsidian: developer AppImage (class c), latest-at-build, sha256 logged --
OBSIDIAN_VERSION=$(curl -fsSL https://api.github.com/repos/obsidianmd/obsidian-releases/releases/latest \
    | grep -oP '"tag_name":\s*"v\K[0-9.]+')
curl -fsSL -o /tmp/Obsidian.AppImage \
    "https://github.com/obsidianmd/obsidian-releases/releases/download/v${OBSIDIAN_VERSION}/Obsidian-${OBSIDIAN_VERSION}.AppImage"
sha256sum /tmp/Obsidian.AppImage   # logged into the build output
chmod +x /tmp/Obsidian.AppImage
( cd /tmp && ./Obsidian.AppImage --appimage-extract >/dev/null )
mv /tmp/squashfs-root /opt/obsidian; chmod -R a+rX /opt/obsidian; rm /tmp/Obsidian.AppImage
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
[ -f /usr/share/applications/1password.desktop ] && \
    sed -i 's|^Exec=\(\S*\)|Exec=\1 --no-sandbox|' /usr/share/applications/1password.desktop || true

# ============================================================================
# WEB GATEWAY: Apache Guacamole web door setup
# ============================================================================
# 0700 root: bind-mount point for the runtime secrets.env (RDP_PW etc.) — keep it
# non-traversable so only root (PID 1 / the firstboot oneshot) can read it.
install -d -m 0700 /etc/fedora-desktop
# ---- Guacamole webapp: Apache .war (the lone class-c), GPG-verified ------------
curl -fsSL -o /tmp/guacamole.war \
    "https://downloads.apache.org/guacamole/${GUAC_VERSION}/binary/guacamole-${GUAC_VERSION}.war"
curl -fsSL -o /tmp/guacamole.war.asc \
    "https://downloads.apache.org/guacamole/${GUAC_VERSION}/binary/guacamole-${GUAC_VERSION}.war.asc"
curl -fsSL -o /tmp/guac-KEYS "https://downloads.apache.org/guacamole/KEYS"
export GNUPGHOME="$(mktemp -d)"; gpg --quiet --import /tmp/guac-KEYS
gpg --status-fd 1 --verify /tmp/guacamole.war.asc /tmp/guacamole.war 2>/dev/null \
    | grep -q "VALIDSIG ${GUAC_GPG_FP}" \
    || { echo "FATAL: guacamole.war GPG verify failed / not signed by pinned key ${GUAC_GPG_FP}" >&2; exit 1; }
echo "guacamole.war: GOOD signature from pinned Apache key ${GUAC_GPG_FP}"
rm -rf "$GNUPGHOME"; unset GNUPGHOME
javax2jakarta /tmp/guacamole.war /var/lib/tomcat/webapps/guacamole.war
rm -f /tmp/guacamole.war /tmp/guacamole.war.asc /tmp/guac-KEYS
# 0751 (not 0750): core (other) must TRAVERSE this tomcat-owned dir to read its
# own core-owned RDP TLS key (krdp-key.pem, 0600) — else KRdp's RDP can't start.
install -d -m 0751 -o tomcat -g tomcat /etc/guacamole /var/lib/guac-cert
printf 'guacd-hostname: 127.0.0.1\nguacd-port: 4822\n' > /etc/guacamole/guacamole.properties
# Guacamole fronts KRdp's LOOPBACK RDP (127.0.0.1:3389, security=tls). The web
# user-mapping (creds + the KRdp TLS params) is written at first boot by
# entrypoint-krdp (it needs the runtime RDP_PW/GUAC_PW). TLS :8443 connector:
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
# auth-ban defaults (5 failed attempts / 5 min -> 5-min ban) are sane; tunable via
# ban-max-invalid-attempts / ban-address-duration etc. in guacamole.properties.

# ---- DB-backed auth: guacamole-auth-jdbc (MySQL) + guacamole-auth-totp -------
# Same class-(c) GPG-verify-fail-closed pattern + helper as the xrdp install.sh. TOTP
# 2FA REQUIRES a database; entrypoint-krdp.sh provisions it via the SHARED helper
# bin/guac-db-provision.sh (single source of truth for the four must-dos).
guac_verify_tarball() {  # <basename.tar.gz> <out.tgz> — fetch + GPG-verify (fail-closed) + extract
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
guac_verify_tarball "guacamole-auth-jdbc-${GUAC_VERSION}.tar.gz" /tmp/guac-jdbc.tgz
install -m 0640 -o tomcat -g tomcat \
    "/tmp/guacamole-auth-jdbc-${GUAC_VERSION}/mysql/guacamole-auth-jdbc-mysql-${GUAC_VERSION}.jar" \
    "/etc/guacamole/extensions/guacamole-auth-jdbc-mysql-${GUAC_VERSION}.jar"
install -d -m 0755 /usr/local/share/guacamole-schema
install -m 0644 "/tmp/guacamole-auth-jdbc-${GUAC_VERSION}/mysql/schema/001-create-schema.sql" \
    /usr/local/share/guacamole-schema/001-create-schema.sql   # NEVER 002 (guacadmin backdoor)
rm -rf "/tmp/guacamole-auth-jdbc-${GUAC_VERSION}"
guac_verify_tarball "guacamole-auth-totp-${GUAC_VERSION}.tar.gz" /tmp/guac-totp.tgz
install -m 0640 -o tomcat -g tomcat \
    "/tmp/guacamole-auth-totp-${GUAC_VERSION}/guacamole-auth-totp-${GUAC_VERSION}.jar" \
    "/etc/guacamole/extensions/guacamole-auth-totp-${GUAC_VERSION}.jar"
rm -rf "/tmp/guacamole-auth-totp-${GUAC_VERSION}"
install -m 0640 -o tomcat -g tomcat /usr/lib/java/mariadb-java-client.jar /etc/guacamole/lib/mariadb-java-client.jar
# MariaDB daemon config. Named zz- so it sorts AFTER Fedora's mariadb-server.cnf and
# these settings WIN: loopback ONLY (Principle 7 — 3306 is NEVER published); name
# resolution + query-log + binlog OFF (no password in any log — Principle 5). Socket
# stays the Fedora default /var/lib/mysql/mysql.sock (datadir-local; no /run dir needed).
cat > /etc/my.cnf.d/zz-fedora-desktop.cnf <<'CNF'
[mysqld]
bind-address=127.0.0.1
skip-name-resolve
general-log=0
skip-log-bin
CNF

# MariaDB + the web door. Ordering (drop-ins): the firstboot oneshot provisions the
# DB so it runs After mariadb; Tomcat serves only After provisioning.
systemctl enable mariadb.service guacd.service tomcat.service
install -d -m 0755 /etc/systemd/system/tomcat.service.d
cat > /etc/systemd/system/tomcat.service.d/10-after-db.conf <<'EOF'
[Unit]
After=mariadb.service fedora-desktop-krdp-firstboot.service
# Requires the firstboot oneshot too: a FAILED provisioning (e.g. the guacadmin
# fail-closed exit 1) must BLOCK Tomcat from serving :8443. After= alone would not.
Requires=mariadb.service fedora-desktop-krdp-firstboot.service
EOF

# ---- first-boot config oneshot (TLS, KRdp rdp + krfb vnc, ssh keys, web door) -
# entrypoint-krdp.sh runs ONCE under systemd; it reads the runtime secrets from
# the unit Environment (run.sh.krdp / the Quadlet pass them). KRdp + krfb run in
# HEADLESS mode under core's systemd --user (no sddm) — see entrypoint-krdp.
cat > /etc/systemd/system/fedora-desktop-krdp-firstboot.service <<'EOF'
[Unit]
Description=fedora-desktop KRDP first-boot config (TLS, KRdp rdp, krfb vnc, ssh keys, DB-auth, web door)
After=systemd-user-sessions.service network-online.target mariadb.service
Wants=network-online.target
Requires=mariadb.service
[Service]
Type=oneshot
RemainAfterExit=yes
# Secrets reach this oneshot ONLY via the bind-mounted secrets.env. The dead
# /run/.containerenv import was removed (it invited the leaky `podman -e` path).
EnvironmentFile=-/etc/fedora-desktop/secrets.env
ExecStart=/usr/local/bin/entrypoint-krdp.sh
[Install]
WantedBy=multi-user.target
EOF
systemctl enable fedora-desktop-krdp-firstboot.service

# ---- bake the lineage markers (headless Plasma Wayland) ----------------------
printf 'krdp\n'           > /etc/fedora-desktop/lineage
printf 'plasma-wayland\n' > /etc/fedora-desktop/xsession

# (machine-id is handled by systemd-machine-id-setup at boot.)
$DNF clean all
rm -rf /var/cache/dnf /var/cache/libdnf5
echo ">>> fedora-desktop-krdp installed: Plasma-6 Wayland + KRdp(RDP) + krfb(VNC) + Guacamole web + apps (systemd-PID-1, headless)"
