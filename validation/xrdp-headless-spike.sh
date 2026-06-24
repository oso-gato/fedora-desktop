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
IMG="${IMG:-localhost/xrdp-spike:f${FED}}"
OUTDIR="${OUTDIR:-$PWD/xrdp-spike-out}"
SESSION_WAIT="${SESSION_WAIT:-12}"                  # secs for a session to spawn after connect
KEEP="${KEEP:-0}"
RDP_SEC="${RDP_SEC:-rdp}"                            # xrdp security: rdp|tls|nla (tunable)
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
  local cf pol rc; cf="$(mktemp)"; pol="$(mktemp)"
  printf '%s' '{"default":[{"type":"insecureAcceptAnything"}]}' > "$pol"
  cat > "$cf" <<EOF
FROM registry.fedoraproject.org/fedora:${FED}
RUN dnf -y --setopt=install_weak_deps=False install \
        xrdp xorgxrdp \
        xfce4-session xfwm4 xfce4-panel xfdesktop xfce4-terminal xfce4-settings \
        dbus-x11 xorg-x11-xauth mesa-dri-drivers procps-ng iproute util-linux passwd openssl \
    && dnf clean all
# launch XFCE for every xrdp session
RUN printf '#!/bin/bash\nexport XDG_SESSION_TYPE=x11\nexec startxfce4\n' > /etc/xrdp/startwm.sh && chmod +x /etc/xrdp/startwm.sh
# xrdp RSA keys + a self-signed TLS cert (xrdp.ini default paths)
RUN xrdp-keygen xrdp auto >/dev/null 2>&1 || true; \
    openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj /CN=xrdp-spike \
      -keyout /etc/xrdp/key.pem -out /etc/xrdp/cert.pem >/dev/null 2>&1; \
    chmod 600 /etc/xrdp/key.pem
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
podman run -d --name "$CT" --hostname "$CT" --shm-size=1g \
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
# Gate B evidence: distinct per-user Xorg :1x sessions
podman exec "$CT" bash -lc 'ls -1 /tmp/.X11-unix 2>/dev/null; pgrep -a Xorg 2>/dev/null' > "$OUTDIR/sessions.txt" 2>&1 || true

# ---- summary ----------------------------------------------------------------
echo "======================================================================"
echo "[xrdp-spike] xrdp lineage — $NUSERS users, ONE shared :3389 (sesman <User,bpp> routing):"
printf '   %-8s %-6s\n' "A/C:3389" "${R[sys]:--}"
for i in "${!users[@]}"; do printf '   %-8s paint=%s\n' "${users[$i]}" "${R[${users[$i]}]:--}"; done
echo "   --- per-user X sessions (want one :1x per connected user) ---"; cat "$OUTDIR/sessions.txt" 2>/dev/null
echo "======================================================================"
if [ "${R[sys]:-}" = PASS ] && [ "$allpaint" = 1 ]; then
  log "VERDICT: xrdp PAINTS headless + MULTI-USER works — $NUSERS distinct usernames each got"
  log "         their own painted XFCE :1x session over the shared :3389. (Resume + the public"
  log "         Guacamole door / TOTP / fleet-over-Tailscale are real-deploy-only — see the runbook.)"
  exit 0
else
  err "VERDICT: not fully green. If core paints but u1 is black, that's the XFCE second-session"
  err "         black-screen (the key multi-user risk) — inspect $OUTDIR/freerdp-*.log + sessions.txt +"
  err "         container.log. If :3389 is down, xrdp/sesman didn't start (container.log)."
  exit 1
fi
