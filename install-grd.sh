#!/usr/bin/env bash
# fedora-desktop — GRD lineage install (systemd-PID-1).
# ============================================================================
# Minimal GNOME-50 Wayland desktop + GNOME Remote Desktop (RDP+VNC) + Apache
# Guacamole web door + the fedora-dev harness re-expressed as systemd units +
# the four apps. MINIMAL LEAF packages only (install_weak_deps=False, PRINCIPLE
# 3): the gnome-shell webkit/control-center closure is the IRREDUCIBLE hard-dep
# cost of a real GNOME desktop (disclosed in CLAUDE.md), not bloat-by-choice.
# HEADLESS prerequisite (CLAUDE.md): no monitor/GPU/seat — mutter --headless.
set -euxo pipefail
DNF="dnf -y --setopt=install_weak_deps=False"

# ---- WEB GATEWAY (the public browser door) — Apache Guacamole ONLY -----------
# The SOLE public desktop door is the TLS web gateway on :8443, fronting GRD's
# loopback RDP :3389 -> HTML5. Guacamole is the ONLY web gateway: it authenticates
# the public door with a STRONG, arbitrary-length password (GUAC_PW). **noVNC was
# REMOVED fleet-wide** — the web gateway is a PUBLIC (non-tailnet) door, and
# noVNC's VNC VncAuth (only 8 chars effective) is unacceptable there. guacd/libguac
# + Fedora Tomcat + tomcat-jakartaee-migration are class-(a); only the guacamole.war
# web client is class-(c) (GPG-verified below); gnupg2 = the gpg CLI for that check.
: "${GUAC_VERSION:?GUAC_VERSION ARG must be passed from Containerfile.grd}"
: "${GUAC_GPG_FP:?GUAC_GPG_FP ARG must be passed from Containerfile.grd}"
WEB_PKGS="guacd libguac-client-rdp tomcat tomcat-jakartaee-migration gnupg2"
echo ">>> fedora-desktop-grd web gateway: Apache Guacamole (only) | pkgs='$WEB_PKGS'"
# DB-backed auth (TOTP 2FA REQUIRES a database). MariaDB + JDBC driver are Fedora
# class-(a) leaf packages; the two Guacamole extensions are class-(c) (GPG-verified
# below). On this systemd lineage MariaDB runs as mariadb.service (not supervised-bash).
DB_PKGS="mariadb-server mariadb mariadb-java-client"
echo ">>> fedora-desktop-grd DB-backed auth: MariaDB + Guacamole jdbc/totp | pkgs='$DB_PKGS'"

# ---- vendor dnf repos (class b, gpgcheck=1) — shared with the xrdp lineage --
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
    gnome-shell gnome-session mutter gsettings-desktop-schemas \
    gnome-terminal nautilus \
    gnome-remote-desktop pipewire pipewire-libs wireplumber \
    xorg-x11-server-Xwayland mesa-dri-drivers mesa-libgbm openssl \
    ${WEB_PKGS} \
    ${DB_PKGS} \
    firefox rclone \
    code 1password 1password-cli
# claude-code is DELIBERATELY NOT here (lives in the claudebox). onedrive is NOT
# here (rclone-only). gnome-shell's webkitgtk6.0 + webkit2gtk4.1 + gnome-control-
# center ride in as hard requires — disclosed, irreducible.

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
# daily-refreshed claudebox + GRD's headless session. loginctl needs a running
# logind (absent at build) → write the linger marker directly (idempotent).
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
# WEB DOOR: Apache Guacamole (the only web gateway)
# ============================================================================
# ---- Guacamole webapp: Apache .war (the lone class-c), GPG-verified ----------
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
# own core-owned RDP TLS key (grd-key.pem, 0600) — else GRD's RDP can't start.
install -d -m 0751 -o tomcat -g tomcat /etc/guacamole /var/lib/guac-cert
printf 'guacd-hostname: 127.0.0.1\nguacd-port: 4822\n' > /etc/guacamole/guacamole.properties
# Guacamole fronts GRD's LOOPBACK RDP (127.0.0.1:3389, security=tls). The web
# user-mapping (creds + the GRD TLS params) is written at first boot by
# entrypoint-grd (it needs the runtime RDP_PW/GUAC_PW). TLS :8443 connector:
sed -i 's|</Service>|    <Connector port="8443" protocol="org.apache.coyote.http11.Http11NioProtocol" SSLEnabled="true" maxThreads="50" scheme="https" secure="true">\n        <SSLHostConfig><Certificate certificateKeystoreFile="/var/lib/guac-cert/keystore.p12" certificateKeystorePassword="container-local" type="RSA"/></SSLHostConfig>\n    </Connector>\n  </Service>|' /etc/tomcat/server.xml

# ---- guacamole-auth-ban: brute-force lockout on the PUBLIC :8443 door --------
# A SECOND class-(c) Apache Guacamole artifact (same pinned key), GPG-verified
# fail-closed: bans a source IP after repeated failed logins. Backend-INDEPENDENT
# (in-memory) — bans a source IP after repeated failed logins. GUACAMOLE_HOME is set
# to /etc/guacamole on grd's stock tomcat.service via the tomcat.service.d drop-in
# below (NOT JAVA_OPTS — that's the xrdp entrypoint's path), so the extension JARs in
# /etc/guacamole/extensions/ + guacamole.properties actually load. This is what makes
# a single strong GUAC_PW a
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
# 2FA REQUIRES a database; entrypoint-grd.sh provisions it via the SHARED helper
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

# MariaDB + the web door. Ordering (drop-ins, not unit edits): the firstboot oneshot
# provisions the DB so it runs After mariadb; Tomcat serves only After provisioning.
# guacd MUST bind the IPv4 loopback to match guacamole.properties' guacd-hostname:
# 127.0.0.1 (set by the SHARED bin/guac-db-provision.sh — do NOT change that; the xrdp
# lineage depends on it). Fedora's stock guacd.service runs `/usr/sbin/guacd -f $OPTS`;
# with $OPTS empty, guacd 1.6.0 defaults to 'localhost' -> ::1 on a dual-stack box, so
# Guacamole's IPv4 dial to 127.0.0.1:4822 is refused. Re-express the xrdp lineage's
# explicit `guacd -b 127.0.0.1` (entrypoint.sh) as a stock-unit drop-in.
install -d -m 0755 /etc/systemd/system/guacd.service.d
cat > /etc/systemd/system/guacd.service.d/10-bind-loopback.conf <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/sbin/guacd -f -b 127.0.0.1
EOF
systemctl enable mariadb.service guacd.service tomcat.service
install -d -m 0755 /etc/systemd/system/tomcat.service.d
cat > /etc/systemd/system/tomcat.service.d/10-after-db.conf <<'EOF'
[Unit]
After=mariadb.service fedora-desktop-grd-firstboot.service
# Requires the firstboot oneshot too: a FAILED provisioning (e.g. the guacadmin
# fail-closed exit 1) must BLOCK Tomcat from serving :8443. After= alone would not.
Requires=mariadb.service fedora-desktop-grd-firstboot.service
[Service]
# Point Guacamole at /etc/guacamole. The xrdp lineage sets this via JAVA_OPTS on its
# manual Tomcat launch (entrypoint.sh); grd uses the stock systemd tomcat.service, which
# otherwise defaults GUACAMOLE_HOME to the tomcat user's ~/.guacamole -> Guacamole loads
# NO extensions (jdbc/totp/auth-ban) + NO guacamole.properties -> no auth backend ->
# "An error has occurred" on the web page. Without this the grd web door cannot authenticate.
Environment=GUACAMOLE_HOME=/etc/guacamole
EOF

# ---- first-boot config oneshot (TLS, GRD rdp+vnc, ssh keys, claudebox) -------
# entrypoint-grd.sh runs ONCE under systemd; it reads the runtime secrets from
# the unit Environment (run.sh.grd / the Quadlet pass them). GRD itself runs in
# HEADLESS-USER mode under core's systemd --user (no gdm) — see entrypoint-grd.
cat > /etc/systemd/system/fedora-desktop-grd-firstboot.service <<'EOF'
[Unit]
Description=fedora-desktop GRD first-boot config (TLS, GRD rdp+vnc, ssh keys, DB-auth, claudebox)
After=systemd-user-sessions.service network-online.target mariadb.service
Wants=network-online.target
Requires=mariadb.service
[Service]
Type=oneshot
RemainAfterExit=yes
# Secrets reach this oneshot ONLY via the bind-mounted secrets.env (run.sh / the
# Quadlet writes it). The dead /run/.containerenv import was removed — it invited
# the `podman -e` path that leaks secrets to `podman inspect`.
EnvironmentFile=-/etc/fedora-desktop/secrets.env
ExecStart=/usr/local/bin/entrypoint-grd.sh
[Install]
WantedBy=multi-user.target
EOF
systemctl enable fedora-desktop-grd-firstboot.service

# ---- bake the lineage markers (headless GNOME-Wayland) ----------------------
# 0700 root: this dir is the bind-mount point for the runtime secrets.env (RDP_PW
# etc.) — keep it non-traversable so only root (PID 1 / the oneshot) can read it.
install -d -m 0700 /etc/fedora-desktop
printf 'grd\n'           > /etc/fedora-desktop/lineage
printf 'gnome-wayland\n' > /etc/fedora-desktop/xsession

# (machine-id is handled by systemd-machine-id-setup at boot — no dbus-uuidgen here.)
$DNF clean all
rm -rf /var/cache/dnf /var/cache/libdnf5
echo ">>> fedora-desktop-grd installed: GNOME-50 Wayland + GRD(RDP+VNC) + Guacamole web + apps (systemd-PID-1, headless)"
