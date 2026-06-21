#!/usr/bin/env bash
# fedora-desktop — KRDP lineage install (systemd-PID-1).
# ============================================================================
# Minimal Plasma 6 Wayland desktop + KRdp (RDP) + krfb (VNC) + a per-WEB_GATEWAY
# web door (Guacamole fronting KRdp's loopback RDP | noVNC fronting krfb's
# loopback VNC) + the fedora-dev harness re-expressed as systemd units + the four
# apps. MINIMAL LEAF packages (install_weak_deps=False, PRINCIPLE 3): the Plasma
# hard-dep closure (plasma-desktop -> kio-extras -> samba-* for smb://; the kf6-*
# framework set) is the IRREDUCIBLE cost of a real KDE desktop (disclosed in
# CLAUDE.md), not bloat-by-choice. HEADLESS prerequisite (CLAUDE.md): no
# monitor/GPU/seat — kwin_wayland --virtual / krfb-virtualmonitor (software GL).
set -euxo pipefail
: "${WEB_GATEWAY:=guacamole}"
DNF="dnf -y --setopt=install_weak_deps=False"

# ---- WEB GATEWAY selector (the public browser door, identical to xrdp+grd) ----
#   guacamole — guacd -> KRdp's loopback RDP :3389 -> HTML5 (RDP-grade). guacd/
#               libguac + Fedora Tomcat + jakartaee-migration are class-(a); only
#               the guacamole.war web client is class-(c) (GPG-verified below).
#   novnc     — noVNC + websockify -> krfb's loopback VNC :5900 head: ALL
#               class-(a), zero waivers. RFB_PW becomes the public web-door auth.
case "$WEB_GATEWAY" in
  guacamole)
    : "${GUAC_VERSION:?GUAC_VERSION ARG must be passed for the guacamole gateway}"
    : "${GUAC_GPG_FP:?GUAC_GPG_FP ARG must be passed for the guacamole gateway}"
    WEB_PKGS="guacd libguac-client-rdp tomcat tomcat-jakartaee-migration gnupg2" ;;
  novnc)
    WEB_PKGS="novnc python3-websockify" ;;
  *) echo "FATAL: unknown WEB_GATEWAY='$WEB_GATEWAY' (want: guacamole|novnc)" >&2; exit 1 ;;
esac
echo ">>> fedora-desktop-krdp web gateway: WEB_GATEWAY=$WEB_GATEWAY | pkgs='$WEB_PKGS'"

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
# Per-WEB_GATEWAY web door setup
# ============================================================================
# 0700 root: bind-mount point for the runtime secrets.env (RDP_PW etc.) — keep it
# non-traversable so only root (PID 1 / the firstboot oneshot) can read it.
install -d -m 0700 /etc/fedora-desktop
if [ "$WEB_GATEWAY" = "guacamole" ]; then
    # ---- Guacamole webapp: Apache .war (the lone class-c), GPG-verified --------
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
    systemctl enable guacd.service tomcat.service
else
    # ---- noVNC: a websockify SYSTEM unit serving /usr/share/novnc on TLS :8443,
    # bridging to krfb's loopback VNC :5900 head. The TLS PEM cert is minted at
    # first boot by entrypoint-krdp (core-owned). Restart=always rides out the
    # race until the cert exists + krfb's :5900 comes up under core's session.
    install -d -m 0750 -o core -g core /var/lib/guac-cert
    cat > /etc/systemd/system/fedora-desktop-novnc.service <<'EOF'
[Unit]
Description=noVNC web gateway (websockify TLS :8443 -> loopback krfb VNC :5900)
After=network-online.target
Wants=network-online.target
[Service]
User=core
Group=core
ExecStart=/usr/bin/websockify --web=/usr/share/novnc --ssl-only \
    --cert=/var/lib/guac-cert/novnc-cert.pem --key=/var/lib/guac-cert/novnc-key.pem \
    8443 127.0.0.1:5900
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
    systemctl enable fedora-desktop-novnc.service
fi

# ---- first-boot config oneshot (TLS, KRdp rdp + krfb vnc, ssh keys, web door) -
# entrypoint-krdp.sh runs ONCE under systemd; it reads the runtime secrets from
# the unit Environment (run.sh.krdp / the Quadlet pass them). KRdp + krfb run in
# HEADLESS mode under core's systemd --user (no sddm) — see entrypoint-krdp.
cat > /etc/systemd/system/fedora-desktop-krdp-firstboot.service <<'EOF'
[Unit]
Description=fedora-desktop KRDP first-boot config (TLS, KRdp rdp, krfb vnc, ssh keys, web door)
After=systemd-user-sessions.service network-online.target
Wants=network-online.target
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
printf '%s\n' "$WEB_GATEWAY" > /etc/fedora-desktop/web-gateway

# (machine-id is handled by systemd-machine-id-setup at boot.)
$DNF clean all
rm -rf /var/cache/dnf /var/cache/libdnf5
echo ">>> fedora-desktop-krdp installed: Plasma-6 Wayland + KRdp(RDP) + krfb(VNC) + ${WEB_GATEWAY} web + apps (systemd-PID-1, headless)"
