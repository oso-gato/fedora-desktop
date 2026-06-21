#!/usr/bin/env bash
# fedora-desktop — KRDP lineage first-boot config (systemd oneshot, runs ONCE).
# ============================================================================
# Seeds core's password, syncs key-only ssh, mints TLS, configures KRdp (RDP) +
# krfb (VNC) + the Apache Guacamole web door, and leaves the headless Plasma
# Wayland session + the claudebox to core's lingering systemd --user manager.
# HEADLESS — no monitor/GPU/seat required.
#
# Secrets reach this oneshot via the unit's EnvironmentFile (run.sh.krdp writes
# /etc/fedora-desktop/secrets.env from the podman -e vars before this runs, OR
# podman passes them into PID 1's env which the unit imports).
#
# Required: RDP_PW (core system + KRdp RDP password) + GUAC_PW (the PUBLIC
# Guacamole web-login password — the only auth on the only public door; brute-force
# lockout is enforced by the baked guacamole-auth-ban extension). RFB_PW is
# OPTIONAL: it sets the krfb VNC password for the tailnet-only :5900 mirror; when
# unset, krfb falls back to RDP_PW (parity with the xrdp lineage's :5900 head).
set -eu
: "${RDP_PW:?RDP_PW must be set (core system + KRdp RDP password) — see run.sh.krdp}"
: "${GUAC_PW:?GUAC_PW must be set (the PUBLIC Guacamole web-login password) — see run.sh.krdp}"
# krfb VNC :5900 is the TAILNET-ONLY native VNC mirror — armed by RFB_PW when set,
# else RDP_PW (VncAuth is weak/8-char — fine since :5900 is tailnet-only + loopback).
VNC_PW="${RFB_PW:-$RDP_PW}"

# ---- core's system/KRdp password (runtime only — never in a layer) -----------
echo "core:${RDP_PW}" | chpasswd

# ---- key-only ssh: sync core's authorized_keys from github.com/oso-gato.keys -
runuser -u core -- bash -c '
    mkdir -p ~/.ssh && chmod 700 ~/.ssh
    t=$(mktemp)
    if curl -fsSL --max-time 10 https://github.com/oso-gato.keys -o "$t" && [ -s "$t" ]; then
        mv "$t" ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
    else rm -f "$t"; fi'

# ---- TLS material on the cert volume ---------------------------------------
# KRdp's RDP requires TLS (PEM cert+key); the Guacamole web door's TLS is the
# Tomcat PKCS12 keystore (minted below). All persist on /var/lib/guac-cert.
install -d -m 0751 /var/lib/guac-cert   # 0751: core traverses the tomcat-owned dir to read its RDP key
if [ ! -f /var/lib/guac-cert/krdp-cert.pem ]; then
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=fedora-desktop-krdp" \
        -keyout /var/lib/guac-cert/krdp-key.pem -out /var/lib/guac-cert/krdp-cert.pem
    chown core:core /var/lib/guac-cert/krdp-*.pem; chmod 600 /var/lib/guac-cert/krdp-key.pem
fi

# ---- Guacamole web user-mapping: core/GUAC_PW -> KRdp's LOOPBACK RDP (TLS) -----
# Web-door audio OFF by default (low-bandwidth knowledge-work desktop; audio is
# a continuous push stream). ENABLE_AUDIO=true restores it. Guacamole's RDP
# lever is `disable-audio` (audio is ON unless set) — `enable-audio` is a no-op.
if [ "${ENABLE_AUDIO:-false}" = "true" ]; then
    RDP_AUDIO_PARAM='<!-- audio enabled (libguac-client-rdp default) -->'
else
    RDP_AUDIO_PARAM='<param name="disable-audio">true</param>'
fi
cat > /etc/guacamole/user-mapping.xml <<EOF
<user-mapping>
  <authorize username="core" password="${GUAC_PW}">
    <connection name="fedora-desktop-krdp">
      <protocol>rdp</protocol>
      <param name="hostname">127.0.0.1</param>
      <param name="port">3389</param>
      <param name="username">core</param>
      <param name="password">${RDP_PW}</param>
      <param name="security">tls</param>
      <param name="ignore-cert">true</param>
      <param name="resize-method">display-update</param>
      ${RDP_AUDIO_PARAM}
    </connection>
  </authorize>
</user-mapping>
EOF
chown tomcat:tomcat /etc/guacamole/user-mapping.xml; chmod 600 /etc/guacamole/user-mapping.xml
if [ ! -f /var/lib/guac-cert/keystore.p12 ]; then
    keytool -genkeypair -alias guac -keyalg RSA -keysize 2048 -validity 3650 \
        -dname "CN=fedora-desktop-krdp" -storetype PKCS12 \
        -keystore /var/lib/guac-cert/keystore.p12 -storepass container-local
    chown tomcat:tomcat /var/lib/guac-cert/keystore.p12; chmod 640 /var/lib/guac-cert/keystore.p12
fi

# ---- KRdp (RDP) + krfb (VNC) + headless session under core's systemd --user ---
# KRdp serves :3389 (Guacamole fronts it on loopback; native RDP clients reach it
# on the tailnet) — bound 0.0.0.0 inside the container, :3389 is NEVER published
# publicly. krfb-virtualmonitor serves the native VNC :5900 (TAILNET-ONLY + loopback;
# native VNC viewers reach it on the tailnet — NEVER published publicly). BOTH
# servers attach to a RUNNING KWin Wayland session via the xdg-desktop-portal-kde
# RemoteDesktop/ScreenCast portal + kpipewire — KRdp CANNOT create a session
# itself. Unlike GNOME's GRD (turnkey `grdctl --headless`), KDE ships NO supported
# sessionless daemon, so this lineage brings up its OWN headless KWin session (the
# plasma-headless.service below). *** That headless-Plasma-Wayland bring-up is
# EXPERIMENTAL and UNPROVEN on a seatless container — the exact incantation is the
# host-validation iteration point (CLAUDE.md marks krdp EXPERIMENTAL). *** All of
# this is STAGED at first boot (persistent on the home volume); it comes UP only
# on a cgroup-v2-delegating host with core's `systemd --user` running.
#
# Config mechanism verified against KRdp/krfb upstream source (invent.kde.org):
#   * krdpserverrc [General] keys: ListenPort / Certificate / CertificateKey /
#     Users / Autostart. There is NO listen-address key and NO password key.
#   * KRdp password is NOT in the rc — the clean non-interactive path (no KWallet)
#     is the krdpserver `--username/--password` CLI flags via a systemd --user
#     ExecStart drop-in (the shipped unit's ExecStart is flag-less).
#   * krfb-virtualmonitor takes its password ONLY via `--password` (mandatory —
#     no listening socket without it); binds 0.0.0.0:5900 (no bind flag exists).

# krdpserverrc (kwriteconfig6 just writes ~/.config — no dbus/session needed).
runuser -u core -- env HOME=/home/core bash -c '
    kwriteconfig6 --file krdpserverrc --group General --key ListenPort 3389
    kwriteconfig6 --file krdpserverrc --group General --key Certificate    /var/lib/guac-cert/krdp-cert.pem
    kwriteconfig6 --file krdpserverrc --group General --key CertificateKey /var/lib/guac-cert/krdp-key.pem
    kwriteconfig6 --file krdpserverrc --group General --key Users core
    kwriteconfig6 --file krdpserverrc --group General --key Autostart true
' 2>/dev/null || echo "[krdp] krdpserverrc staging deferred (kf6-kconfig user ctx) — re-run at host-validation"

# KRdp creds via a systemd --user ExecStart drop-in (bypasses KWallet). core
# connects as core/$RDP_PW (matches the Guacamole user-mapping + native RDP
# clients). Default bind 0.0.0.0 so loopback (Guacamole) AND tailnet both reach
# :3389. The password lands in this 0600 core-owned unit file on the home volume
# (runtime secret on a volume, never an image layer — same model as the xrdp
# lineage's .vncpasswd; note: also visible in krdpserver's ps/cmdline).
KRDP_UNIT_DIR=/home/core/.config/systemd/user/app-org.kde.krdpserver.service.d
install -d -o core -g core -m 0700 "$KRDP_UNIT_DIR"
cat > "$KRDP_UNIT_DIR/override.conf" <<EOF
[Service]
ExecStart=
ExecStart=/usr/bin/krdpserver --port 3389 --username core --password ${RDP_PW} --certificate /var/lib/guac-cert/krdp-cert.pem --certificate-key /var/lib/guac-cert/krdp-key.pem
EOF
chown core:core "$KRDP_UNIT_DIR/override.conf"; chmod 600 "$KRDP_UNIT_DIR/override.conf"
# The shipped 00-krdp.preset leaves the unit DISABLED — pre-create the enable
# symlink (WantedBy=plasma-workspace.target) so core's `systemd --user` starts it
# once the Plasma session is up on the host.
KRDP_WANTS=/home/core/.config/systemd/user/plasma-workspace.target.wants
install -d -o core -g core -m 0700 "$KRDP_WANTS"
ln -sf /usr/lib/systemd/user/app-org.kde.krdpserver.service \
    "$KRDP_WANTS/app-org.kde.krdpserver.service"
chown -h core:core "$KRDP_WANTS/app-org.kde.krdpserver.service"

# ---- krfb (VNC :5900) as a systemd --user unit — the native VNC tailnet head ---
# The native VNC :5900 mirror (TAILNET-ONLY, parity with the xrdp lineage's
# x0vncserver head). VNC password = VNC_PW (RFB_PW when set, else RDP_PW), read from
# ~/.krfb-rfbpw at exec time so it is NOT baked into the unit file (it IS visible in
# krfb's ps/cmdline once running — accepted, same residual as the xrdp model).
# krfb-virtualmonitor takes the password ONLY via --password (mandatory) and binds
# 0.0.0.0:5900 (no bind flag) — :5900 is tailnet-only + loopback, NEVER published.
printf '%s' "$VNC_PW" > /home/core/.krfb-rfbpw
chown core:core /home/core/.krfb-rfbpw; chmod 600 /home/core/.krfb-rfbpw
cat > /home/core/.config/systemd/user/krfb-virtualmonitor.service <<'KRFBEOF'
[Unit]
Description=krfb-virtualmonitor headless VNC (:5900) for fedora-desktop-krdp
After=plasma-workspace.target
PartOf=plasma-workspace.target
[Service]
ExecStart=/bin/bash -c 'exec /usr/bin/krfb-virtualmonitor --password "$(cat %h/.krfb-rfbpw)" --port 5900 --resolution 1920x1080 --name fedora-desktop-krdp'
Restart=on-failure
RestartSec=5
[Install]
WantedBy=plasma-workspace.target
KRFBEOF
chown core:core /home/core/.config/systemd/user/krfb-virtualmonitor.service
ln -sf /home/core/.config/systemd/user/krfb-virtualmonitor.service \
    "$KRDP_WANTS/krfb-virtualmonitor.service"
chown -h core:core "$KRDP_WANTS/krfb-virtualmonitor.service"

# ---- headless Plasma Wayland session (EXPERIMENTAL — host-validation iteration) -
# KRdp + krfb both need a RUNNING KWin. KDE ships NO supported sessionless daemon,
# so bring up our own: kwin_wayland --virtual gives a seatless/GPU-less compositor
# + a virtual output; --xwayland lets the XWayland-falling-back Electron apps
# (Obsidian/VS Code/1Password) run. The systemd --user manager already provides
# DBUS_SESSION_BUS_ADDRESS + XDG_RUNTIME_DIR. *** This ExecStart is BEST-EFFORT and
# UNPROVEN headless — confirm/iterate on a delegating host; a fuller session may
# need plasma-session orchestration beyond plasmashell. ***
cat > /home/core/.config/systemd/user/plasma-headless.service <<'SESSEOF'
[Unit]
Description=Headless Plasma 6 Wayland session (kwin_wayland --virtual) — EXPERIMENTAL
Before=plasma-workspace.target
Wants=plasma-workspace.target
[Service]
Type=simple
Environment=XDG_SESSION_TYPE=wayland QT_QPA_PLATFORM=wayland
ExecStart=/usr/bin/kwin_wayland --virtual --width 1920 --height 1080 --xwayland /usr/bin/plasmashell
Restart=on-failure
RestartSec=5
[Install]
WantedBy=default.target
SESSEOF
chown core:core /home/core/.config/systemd/user/plasma-headless.service
SESS_WANTS=/home/core/.config/systemd/user/default.target.wants
install -d -o core -g core -m 0700 "$SESS_WANTS"
ln -sf /home/core/.config/systemd/user/plasma-headless.service "$SESS_WANTS/plasma-headless.service"
chown -h core:core "$SESS_WANTS/plasma-headless.service"
# Pull plasma-workspace.target into the boot so the krdpserver + krfb .wants fire.
ln -sf /usr/lib/systemd/user/plasma-workspace.target "$SESS_WANTS/plasma-workspace.target" 2>/dev/null || true
chown -h core:core "$SESS_WANTS/plasma-workspace.target" 2>/dev/null || true

echo "fedora-desktop-krdp configured: KRdp RDP(:3389,TLS) + krfb VNC(:5900) + Guacamole web(:8443)."
echo "Headless Plasma Wayland session (plasma-headless.service — EXPERIMENTAL) + KRdp + krfb +"
echo "the claudebox come up under core's systemd --user (linger set; HOST-VALIDATED on a"
echo "cgroup-v2-delegating host — the headless KDE-Wayland bring-up is the unproven step)."
