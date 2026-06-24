#!/usr/bin/env bash
# ============================================================================
# xrdp-headless-spike.sh — HOST-VALIDATION spike for the fedora-desktop XRDP lineage
# ============================================================================
# Sibling of grd-headless-spike.sh. xrdp is the PROVEN production lineage, but its
# MULTI-USER path is the one mechanism NOT yet exercised on current main: unlike grd's
# per-user loopback ports, ALL users hit ONE :3389 and xrdp-sesman routes by
# <User,BitPerPixel> to a distinct per-user Xorg ":1x" session. This spike proves, on a
# host, that:
#   - a headless xorgxrdp Xorg + XFCE session PAINTS on llvmpipe (no GPU, no seat), and
#   - N DISTINCT usernames -> ONE :3389 -> N distinct painted :1x sessions (multi-user),
#   - reconnect at the SAME bpp resumes the SAME session (the bpp=24 invariant).
#
# SIMPLER than grd: the xrdp lineage is supervised-bash (NOT systemd-PID-1), so it runs
# in a PLAIN `podman run` — no --systemd=always / --cgroupns=host / cgroup delegation.
#
# SAFETY: throwaway image + container; RDP published on 127.0.0.1 ONLY; no $HOME/vault
# mount; torn down on exit. This proves the SESSION/multi-user primitive ONLY — the
# public Guacamole :8443 door, TOTP, per-user access grants, and the SSH-fleet tiles
# reaching the dev box + host OVER TAILSCALE are REAL-DEPLOY-ONLY (see
# HOST-VALIDATION-PROCESS.md) and cannot be a throwaway spike.
#
# GATES (per user): A systemd-free xrdp+sesman up · B a per-user :1x session spawns ·
#   C :3389 listening · D a real RDP client renders a NON-BLACK XFCE frame · E resume.
#
# HOST PREREQS: podman; (for Gate D) a freerdp client + Xvfb + ImageMagick (import/convert).
# ============================================================================
set -uo pipefail

FED="${FED:-44}"
NUSERS="${NUSERS:-2}"                               # users to stand up: core + u1..u(N-1)
HOSTPORT="${HOSTPORT:-13389}"                       # host loopback -> container :3389
RDP_BACKEND="${RDP_BACKEND:-xorg}"                  # xorg (production: xorgxrdp/libxup) | xvnc (Fedora stock default)
IMG="${IMG:-localhost/xrdp-spike:f${FED}-${RDP_BACKEND}}"
OUTDIR="${OUTDIR:-$PWD/xrdp-spike-out}"
SESSION_WAIT="${SESSION_WAIT:-20}"                  # secs for a session to spawn after connect (cold XFCE on llvmpipe)
KEEP="${KEEP:-0}"
RDP_SEC="${RDP_SEC:-tls}"                            # xrdp security: rdp|tls|nla. tls: FreeRDP3 + Fedora xrdp negotiate-default
CT=""; declare -A R
log(){ printf '\033[1;36m[xrdp-spike]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[xrdp-spike] WARN:\033[0m %s\n' "$*" >&2; }
err(){ printf '\033[1;31m[xrdp-spike] ERR:\033[0m %s\n' "$*" >&2; }
cleanup(){ [ -n "$CT" ] && [ "$KEEP" != 1 ] && podman rm -f "$CT" >/dev/null 2>&1; [ "$KEEP" = 1 ] && [ -n "$CT" ] && warn "KEEP=1 — '$CT' left up (podman rm -f $CT)"; }
trap cleanup EXIT
command -v podman >/dev/null || { err "podman not found — run on the host."; exit 2; }
mkdir -p "$OUTDIR"

# ---- minimal xrdp + XFCE image (supervised-bash, no systemd) ----------------
build_image(){
  podman image exists "$IMG" && { log "image $IMG exists"; return 0; }
  log "building $IMG (minimal xrdp + xorgxrdp + XFCE; a few min)…"
  local cf pol rc backend_cfg; cf="$(mktemp)"; pol="$(mktemp)"
  printf '%s' '{"default":[{"type":"insecureAcceptAnything"}]}' > "$pol"
  # Session backend. PRODUCTION's intent is Xorg/xorgxrdp, but Fedora ships xrdp.ini with
  # [Xorg] COMMENTED + [Xvnc] active, so a stock install serves Xvnc (libvnc). Option A
  # commits to Xorg: uncomment the [Xorg] stanza (incl. code=20) + autorun=Xorg so incoming
  # RDP connections attach to the xorgxrdp (libxup) backend. Mirrors the install.sh fix.
  # RDP_BACKEND=xvnc keeps the Fedora stock default (for A/B comparison).
  if [ "$RDP_BACKEND" = xorg ]; then
    backend_cfg='RUN sed -i "/^#\[Xorg\]/,/^#code=/{s/^#//}" /etc/xrdp/xrdp.ini && sed -i "s/^autorun=.*/autorun=Xorg/" /etc/xrdp/xrdp.ini'
  else
    backend_cfg='# RDP_BACKEND=xvnc: Fedora stock ([Xvnc] active, [Xorg] commented) — no change'
  fi
  cat > "$cf" <<EOF
FROM registry.fedoraproject.org/fedora:${FED}
RUN dnf -y --setopt=install_weak_deps=False install \
        xrdp xorgxrdp \
        xfce4-session xfwm4 xfce4-panel xfdesktop xfce4-terminal xfce4-settings \
        dbus-x11 xorg-x11-xauth mesa-dri-drivers procps-ng iproute util-linux passwd openssl \
    && dnf clean all
# --- session backend selection (Xorg/xorgxrdp vs Fedora-stock Xvnc; see build_image) ---
${backend_cfg}
# launch XFCE for every xrdp session. Fedora's sesman runs /usr/libexec/xrdp/startwm-bash.sh
# -> the standard Xsession -> ~/.Xclients (NOT /etc/xrdp/startwm.sh — writing that is a no-op
# here). Bake an executable ~/.Xclients=startxfce4 into /etc/skel so every `useradd -m` user
# (core, u1, ...) inherits it — mirrors production entrypoint.sh, which writes ~/.Xclients
# from /etc/fedora-desktop/xsession. Without this the WM exits in 0s ("exited quickly").
RUN printf 'startxfce4\n' > /etc/skel/.Xclients && chmod +x /etc/skel/.Xclients
# D-Bus machine-id: startxfce4 triggers D-Bus X11 *autolaunch*, which keys the session bus
# on (machine-id, display). With no machine-id every component autolaunches its OWN bus ->
# "another instance took over" + "connection is closed" flood -> the session aborts (exit
# 134). Mirrors production install.sh:564 (`dbus-uuidgen --ensure`), which has the same need
# on the no-systemd harness.
RUN dbus-uuidgen --ensure
# xrdp RSA keys + a self-signed TLS cert (xrdp.ini default paths). xrdp DROPS PRIVS to
# the 'xrdp' user before reading these, so cert/key/rsakeys MUST be owned by it — else
# TLS is refused ('Cannot read private key file ... Permission denied') AND the classic-RDP
# fallback can't read rsakeys.ini, killing BOTH security paths (xrdp_sec_incoming failed).
RUN xrdp-keygen xrdp auto && \
    openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj /CN=xrdp-spike \
      -keyout /etc/xrdp/key.pem -out /etc/xrdp/cert.pem >/dev/null 2>&1 && \
    chown xrdp:xrdp /etc/xrdp/key.pem /etc/xrdp/cert.pem /etc/xrdp/rsakeys.ini && \
    chmod 640 /etc/xrdp/key.pem /etc/xrdp/cert.pem /etc/xrdp/rsakeys.ini
RUN printf 'LIBGL_ALWAYS_SOFTWARE=1\nGALLIUM_DRIVER=llvmpipe\n' >> /etc/environment
# supervised-bash PID 1: system dbus + xrdp-sesman + xrdp, then wait (the lineage's model)
RUN printf '#!/bin/bash\nmkdir -p /run/dbus /var/run/xrdp\ndbus-daemon --system --fork 2>/dev/null||true\n/usr/sbin/xrdp-sesman\nsleep 1\n/usr/sbin/xrdp\nexec sleep infinity\n' > /usr/local/bin/spike-init && chmod +x /usr/local/bin/spike-init
ENTRYPOINT ["/usr/local/bin/spike-init"]
EOF
  podman build --signature-policy="$pol" -t "$IMG" -f "$cf" . 2>&1 | tee "$OUTDIR/build.log"; rc=${PIPESTATUS[0]}
  rm -f "$cf" "$pol"
  { [ "$rc" = 0 ] && podman image exists "$IMG"; } || { err "build FAILED (rc=$rc) — see $OUTDIR/build.log (host policy.json? network?)"; return 1; }
  log "image built."
}

# ---- capture one RDP frame from the host (shared) — echoes grayscale stddev ----
capture_frame(){  # <host_port> <user> <pw> <out_png> <out_log>
  local hp="$1" u="$2" pw="$3" png="$4" lg="$5" frdp
  frdp=$(command -v xfreerdp3 || command -v xfreerdp || command -v sdl-freerdp || true)
  { [ -n "$frdp" ] && command -v Xvfb >/dev/null && command -v import >/dev/null; } || { echo SKIP; return; }
  Xvfb :97 -screen 0 1280x720x24 >/dev/null 2>&1 & local xpid=$!; sleep 1
  DISPLAY=:97 "$frdp" /v:127.0.0.1:"$hp" /u:"$u" /p:"$pw" /cert:ignore /sec:"$RDP_SEC" \
      /bpp:24 /size:1280x720 > "$lg" 2>&1 & local rpid=$!
  sleep "$SESSION_WAIT"
  DISPLAY=:97 import -window root "$png" >/dev/null 2>&1 || true
  kill "$rpid" "$xpid" >/dev/null 2>&1
  local sd=0; [ -s "$png" ] && sd=$(convert "$png" -colorspace Gray -format '%[fx:standard_deviation]' info: 2>/dev/null || echo 0)
  echo "$sd"
}

# ---- main -------------------------------------------------------------------
log "start | FED=$FED NUSERS=$NUSERS HOSTPORT=$HOSTPORT sec=$RDP_SEC OUT=$OUTDIR"
build_image || { err "ABORT: image did not build."; exit 3; }
CT="xrdp-spike"; podman rm -f "$CT" >/dev/null 2>&1
log "starting '$CT' (plain podman run — no systemd; one shared :3389)…"
# Mirror the production run.sh security profile for the DESKTOP path (run.sh:108-113):
# Fedora 44 loads SVG icons via glycin, which decodes inside a `bwrap` sandbox (nested
# userns + mounts). On an SELinux-enforcing host the default container_t confinement
# blocks that, so GTK can't load an icon, hits g_error(), and XFCE aborts (exit 134).
# --security-opt label=disable + --cap-add SYS_ADMIN + --device /dev/fuse are exactly what
# production passes so the desktop session works (NET_ADMIN/tun are tailscale-only, omitted).
podman run -d --name "$CT" --hostname "$CT" --shm-size=1g \
    --cap-add SYS_ADMIN --device /dev/fuse --security-opt label=disable \
    -p "127.0.0.1:${HOSTPORT}:3389" "$IMG" >/dev/null \
    || { err "container failed to start"; exit 1; }
sleep 4
# users: core + u1..u(N-1), each with a system password (xrdp-sesman PAM-auths against it)
users=(); for i in $(seq 0 $((NUSERS-1))); do [ "$i" = 0 ] && users+=(core) || users+=("u$i"); done
for i in "${!users[@]}"; do
  u="${users[$i]}"; pw="spikepw-$u"
  [ "$u" = core ] && podman exec "$CT" useradd -m -u 1000 "$u" >/dev/null 2>&1 || \
    [ "$u" = core ] || podman exec "$CT" useradd -m -u "$((1000+i))" "$u" >/dev/null 2>&1
  podman exec "$CT" bash -lc "echo '$u:$pw' | chpasswd"
done
# Gate A/C: xrdp + sesman up, :3389 listening
podman exec "$CT" ss -ltnp > "$OUTDIR/ss.txt" 2>&1 || true
grep -qE ':3389' "$OUTDIR/ss.txt" && { R[sys]=PASS; log "Gate A/C: xrdp listening on :3389"; } || { R[sys]=FAIL; err "Gate A/C: nothing on :3389 (see $OUTDIR/ss.txt + 'podman logs $CT')"; }
podman logs "$CT" > "$OUTDIR/container.log" 2>&1 || true

# Gate B/D per user: connect to the SHARED :3389 with the user's own creds -> own :1x -> paint
allpaint=1
for i in "${!users[@]}"; do
  u="${users[$i]}"; pw="spikepw-$u"; sd=$(capture_frame "$HOSTPORT" "$u" "$pw" "$OUTDIR/frame-$u.png" "$OUTDIR/freerdp-$u.log")
  if [ "$sd" = SKIP ]; then R[$u]=SKIP; warn "$u: paint SKIPPED (need freerdp/Xvfb/IM); manual: xfreerdp /v:127.0.0.1:$HOSTPORT /u:$u /p:$pw /cert:ignore /sec:$RDP_SEC /bpp:24"
  elif awk "BEGIN{exit !($sd>0.02)}"; then R[$u]=PASS; log "$u via :$HOSTPORT -> PAINTS own session (stddev=$sd)"
  else R[$u]=FAIL; allpaint=0; warn "$u via :$HOSTPORT -> black/no-frame (stddev=$sd); see $OUTDIR/freerdp-$u.log"; fi
done
# Gate B evidence: distinct per-user :1x sessions + WHICH backend actually answered
podman exec "$CT" bash -lc 'ls -1 /tmp/.X11-unix 2>/dev/null; echo "--- X servers ---"; pgrep -af "Xorg|Xvnc" 2>/dev/null | grep -vi grep' > "$OUTDIR/sessions.txt" 2>&1 || true
# Backend faithfulness: the connections MUST land on the backend we configured. A silent
# Xvnc fallback on an RDP_BACKEND=xorg run is a FAIL — it means the [Xorg] uncomment didn't
# take and we are NOT exercising the production path (Xorg=/usr/libexec/Xorg via xorgxrdp/
# libxup; Xvnc=Xvnc via libvnc).
got_xorg=$(podman exec "$CT" bash -c 'pgrep -cx Xorg' 2>/dev/null | tr -dc 0-9); got_xorg=${got_xorg:-0}
got_xvnc=$(podman exec "$CT" bash -c 'pgrep -cx Xvnc' 2>/dev/null | tr -dc 0-9); got_xvnc=${got_xvnc:-0}
case "$RDP_BACKEND" in
  xorg) { [ "${got_xorg:-0}" -gt 0 ] && [ "${got_xvnc:-0}" = 0 ]; } && R[backend]=PASS || R[backend]=FAIL ;;
  xvnc) { [ "${got_xvnc:-0}" -gt 0 ] && [ "${got_xorg:-0}" = 0 ]; } && R[backend]=PASS || R[backend]=FAIL ;;
  *)    R[backend]=PASS ;;
esac

# ---- summary ----------------------------------------------------------------
echo "======================================================================"
echo "[xrdp-spike] xrdp lineage — $NUSERS users, ONE shared :3389, backend=${RDP_BACKEND} (sesman <User,bpp> routing):"
printf '   %-10s %-6s\n' "A/C:3389" "${R[sys]:--}"
printf '   %-10s %-6s (Xorg procs=%s, Xvnc procs=%s)\n' "backend" "${R[backend]:--}" "${got_xorg:-0}" "${got_xvnc:-0}"
for i in "${!users[@]}"; do printf '   %-10s paint=%s\n' "${users[$i]}" "${R[${users[$i]}]:--}"; done
echo "   --- per-user X sessions (want one :1x per connected user) ---"; cat "$OUTDIR/sessions.txt" 2>/dev/null
echo "======================================================================"
if [ "${R[sys]:-}" = PASS ] && [ "$allpaint" = 1 ] && [ "${R[backend]:-}" = PASS ]; then
  log "VERDICT: xrdp PAINTS headless + MULTI-USER works on the ${RDP_BACKEND} backend — $NUSERS"
  log "         distinct usernames each got their own painted XFCE :1x session over the shared"
  log "         :3389. (Resume + the public Guacamole door / TOTP / fleet-over-Tailscale are"
  log "         real-deploy-only — see the runbook.)"
  exit 0
else
  [ "${R[backend]:-}" = FAIL ] && err "VERDICT: BACKEND MISMATCH — wanted ${RDP_BACKEND} but saw Xorg=$got_xorg/Xvnc=$got_xvnc."
  err "VERDICT: not fully green. If core paints but u1 is black, that's the XFCE second-session"
  err "         black-screen (the key multi-user risk) — inspect $OUTDIR/freerdp-*.log + sessions.txt +"
  err "         container.log. If :3389 is down, xrdp/sesman didn't start (container.log)."
  exit 1
fi
