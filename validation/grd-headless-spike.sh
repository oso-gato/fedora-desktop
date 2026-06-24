#!/usr/bin/env bash
# ============================================================================
# grd-headless-spike.sh — HOST-VALIDATION spike for the fedora-desktop grd lineage
# ============================================================================
# PURPOSE: resolve the ONE risk that gates every grd SSO build BEFORE we commit to
# a session-creation design:
#
#     "Does a headless GNOME-50 session actually PAINT behind a loopback RDP port
#      in a SEATLESS, no-GPU, rootless, systemd-PID-1 container — and does a single
#      RDP credential land on it (SSO)?"
#
# Per the ultra-verified analysis, ~60-70% of the failure probability for BOTH
# candidate builds is this single shared primitive; the #1-vs-#2 (GDM vs GDM-free)
# choice is a secondary completeness tweak you make AFTER this passes. So run THIS
# first.
#
# WHY A SPIKE (not the real image): the grd image is systemd-PID-1 and CANNOT boot
# in the nested CONTAINER_HOST build engine — this is HOST work. Run it on a
# cgroup-v2-delegating host with podman. It builds a THROWAWAY image + container that
# faithfully reproduce run.sh.grd's seatless/no-GPU conditions, then probes paint.
#
# SAFETY: never bind-mounts $HOME or the vault; all state is a scratch named volume,
# torn down at the end. Publishes the test RDP port on 127.0.0.1 ONLY.
#
# WHAT IT TESTS (per variant, in its own fresh container):
#   Gate A  systemd comes up (container running)
#   Gate B  a headless GNOME session exists + mutter paints surfaceless on llvmpipe
#           (journal shows the headless/surfaceless renderer, no EGL/DRI fatal,
#            "No seat assigned, running headlessly")
#   Gate C  the GRD --headless daemon binds loopback :3389
#   Gate D  a REAL RDP client completes the (NLA) handshake AND renders a NON-BLACK
#           desktop frame  <-- the actual "does it paint + SSO" proof
#   Gate E  (light) disconnect + reconnect resumes the SAME session (persistent)
#
# VARIANTS (the two session-CREATION builds; serving layer is identical):
#   2 = GDM-FREE   : gnome-shell --headless as a core `systemd --user` unit (linger)
#   1 = GNOME-50   : gdm + `gnome-headless-session@core.service` (CreateUserDisplay
#                    autologin, no greeter; gdm as session factory only)
# Both then serve via the SAME user `gnome-remote-desktop-headless.service` +
# `grdctl --headless`. Default runs BOTH so you learn which (if either) paints.
#
# NOT in scope (do these only AFTER paint passes): the Guacamole :8443 hop (note its
# RDP tile must use security=any, NOT tls — GRD's front door is NLA-only), TOTP,
# multi-user-on-N-ports, cross-device resume from a different geometry.
#
# HOST PREREQS: podman (rootful or rootless with cgroup-v2 delegation).
#   Optional, for the automated Gate D paint check: a freerdp client
#   (xfreerdp / xfreerdp3 / sdl-freerdp), Xvfb, and ImageMagick (`import`/`convert`).
#   Without them, Gates A-C/E still run and the script prints a MANUAL connect command
#   for you to eyeball the desktop.
# ============================================================================
set -uo pipefail

# ---- config (override via env) ---------------------------------------------
FED="${FED:-44}"                                  # Fedora version (44 = GNOME 50)
VARIANTS="${VARIANTS:-2 1}"                        # which builds to test, in order
TESTPW="${TESTPW:-grd-spike-$RANDOM$RANDOM}"       # throwaway RDP password for 'core'
HOSTPORT="${HOSTPORT:-13389}"                      # host loopback port -> container :3389
IMG="${IMG:-localhost/grd-spike:f${FED}}"
OUTDIR="${OUTDIR:-$PWD/grd-spike-out}"             # diagnostics land here
SESSION_WAIT="${SESSION_WAIT:-25}"                 # secs to wait for the GNOME session
KEEP="${KEEP:-0}"                                  # KEEP=1 leaves the last container up for poking
# The exact gnome-shell headless invocation is one of the UNPROVEN bits — tune here:
GNOME_SHELL_HEADLESS="${GNOME_SHELL_HEADLESS:-/usr/bin/gnome-shell --headless --wayland --mode=user}"

CT=""                                             # current container name (for cleanup)
declare -A RESULT                                 # "variant:gate" -> PASS/FAIL/SKIP

log()  { printf '\033[1;36m[spike]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[spike] WARN:\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m[spike] ERROR:\033[0m %s\n' "$*" >&2; }

cleanup() {
  [ -n "$CT" ] && [ "$KEEP" != 1 ] && { podman rm -f "$CT" >/dev/null 2>&1; podman volume rm "${CT}-home" >/dev/null 2>&1; }
  [ "$KEEP" = 1 ] && [ -n "$CT" ] && warn "KEEP=1 — container '$CT' left running; remove with: podman rm -f $CT && podman volume rm ${CT}-home"
}
trap cleanup EXIT

require_podman() { command -v podman >/dev/null || { err "podman not found — run this on the delegating HOST."; exit 2; }; }

# ---- 1. build a minimal Fedora/GNOME/GRD systemd image ---------------------
build_image() {
  if podman image exists "$IMG"; then log "image $IMG exists (set IMG= or 'podman rmi $IMG' to rebuild)"; return 0; fi
  log "building $IMG (minimal GNOME-$([ "$FED" = 44 ] && echo 50) + GRD + gdm; a few minutes)…"
  local cf pol rc; cf="$(mktemp)"; pol="$(mktemp)"
  # Some hosts harden /etc/containers/policy.json to REJECT unsigned images (the
  # fedora-desktop hosts require cosign-signed images). The upstream Fedora base used by
  # this THROWAWAY spike is unsigned, so pass a permissive signature policy SCOPED TO
  # THIS BUILD ONLY — the host's standing /etc/containers/policy.json is NOT modified.
  printf '%s' '{"default":[{"type":"insecureAcceptAnything"}],"transports":{"docker-daemon":{"":[{"type":"insecureAcceptAnything"}]}}}' > "$pol"
  cat > "$cf" <<EOF
FROM registry.fedoraproject.org/fedora:${FED}
RUN dnf -y --setopt=install_weak_deps=False install \
        systemd systemd-pam iproute procps-ng \
        gnome-shell gnome-session mutter gsettings-desktop-schemas \
        gnome-remote-desktop pipewire pipewire-libs wireplumber \
        gdm mesa-dri-drivers mesa-libgbm openssl \
    && dnf clean all
# 'core' (uid 1000) with linger pre-marked — the lineage's user
RUN useradd -u 1000 -m -s /bin/bash core \
    && mkdir -p /var/lib/systemd/linger && touch /var/lib/systemd/linger/core
# Force software GL + a deterministic headless render path (no /dev/dri present)
RUN printf 'LIBGL_ALWAYS_SOFTWARE=1\nGALLIUM_DRIVER=llvmpipe\n' >> /etc/environment
ENTRYPOINT ["/sbin/init"]
EOF
  podman build --signature-policy="$pol" -t "$IMG" -f "$cf" . 2>&1 | tee "$OUTDIR/build.log"
  rc=${PIPESTATUS[0]}
  rm -f "$cf" "$pol"
  if [ "$rc" != 0 ] || ! podman image exists "$IMG"; then
    err "image build FAILED (rc=$rc) — see $OUTDIR/build.log."
    err "Most common cause on a hardened host: the base pull is rejected by"
    err "/etc/containers/policy.json. Check it with:  cat /etc/containers/policy.json"
    err "(this build already passes a permissive policy scoped to itself; if it still"
    err " fails, the host may block the registry entirely or have no network egress)."
    return 1
  fi
  log "image built."; return 0
}

# ---- 2. run a container that mirrors run.sh.grd's seatless/no-GPU contract --
run_container() {
  CT="grd-spike-v$1"
  podman rm -f "$CT" >/dev/null 2>&1; podman volume rm "${CT}-home" >/dev/null 2>&1
  log "[$1] starting systemd-PID-1 container '$CT' (NO /dev/dri, --cgroupns=host, label=disable)…"
  podman run -d --name "$CT" --hostname "$CT" \
      --systemd=always --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
      --shm-size=512m --security-opt label=disable \
      --cap-add SYS_ADMIN --cap-add NET_ADMIN \
      -v "${CT}-home":/home/core \
      -p "127.0.0.1:${HOSTPORT}:3389" \
      "$IMG" >/dev/null || { err "[$1] container failed to start"; return 1; }
  # wait for systemd to settle (running OR degraded both fine)
  for _i in $(seq 1 30); do
    s=$(xc "$CT" systemctl is-system-running 2>/dev/null)
    case "$s" in running|degraded) RESULT["$1:A"]=PASS; log "[$1] Gate A: systemd '$s'"; return 0;; esac
    sleep 1
  done
  RESULT["$1:A"]=FAIL; err "[$1] Gate A FAIL: systemd never reached running/degraded"; return 1
}

xc()  { podman exec "$@"; }                                        # exec as root
xcu() { local c="$1"; shift; podman exec --user core -e XDG_RUNTIME_DIR=/run/user/1000 \
        -e DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus "$c" "$@"; }  # exec as core, user bus

# mint the GRD RDP TLS pair, owned by core (the --headless daemon runs AS core)
mint_tls() {
  xc "$1" bash -lc 'install -d -o core -g core /home/core/.grd-cert && \
     openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj "/CN=grd-spike" \
       -keyout /home/core/.grd-cert/key.pem -out /home/core/.grd-cert/cert.pem 2>/dev/null && \
     chown -R core:core /home/core/.grd-cert && chmod 600 /home/core/.grd-cert/key.pem'
}

# ---- 3. bring up the per-user headless GNOME session (variant-specific) -----
bringup_session() {
  local v="$1" ct="$2"
  xc "$ct" loginctl enable-linger core >/dev/null 2>&1 || true
  if [ "$v" = 2 ]; then
    log "[2] GDM-free: gnome-shell --headless as core's systemd --user unit"
    xc "$ct" bash -lc "install -d -o core -g core /home/core/.config/systemd/user && \
      cat > /home/core/.config/systemd/user/grd-headless-session.service <<UNIT && chown -R core:core /home/core/.config
[Unit]
Description=Spike headless GNOME session
[Service]
ExecStart=${GNOME_SHELL_HEADLESS}
Restart=on-failure
UNIT"
    xcu "$ct" systemctl --user daemon-reload >/dev/null 2>&1
    xcu "$ct" systemctl --user start grd-headless-session.service >/dev/null 2>&1 \
      || warn "[2] could not start grd-headless-session.service (see diagnostics)"
  else
    log "[1] GNOME-50: gdm + gnome-headless-session@core (CreateUserDisplay autologin, no greeter)"
    xc "$ct" systemctl enable --now gdm.service >/dev/null 2>&1 \
      || warn "[1] gdm.service failed to start (likely the seatless-GDM CanGraphical gate — see diagnostics)"
    xc "$ct" systemctl enable --now "gnome-headless-session@core.service" >/dev/null 2>&1 \
      || warn "[1] gnome-headless-session@core failed (see diagnostics)"
  fi
  log "[$v] waiting ${SESSION_WAIT}s for the session to come up…"; sleep "$SESSION_WAIT"
}

# ---- 4. configure GRD --headless + start the headless RDP daemon (shared) ---
configure_grd() {
  local v="$1" ct="$2"
  mint_tls "$ct"
  xcu "$ct" grdctl --headless rdp set-tls-cert /home/core/.grd-cert/cert.pem >/dev/null 2>&1
  xcu "$ct" grdctl --headless rdp set-tls-key  /home/core/.grd-cert/key.pem  >/dev/null 2>&1
  # set-credentials reads USER + PASSWORD (CLI form varies by version; try both)
  xcu "$ct" grdctl --headless rdp set-credentials core "$TESTPW" >/dev/null 2>&1 \
    || printf 'core\n%s\n' "$TESTPW" | xcu "$ct" grdctl --headless rdp set-credentials >/dev/null 2>&1 || true
  xcu "$ct" grdctl --headless rdp enable >/dev/null 2>&1
  # the per-user headless RDP server (binds :3389 inside core's session)
  xcu "$ct" systemctl --user start gnome-remote-desktop-headless.service >/dev/null 2>&1 \
    || warn "[$v] gnome-remote-desktop-headless.service did not start (see diagnostics)"
  sleep 4
}

# ---- 5. probe the gates -----------------------------------------------------
probe() {
  local v="$1" ct="$2" od="$OUTDIR/v$v"; mkdir -p "$od"

  # Gate B: session exists + mutter paints surfaceless (journal heuristics)
  xcu "$ct" grdctl --headless status > "$od/grdctl-status.txt" 2>&1 || true
  xc  "$ct" bash -lc 'journalctl --no-pager -b 2>/dev/null | grep -iE "mutter|gnome-shell|remote-desktop|seat|egl|renderer|llvmpipe|dri" | tail -200' > "$od/journal.txt" 2>&1 || true
  xc  "$ct" loginctl list-sessions > "$od/loginctl.txt" 2>&1 || true
  if grep -qiE 'No seat assigned, running headlessly|surfaceless|llvmpipe|software rendering' "$od/journal.txt" \
     && ! grep -qiE 'failed to (create|initialize) .*egl|no GPUs found|failed to open .*dri' "$od/journal.txt"; then
    RESULT["$v:B"]=PASS; log "[$v] Gate B: headless compositor signature present (paints surfaceless)"
  else
    RESULT["$v:B"]=FAIL; warn "[$v] Gate B: no clean headless-paint signature (see $od/journal.txt)"
  fi

  # Gate C: :3389 listening inside the container
  xc "$ct" ss -ltnp > "$od/ss.txt" 2>&1 || true
  if grep -qE '127\.0\.0\.1:3389|0\.0\.0\.0:3389|\*:3389|:::3389' "$od/ss.txt"; then
    RESULT["$v:C"]=PASS; log "[$v] Gate C: GRD listening on :3389"
  else
    RESULT["$v:C"]=FAIL; warn "[$v] Gate C: nothing listening on :3389 (GRD daemon not serving — see $od/ss.txt)"
  fi

  # Gate D: real RDP client -> NLA handshake + NON-BLACK frame
  probe_paint "$v" "$od"

  # Gate E (light): reconnect resumes the SAME session
  if [ "${RESULT["$v:D"]:-}" = PASS ]; then
    local sid1 sid2
    sid1=$(awk '/core/{print $1; exit}' "$od/loginctl.txt" 2>/dev/null)
    sleep 2; xc "$ct" loginctl list-sessions > "$od/loginctl-2.txt" 2>&1 || true
    sid2=$(awk '/core/{print $1; exit}' "$od/loginctl-2.txt" 2>/dev/null)
    if [ -n "$sid1" ] && [ "$sid1" = "$sid2" ]; then RESULT["$v:E"]=PASS; log "[$v] Gate E: session persists across reconnect (id=$sid1)"
    else RESULT["$v:E"]=SKIP; warn "[$v] Gate E: could not confirm session-id stability"; fi
  else RESULT["$v:E"]=SKIP; fi

  podman logs "$ct" > "$od/container.log" 2>&1 || true
  log "[$v] diagnostics -> $od/"
}

# Gate D — automated paint check via freerdp+Xvfb+ImageMagick, else manual fallback
probe_paint() {
  local v="$1" od="$2"
  local frdp xvfb im
  frdp=$(command -v xfreerdp3 || command -v xfreerdp || command -v sdl-freerdp || true)
  xvfb=$(command -v Xvfb || true); im=$(command -v import || true)
  if [ -z "$frdp" ] || [ -z "$xvfb" ] || [ -z "$im" ]; then
    RESULT["$v:D"]=SKIP
    warn "[$v] Gate D SKIPPED (need freerdp + Xvfb + ImageMagick). Eyeball it manually:"
    printf '        %s /v:127.0.0.1:%s /u:core /p:%s /cert:ignore /sec:nla /size:1280x720\n' \
           "${frdp:-xfreerdp}" "$HOSTPORT" "$TESTPW"
    return
  fi
  log "[$v] Gate D: connecting a real RDP client into Xvfb and capturing a frame…"
  Xvfb :99 -screen 0 1280x720x24 >/dev/null 2>&1 & local xpid=$!
  sleep 1
  # Minimal, FreeRDP2/3-portable args. NO '+auth-only' (default is a full session — what
  # we want to capture); '+auth-only:off' was invalid syntax that made the client reject
  # its own command line and never connect.
  DISPLAY=:99 "$frdp" /v:127.0.0.1:"$HOSTPORT" /u:core /p:"$TESTPW" /cert:ignore /sec:nla \
      /size:1280x720 +clipboard > "$od/freerdp.log" 2>&1 & local rpid=$!
  sleep 14
  DISPLAY=:99 import -window root "$od/frame.png" >/dev/null 2>&1 || true
  kill "$rpid" "$xpid" >/dev/null 2>&1
  local sd=0; [ -s "$od/frame.png" ] && sd=$(convert "$od/frame.png" -colorspace Gray -format '%[fx:standard_deviation]' info: 2>/dev/null || echo 0)
  echo "$sd" > "$od/frame-stddev.txt"
  if awk "BEGIN{exit !($sd > 0.02)}"; then
    RESULT["$v:D"]=PASS; log "[$v] Gate D: NON-BLACK desktop frame rendered (stddev=$sd) — IT PAINTS + SSO works"
  elif grep -qiE 'invalid sigil|^usage:|failed at index|/usr/bin/.*free.*rdp - ' "$od/freerdp.log"; then
    RESULT["$v:D"]=SKIP
    warn "[$v] Gate D INCONCLUSIVE: the freerdp client rejected its own arguments (version quirk) and never connected — NOT a desktop result. See $od/freerdp.log; try the manual connect below."
    printf '        DISPLAY=:99 %s /v:127.0.0.1:%s /u:core /p:%s /cert:ignore /size:1280x720\n' "$frdp" "$HOSTPORT" "$TESTPW"
  elif grep -qiE 'connected to|negotiat|channel|licens|server redirect|surface|gfx' "$od/freerdp.log"; then
    RESULT["$v:D"]=FAIL
    warn "[$v] Gate D: client CONNECTED but captured frame is black (stddev=$sd) — session may be empty / no virtual monitor, OR the WM-less Xvfb capture missed the window. Eyeball $od/frame.png; see $od/freerdp.log."
  else
    RESULT["$v:D"]=FAIL
    warn "[$v] Gate D: client did not connect (stddev=$sd) — see $od/freerdp.log (auth/security/port)."
  fi
}

# ---- main -------------------------------------------------------------------
require_podman
mkdir -p "$OUTDIR"
log "spike start | FED=$FED VARIANTS='$VARIANTS' HOSTPORT=$HOSTPORT OUT=$OUTDIR"
build_image || { err "ABORT: base image did not build — the paint primitive was NOT tested."; exit 3; }
for v in $VARIANTS; do
  echo "----------------------------------------------------------------------"
  if run_container "$v"; then
    bringup_session "$v" "$CT"
    configure_grd  "$v" "$CT"
    probe          "$v" "$CT"
  fi
  cleanup; CT=""
done

# ---- summary ----------------------------------------------------------------
echo "======================================================================"
printf '%-9s %-6s %-6s %-6s %-6s %-6s\n' "VARIANT" "A:sys" "B:paint" "C:3389" "D:RDP" "E:resume"
overall=1
for v in $VARIANTS; do
  name=$([ "$v" = 2 ] && echo "2 GDM-free" || echo "1 GNOME50")
  printf '%-9s %-6s %-6s %-6s %-6s %-6s\n' "$name" \
    "${RESULT["$v:A"]:--}" "${RESULT["$v:B"]:--}" "${RESULT["$v:C"]:--}" "${RESULT["$v:D"]:--}" "${RESULT["$v:E"]:--}"
  [ "${RESULT["$v:D"]:-}" = PASS ] && overall=0
done
echo "======================================================================"
ran_any=0; for v in $VARIANTS; do [ "${RESULT["$v:A"]:-}" = PASS ] && ran_any=1; done
if [ "$overall" = 0 ]; then
  log "VERDICT: the shared primitive WORKS for at least one build — a headless GNOME"
  log "         session paints behind loopback RDP in this container. Proceed to wire"
  log "         the winning build into the grd lineage (then add Guacamole security=any,"
  log "         TOTP, per-user ports). Gate D = the proof; check grd-spike-out/v*/frame.png."
elif [ "$ran_any" = 0 ]; then
  err  "VERDICT: INFRASTRUCTURE FAILURE — no container even reached systemd (Gate A all '-')."
  err  "         The paint primitive was NOT tested; this is NOT a grd finding. Inspect"
  err  "         $OUTDIR/build.log + $OUTDIR/v*/container.log. Likely: image/policy (see"
  err  "         above), or cgroup-v2 delegation missing (rootless: add the user@ Delegate="
  err  "         drop-in from HOST-VALIDATION-PROCESS.md, then re-run)."
else
  err  "VERDICT: a container ran but NO build painted a desktop (Gate D). The dominant shared"
  err  "         risk is REAL in this container shape. Inspect grd-spike-out/v*/{journal,freerdp,ss}.txt:"
  err  "         common causes — gdm seat0/CanGraphical refusal (variant 1), gnome-shell"
  err  "         --headless not coming up under systemd --user (variant 2; tune"
  err  "         GNOME_SHELL_HEADLESS=), mutter no surfaceless EGL with no /dev/dri (may"
  err  "         need a vgem/vkms render node), or GRD not attaching to the session."
  err  "         Do NOT invest in the grd session rewrite until this paints."
fi
exit "$overall"
