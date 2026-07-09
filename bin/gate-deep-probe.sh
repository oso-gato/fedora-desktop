#!/usr/bin/env bash
# gate-deep-probe.sh — deeper Gate-B equivalence probe, run INSIDE a disposable candidate by the
# host live-gate (.live-gate PROBE_<lineage>), loopback-only, as root. Usage: gate-deep-probe.sh <xrdp|grd>
#
# Exit 0 = every GATED check passed; non-zero = a check failed. On a non-zero exit the host gate
# (validate-candidate.sh) dumps this script's stdout into the RED verdict comment, so a failure is
# self-diagnosing — read the [FAIL] lines + SUMMARY on the PR to iterate.
#
# WHY: the prior .live-gate probe proved only "web :8443 served 200 + RDP :3389 was open". This
# deepens that toward grd<->xrdp functional EQUIVALENCE with what is feasible in a loopback-only,
# podman-exec, no-published-port context. It asserts, per lineage:
#   * the desktop SESSION actually started and is RENDERING (not a black/dead session behind an open
#     port) — grd: the GDM headless session is active + the compositor is running + (corroborating)
#     mutter's surfaceless/llvmpipe paint signature in the journal; xrdp: a live Xorg :10 session;
#   * the RDP server is correctly CONFIGURED — grd: GRD is the :3389 listener; xrdp: the bpp=24
#     invariant + the xorgxrdp backend + KillDisconnected=false (the resume semantics);
#   * the Guacamole public-door AUTH chain is wired — the jdbc+totp extensions are installed and the
#     'core' DB identity exists, with the guacadmin backdoor absent.
#
# It deliberately does NOT (cannot, in a loopback gate) prove: a real RDP-pixel frame (the spikes use
# host-side xfreerdp + Xvfb + ImageMagick against a PUBLISHED port — structurally impossible here, and
# shipping those tools would violate Principle 3), cross-device resume, or fleet-SSH over a live
# tailnet. Those stay operator-run — see validation/GO-LIVE-VALIDATION*.md. (Multi-user per-user port
# binding is a planned increment; this first version gates the single-user core path.)
set -uo pipefail
LIN="${1:?usage: gate-deep-probe.sh <xrdp|grd>}"
fail=0; FAILED=""
pass(){ echo "  [PASS] $*"; }
info(){ echo "  [info] $*"; }
bad(){ echo "  [FAIL] $*"; fail=1; FAILED="$FAILED; ${2:-$1}"; }
GHOME=/etc/guacamole; SOCK=/var/lib/mysql/mysql.sock; DB=guacamole_db
sql(){ mariadb --socket="$SOCK" -N -B "$DB" -e "$1" 2>/dev/null; }

echo "== deep-probe ($LIN) =="

# ---- common: basics (already health-gated; re-assert cheaply for a self-contained verdict) -------
code="$(curl -sk -o /dev/null -w '%{http_code}' https://127.0.0.1:8443/guacamole/ 2>/dev/null || true)"
[ "$code" = 200 ] && pass "web :8443 /guacamole/ = 200" || bad "web :8443 = ${code:-none} (want 200)" "web-8443"
if timeout 6 bash -c 'exec 3<>/dev/tcp/127.0.0.1/3389' 2>/dev/null; then pass "RDP :3389 open"; else bad "RDP :3389 not open" "rdp-3389"; fi
mariadb-admin --socket="$SOCK" ping >/dev/null 2>&1 && pass "MariaDB ping" || bad "MariaDB not answering on $SOCK" "mariadb-ping"

# ---- common: Guacamole public-door auth chain wired ----------------------------------------------
if ls "$GHOME"/extensions/*jdbc*.jar >/dev/null 2>&1 && ls "$GHOME"/extensions/*totp*.jar >/dev/null 2>&1; then
  pass "Guacamole jdbc + totp extensions present ($(ls "$GHOME"/extensions/*.jar 2>/dev/null | wc -l) jar(s))"
else bad "Guacamole jdbc/totp extension jar(s) missing in $GHOME/extensions" "guac-ext"; fi
n_core="$(sql "SELECT COUNT(*) FROM guacamole_entity WHERE name='core' AND type='USER';")"
[ "${n_core:-0}" -ge 1 ] 2>/dev/null && pass "Guacamole DB identity 'core' provisioned (DB-auth live)" || bad "Guacamole DB identity 'core' absent (n=${n_core:-?})" "db-core"
n_bad="$(sql "SELECT COUNT(*) FROM guacamole_entity WHERE name='guacadmin';")"
[ "${n_bad:-1}" = 0 ] && pass "guacadmin backdoor absent" || bad "guacadmin backdoor present (n=${n_bad:-?})" "guacadmin"

# ---- lineage-specific: session is RENDERING + RDP server CONFIGURED ------------------------------
case "$LIN" in
  grd)
    sa="$(systemctl is-active 'gnome-headless-session@core.service' 2>/dev/null || true)"
    [ "$sa" = active ] && pass "grd: gnome-headless-session@core active (GDM headless session up)" \
      || bad "grd: gnome-headless-session@core not active (=${sa:-unknown})" "grd-session"
    if pgrep -u core -x gnome-shell >/dev/null 2>&1; then pass "grd: gnome-shell compositing for core (desktop rendering)"
    elif pgrep -u core -f gnome-remote-desktop >/dev/null 2>&1; then pass "grd: gnome-remote-desktop running for core"; info "gnome-shell not matched by pgrep -x; GRD daemon present"
    else bad "grd: neither gnome-shell nor gnome-remote-desktop running for core (session may be black)" "grd-compositor"; fi
    # The assertion is "GRD is the :3389 listener" — attribute the socket to its
    # process via /proc/<pid>/comm (survives ss's process-name truncation). The old
    # fallback arm passed on ANY listener, silently degrading this to the port-open
    # check HEALTH already did.
    l="$(ss -ltnp 2>/dev/null | grep ':3389' | head -1 || true)"
    if [ -z "$l" ]; then bad "grd: nothing listening on :3389 per ss" "grd-listener"
    else
      lp="$(printf '%s' "$l" | sed -n 's/.*pid=\([0-9]*\).*/\1/p')"
      lc="$(cat "/proc/${lp:-0}/comm" 2>/dev/null || true)"
      case "$lc" in
        gnome-remote-de*) pass "grd: gnome-remote-desktop is the :3389 listener (comm=$lc)" ;;
        "") if pgrep -u core -f gnome-remote-desktop >/dev/null 2>&1; then
              info "grd: :3389 listener pid unresolved by ss; GRD daemon confirmed running"
              pass "grd: :3389 listener present + GRD daemon running (pid-attribution unavailable)"
            else bad "grd: :3389 listener cannot be attributed and no GRD daemon is running" "grd-listener"; fi ;;
        *) bad "grd: the :3389 listener is '$lc', NOT gnome-remote-desktop" "grd-listener" ;;
      esac
    fi
    # corroborating paint evidence (informational — journal location can vary by GNOME build)
    pj="$( { journalctl --no-pager -b _UID=1000 2>/dev/null; journalctl --no-pager -b -u 'gnome-headless-session@core.service' 2>/dev/null; } | grep -iE 'surfaceless|llvmpipe|No seat assigned, running headlessly|software rendering' | head -1 || true)"
    [ -n "$pj" ] && info "grd: mutter headless paint signature: $pj" || info "grd: no explicit surfaceless/llvmpipe journal line captured (non-gating)"
    ge="$( { journalctl --no-pager -b 2>/dev/null; journalctl --no-pager -b _UID=1000 2>/dev/null; } | grep -iE 'failed to (create|initialize) [^ ]*egl|no GPUs found|failed to open [^ ]*dri' | head -1 || true)"
    [ -z "$ge" ] && pass "grd: no fatal GL/EGL/DRI error in journal" || bad "grd: fatal GL error in journal: $ge" "grd-gl"
    ;;
  xrdp)
    { pgrep -x Xorg >/dev/null 2>&1 && [ -e /tmp/.X11-unix/X10 ]; } \
      && pass "xrdp: Xorg :10 session live (X10 socket + Xorg proc)" || bad "xrdp: Xorg :10 session NOT up (X10 socket / Xorg proc missing)" "xrdp-xorg"
    pgrep -x xrdp-sesman >/dev/null 2>&1 && pass "xrdp-sesman running" || bad "xrdp-sesman not running" "xrdp-sesman"
    grep -qE '^max_bpp=24'        /etc/xrdp/xrdp.ini  2>/dev/null && pass "xrdp: max_bpp=24 (bpp invariant pinned)" || bad "xrdp: max_bpp=24 not set in xrdp.ini" "xrdp-bpp"
    grep -qE '^autorun=Xorg'      /etc/xrdp/xrdp.ini  2>/dev/null && pass "xrdp: autorun=Xorg (xorgxrdp backend)" || bad "xrdp: autorun=Xorg not set in xrdp.ini" "xrdp-backend"
    grep -qE '^KillDisconnected=false' /etc/xrdp/sesman.ini 2>/dev/null && pass "xrdp: KillDisconnected=false (resume semantics)" || bad "xrdp: KillDisconnected=false not set in sesman.ini" "xrdp-resume"
    ;;
  *) bad "unknown lineage '$LIN' (want xrdp|grd)" "lineage" ;;
esac

# ---- multi-user: a 2nd user (USER1=gateuser1) provisioned via the gate's scratch SECRET_ENV -------
# The key grd<->xrdp structural difference: grd spawns each user's headless GNOME session at BOOT and
# binds a per-user loopback RDP port (core :3389, USERn :3389+n) — so it IS gate-checkable. xrdp spawns
# a user's X session at LOGIN (sesman, shared :3389), and the gate performs no RDP login, so a live 2nd
# xrdp session is NOT gate-observable without an RDP client (operator-run); we assert account + tile only.
EXTRA_USER=gateuser1
if id "$EXTRA_USER" >/dev/null 2>&1; then
  pass "multi-user: extra user '$EXTRA_USER' provisioned (OS account)"
  ne="$(sql "SELECT COUNT(*) FROM guacamole_entity WHERE name='$EXTRA_USER' AND type='USER';")"
  [ "${ne:-0}" -ge 1 ] 2>/dev/null && pass "multi-user: '$EXTRA_USER' has its own Guacamole DB identity/tile" || bad "multi-user: '$EXTRA_USER' missing Guacamole DB identity (n=${ne:-?})" "mu-db"
  case "$LIN" in
    grd)
      sa1="$(systemctl is-active 'gnome-headless-session@gateuser1.service' 2>/dev/null || true)"
      [ "$sa1" = active ] && pass "grd multi-user: gnome-headless-session@$EXTRA_USER active (per-user headless session)" \
        || bad "grd multi-user: gnome-headless-session@$EXTRA_USER not active (=${sa1:-unknown})" "mu-grd-session"
      ok=0; for _i in $(seq 1 20); do { [ -e /run/fedora-desktop-grd/user-3390.ready ] || ss -ltnp 2>/dev/null | grep -q ':3390'; } && { ok=1; break; }; sleep 3; done
      [ "$ok" = 1 ] && pass "grd multi-user: USER1 bound its OWN loopback RDP port :3390 (per-user GRD)" \
        || bad "grd multi-user: USER1 port :3390 not ready (no /run/fedora-desktop-grd/user-3390.ready, not in ss after 60s)" "mu-grd-port"
      ;;
    xrdp)
      info "xrdp multi-user: per-user X session is login-time (sesman, shared :3389) — not gate-observable without an RDP client; account + Guacamole tile asserted above"
      ;;
  esac
else
  info "multi-user: no extra user provisioned (single-user run) — multi-user checks skipped"
fi

[ "$fail" = 0 ] || echo "  SUMMARY: FAILED checks:${FAILED}"
echo "== deep-probe ($LIN): $([ "$fail" = 0 ] && echo GREEN || echo RED) =="
exit "$fail"
