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
VNC_PW="${RFB_PW:-$RDP_PW}"

# ---- core's system/GRD password (runtime only — never in a layer) -----------
echo "core:${RDP_PW}" | chpasswd

# ---- key-only ssh: sync core's authorized_keys from github.com/oso-gato.keys -
runuser -u core -- bash -c '
    mkdir -p ~/.ssh && chmod 700 ~/.ssh
    t=$(mktemp)
    if curl -fsSL --max-time 10 https://github.com/oso-gato.keys -o "$t" && [ -s "$t" ]; then
        mv "$t" ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
    else rm -f "$t"; fi'

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
# ---- Guacamole web user-mapping: core/GUAC_PW -> GRD's LOOPBACK RDP (TLS) ----
# The web door rides GRD's RDP -> RDP-grade HTML5. Audio OFF by default (low-
# bandwidth knowledge-work desktop; audio is a continuous push stream);
# ENABLE_AUDIO=true restores it. Guacamole's RDP lever is `disable-audio`
# (audio ON unless set) — `enable-audio` was a no-op (verified vs the manual).
if [ "${ENABLE_AUDIO:-false}" = "true" ]; then
    RDP_AUDIO_PARAM='<!-- audio enabled (libguac-client-rdp default) -->'
else
    RDP_AUDIO_PARAM='<param name="disable-audio">true</param>'
fi
# XML-escape user-supplied values so a strong GUAC_PW/RDP_PW (& < > ") cannot break
# the generated user-mapping.xml (malformed XML = auth silently fails).
xml_escape() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'; }
GUAC_PW_X="$(xml_escape "${GUAC_PW}")"; RDP_PW_X="$(xml_escape "${RDP_PW}")"
cat > /etc/guacamole/user-mapping.xml <<EOF
<user-mapping>
  <authorize username="core" password="${GUAC_PW_X}">
    <connection name="fedora-desktop-grd">
      <protocol>rdp</protocol>
      <param name="hostname">127.0.0.1</param>
      <param name="port">3389</param>
      <param name="username">core</param>
      <param name="password">${RDP_PW_X}</param>
      <param name="security">tls</param>
      <param name="ignore-cert">true</param>
      <param name="resize-method">display-update</param>
      ${RDP_AUDIO_PARAM}
    </connection>
  </authorize>
</user-mapping>
EOF
chown tomcat:tomcat /etc/guacamole/user-mapping.xml; chmod 600 /etc/guacamole/user-mapping.xml

# ---- GRD config: enable RDP (TLS, loopback+tailnet) + VNC (tailnet) ----------
# grdctl is per-user; run as core under its (lingering) user runtime. RDP serves
# :3389 (Guacamole fronts it on loopback; native RDP clients reach it on the
# tailnet); VNC serves :5900 (tailnet). The config contract is below; bringing
# up core's `systemd --user` gnome-remote-desktop-headless.service + the headless
# GNOME-Wayland session is HOST-VALIDATED (needs cgroup-v2 delegation).
cat > /tmp/grd-setup.sh <<'GRDEOF'
set -e
export XDG_RUNTIME_DIR=/run/user/1000
grdctl --headless rdp set-tls-cert /var/lib/guac-cert/grd-cert.pem
grdctl --headless rdp set-tls-key  /var/lib/guac-cert/grd-key.pem
grdctl --headless rdp set-credentials core "$GRD_RDP_PW"
grdctl --headless rdp enable
grdctl --headless vnc set-auth-method password
grdctl --headless vnc set-password "$GRD_VNC_PW"
grdctl --headless vnc enable
GRDEOF
# RDP password = RDP_PW always; VNC password = VNC_PW (RFB_PW when set to arm the
# tailnet-only :5900 mirror, else RDP_PW). GRD VNC :5900 is TAILNET-ONLY — it is the
# native GRD VNC server, NOT noVNC.
runuser -u core -- env GRD_RDP_PW="$RDP_PW" GRD_VNC_PW="$VNC_PW" XDG_RUNTIME_DIR=/run/user/1000 \
    bash /tmp/grd-setup.sh \
    || echo "[grd] grdctl config deferred — complete on the cgroup-delegating host (needs core's running systemd --user)"
rm -f /tmp/grd-setup.sh

echo "fedora-desktop-grd configured: GRD RDP(:3389,TLS)+VNC(:5900) + Guacamole web(:8443)."
echo "Headless GNOME-Wayland session + the claudebox come up under core's systemd --user"
echo "(loginctl linger is set; host-validated on a cgroup-delegating host)."
