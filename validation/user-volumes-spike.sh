#!/usr/bin/env bash
# ============================================================================
# user-volumes-spike.sh — HOST-VALIDATION of the per-user-volume OWNERSHIP model
# (the #45 equivalence fix) + the Option-2 SHARED collaboration folder, BEFORE the
# shared folder is wired into run.sh / spin-up.sh / the entrypoints.
# ============================================================================
# Proves, in a throwaway container, that:
#   A  per-user homes get PINNED uid 1000+n / gid 8000+n + 0700 -> deterministic ownership AND
#      ISOLATION: user B canNOT read user A's home (the vault/token security ceiling);
#   B  a FRESH bound-volume mount root (root-owned) is correctly chown'd to the user — the
#      grd gap #45 fixes (without it the user can't write ~);
#   C  a 2770 root:deskshare SHARED volume gives COLLABORATION — every MEMBER can enter +
#      read; a NON-member is fully DENIED; new files inherit the group (setgid);
#   D  the load-bearing design question: can member B EDIT member A's shared file? With the
#      default umask (022 -> 644) NO (group read-only); this spike measures it under the
#      default umask, under umask 002, AND under a default POSIX ACL — so we pick the right
#      mechanism for the feature instead of guessing.
#
# SAFETY: throwaway image + container; no $HOME/vault mount; torn down on exit.
# ============================================================================
set -uo pipefail
FED="${FED:-44}"
IMG="${IMG:-localhost/user-vol-spike:f${FED}}"
CT="user-vol-spike"
SHARE_GID="${SHARE_GID:-6000}"
KEEP="${KEEP:-0}"
log(){  printf '\033[1;36m[user-vol]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[user-vol] WARN:\033[0m %s\n' "$*" >&2; }
err(){  printf '\033[1;31m[user-vol] ERR:\033[0m %s\n' "$*" >&2; }
cleanup(){ [ "$KEEP" = 1 ] || podman rm -f "$CT" >/dev/null 2>&1; [ "$KEEP" = 1 ] && warn "KEEP=1 — '$CT' left up"; }
trap cleanup EXIT
command -v podman >/dev/null || { err "podman not found — run on the host."; exit 2; }

build_image(){
  podman image exists "$IMG" && { log "image $IMG exists"; return 0; }
  log "building $IMG (fedora + shadow-utils/util-linux/acl; ~1 min)…"
  local cf pol rc; cf="$(mktemp)"; pol="$(mktemp)"
  printf '%s' '{"default":[{"type":"insecureAcceptAnything"}]}' > "$pol"
  cat > "$cf" <<EOF
FROM registry.fedoraproject.org/fedora:${FED}
RUN dnf -y --setopt=install_weak_deps=False install shadow-utils util-linux acl passwd && dnf clean all
ENTRYPOINT ["sleep","infinity"]
EOF
  podman build --signature-policy="$pol" -t "$IMG" -f "$cf" . 2>&1 | tee /tmp/user-vol-build.log; rc=${PIPESTATUS[0]}
  rm -f "$cf" "$pol"
  { [ "$rc" = 0 ] && podman image exists "$IMG"; } || { err "build FAILED (rc=$rc) — see /tmp/user-vol-build.log"; return 1; }
  log "image built."
}

build_image || { err "ABORT: image did not build."; exit 3; }
podman rm -f "$CT" >/dev/null 2>&1
podman run -d --name "$CT" --hostname "$CT" --security-opt label=disable "$IMG" >/dev/null \
    || { err "container failed to start"; exit 1; }

# SHARE_GID passed via -e so the RUNNER heredoc can stay QUOTED (no $-escaping).
podman exec -i -e "SHARE_GID=${SHARE_GID}" "$CT" bash -s <<'RUNNER'
set -uo pipefail
SHARE_GID="${SHARE_GID:-6000}"; SHARE=/home/shared; GRP=deskshare
P=0; F=0
ok(){ printf '   PASS  %s\n' "$1"; P=$((P+1)); }
no(){ printf '   FAIL  %s\n' "$1"; F=$((F+1)); }
# runuser sets the FULL supplementary group set (initgroups) — the realistic login path.
asuser(){ local u="$1"; shift; runuser -u "$u" -- "$@"; }

# REPRODUCE the production image: the 1Password packages BAKE groups at gid 1001/1002/1003
# (onepassword/-mcp/-cli). A clean minimal image had these free, which is why an earlier
# gid==uid==1000+n scheme passed here but CRASHED on the real deploy (`groupadd -g 1001` collided,
# `chown name:name` died on the unknown group -> PID 1 exit 1 under set -e). Pre-bake them so this
# spike now reproduces the collision and proves the gid-8000 fix avoids it.
groupadd -g 1001 onepassword     2>/dev/null || true
groupadd -g 1002 onepassword-mcp 2>/dev/null || true
groupadd -g 1003 onepassword-cli 2>/dev/null || true

# mkuser mirrors the FIXED entrypoint create logic against a FRESH root-owned home (the bound
# named-volume mount root): UID 1000+n, GID 8000+n (reserved, collision-free), NUMERIC non-fatal chown.
mkuser(){  # <name> <n>
  local u="$1" n="$2" uid gid; uid=$((1000+n)); gid=$((8000+n))
  mkdir -p "/home/$u"; chown root:root "/home/$u"; chmod 700 "/home/$u"   # simulate fresh volume mount
  groupadd -g "$gid" "$u" 2>/dev/null || true
  useradd -M -u "$uid" -g "$gid" -s /bin/bash "$u" 2>/dev/null || true     # -M: home (the volume) exists
  echo "$u:pw-$u-12345678" | chpasswd
  chown -R "$uid:$gid" "/home/$u" 2>/dev/null || true; chmod 700 "/home/$u"   # NUMERIC, non-fatal (#fix)
}
mkuser alice 1     # member  -> uid 1001, gid 8001
mkuser bob   2     # member  -> uid 1002, gid 8002
mkuser carol 3     # NON-member control -> uid 1003, gid 8003

echo "=== A/B: pinned ownership (uid 1000+n / gid 8000+n) avoids the 1Password gid collision ==="
[ "$(stat -c '%u:%g' /home/alice)" = "1001:8001" ] && ok "alice home 1001:8001 (uid 1000+n, gid 8000+n pinned)" || no "alice home $(stat -c '%u:%g' /home/alice) (want 1001:8001)"
[ "$(stat -c '%u:%g' /home/bob)"   = "1002:8002" ] && ok "bob home 1002:8002"                     || no "bob home $(stat -c '%u:%g' /home/bob) (want 1002:8002)"
id -nG alice | tr ' ' '\n' | grep -qx onepassword && no "alice landed in the onepassword group (gid collision NOT avoided)" || ok "alice NOT in onepassword (gid 8001 cleared the 1001 collision)"
[ "$(stat -c '%a' /home/alice)" = "700" ] && ok "alice home 0700" || no "alice home mode $(stat -c '%a' /home/alice)"
asuser alice bash -c 'echo ok > /home/alice/probe' && ok "alice can write her own home (chown rescued the root-owned mount)" || no "alice CANNOT write her own home (grd-gap bug)"

echo "=== A: 0700 home isolation ==="
asuser alice bash -c 'echo secret-a > /home/alice/secret; chmod 600 /home/alice/secret'
if asuser bob cat /home/alice/secret >/dev/null 2>&1; then no "bob CAN read alice's home (ISOLATION BROKEN)"; else ok "bob CANNOT read alice's home (0700 isolation holds)"; fi

echo "=== C: shared folder 2770 root:deskshare — membership gate ==="
groupadd -g "$SHARE_GID" "$GRP"
usermod -aG "$GRP" alice; usermod -aG "$GRP" bob          # SUPPLEMENTARY (primary stays per-user UPG)
mkdir -p "$SHARE"; chown "root:$GRP" "$SHARE"; chmod 2770 "$SHARE"
[ "$(stat -c '%U:%G %a' $SHARE)" = "root:$GRP 2770" ] && ok "shared dir root:$GRP mode 2770 (setgid)" || no "shared dir $(stat -c '%U:%G %a' $SHARE)"
asuser alice bash -c "echo from-alice > $SHARE/a.txt" && ok "alice (member) writes shared/a.txt" || no "alice cannot write shared"
asuser bob   cat "$SHARE/a.txt" >/dev/null 2>&1 && ok "bob (member) reads alice's shared file" || no "bob cannot read shared file"
[ "$(stat -c '%G' $SHARE/a.txt)" = "$GRP" ] && ok "new shared file inherits group $GRP (setgid works)" || no "shared file group $(stat -c '%G' $SHARE/a.txt)"

echo "=== C: NON-member is fully denied ==="
if asuser carol bash -c "cat $SHARE/a.txt" >/dev/null 2>&1; then no "carol (non-member) CAN read shared (LEAK)"; else ok "carol (non-member) DENIED read"; fi
if asuser carol bash -c "echo x > $SHARE/c.txt" 2>/dev/null;   then no "carol (non-member) CAN write shared (LEAK)"; else ok "carol (non-member) DENIED write"; fi

echo "=== D: can member B EDIT member A's file? (the umask/ACL design question) ==="
# D1 default umask (022 -> 644): expect group READ but NOT group WRITE
if asuser bob bash -c "echo from-bob >> $SHARE/a.txt" 2>/dev/null; then
  echo "   INFO  default-umask: bob CAN append to alice's file (already group-writable)"
else
  echo "   INFO  default-umask: bob CANNOT edit alice's file (644, group read-only) — expected; needs umask 002 or an ACL"
fi
# D2 umask 002 -> new files 664 (group-writable): expect group EDIT to work
asuser alice bash -c "umask 002; echo a2 > $SHARE/b.txt"
if asuser bob bash -c "echo b2 >> $SHARE/b.txt" 2>/dev/null; then ok "umask 002: bob CAN edit alice's shared file (full read-write collab)"; else no "umask 002 did NOT enable group edit"; fi
# D3 default POSIX ACL (umask-independent group rwx): the robust mechanism
setfacl -d -m group:"$GRP":rwx "$SHARE" 2>/dev/null
asuser alice bash -c "echo a3 > $SHARE/c.txt"   # default umask, but the default ACL forces g+rwx
if asuser bob bash -c "echo b3 >> $SHARE/c.txt" 2>/dev/null; then ok "default ACL: bob CAN edit alice's file REGARDLESS of umask (robust)"; else no "default ACL did not force group-write"; fi

echo "======================================================================"
echo "[user-vol] gates PASS=$P FAIL=$F"
if [ "$F" = 0 ]; then
  echo "[user-vol] VERDICT: ownership pin + grd chown + 0700 isolation + 2770 shared-folder all hold."
  echo "           Read the D-block: it tells us whether the shared feature needs umask 002, a"
  echo "           default ACL (recommended — umask-independent), or both, for full read-write collab."
  exit 0
else
  echo "[user-vol] VERDICT: NOT green — see the FAILs above."
  exit 1
fi
RUNNER
rc=$?
[ "$rc" = 0 ] && log "user-volumes spike GREEN." || err "user-volumes spike FAILED (rc=$rc)."
exit "$rc"
