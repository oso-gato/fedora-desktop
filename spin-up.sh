#!/usr/bin/env bash
# spin-up.sh — the interactive "spin-up container" wizard for fedora-desktop.
# ============================================================================
# Asks the operator the deploy-contract questions, then hands off to run.sh:
#   1. core's secrets (RDP/system password + the public Guacamole web password)
#   2. public web port + the optional Dev/VPS fleet SSH tiles + Tailscale auth key
#   3. HOW MANY additional users beyond core (0-5)
#   4. for EACH user: username, password, and fleet access (none|dev|host|both)
# Then it exports the env and exec's run.sh. (run.sh remains the non-interactive
# deploy contract; a scripted/host-claudebox deploy can set the same env + call it
# directly. This wizard just gathers the answers interactively — Principle 5: every
# secret is read at the prompt, exported only to the child run.sh, never written here.)
set -euo pipefail
cd "$(dirname "$0")"
# Lineage (xrdp/grd) is resolved BELOW, after the prompt helpers — the interactive
# selector uses ask(), so it must come after ask() is defined (override: LINEAGE=grd).

# --- prompt helpers (prompts + status go to stderr so $() captures only the value) ---
ask() {  # ask "<prompt>" ["<default>"]
  local p="$1" d="${2:-}" v
  read -r -p "$p${d:+ [$d]}: " v </dev/tty
  printf '%s' "${v:-$d}"
}
ask_secret() {  # ask_secret "<prompt>" [min-length] — hidden, length-floored, confirmed
  local p="$1" min="${2:-0}" a b
  while :; do
    read -rs -p "$p: " a </dev/tty; echo >&2
    [ -n "$a" ] || { echo "  (empty — try again)" >&2; continue; }
    if [ "${#a}" -lt "$min" ]; then echo "  too short — need >= $min chars (or choose Generate)" >&2; continue; fi
    read -rs -p "$p (confirm): " b </dev/tty; echo >&2
    [ "$a" = "$b" ] && { printf '%s' "$a"; return 0; }
    echo "  passwords differ — try again" >&2
  done
}
# Diceware passphrase generator (the "crypto-wallet seed phrase" model): N random words
# from the bundled EFF wordlist -> high entropy (6 words ~ 77 bits) yet typable on mobile.
# Falls back to a high-entropy random string if the wordlist is somehow absent.
WORDLIST="$(dirname "$0")/passphrase-wordlist.txt"
gen_passphrase() {  # gen_passphrase [nwords]
  local n="${1:-6}"
  if [ -r "$WORDLIST" ]; then shuf -n "$n" "$WORDLIST" | paste -sd'-' -
  else openssl rand -base64 24 2>/dev/null | tr -d '/+=' | cut -c1-28; fi
}
PASS_MIN=20
choose_password() {  # choose_password "<label>" — generate (recommended) or type-your-own (>= PASS_MIN)
  local label="$1" mode pw
  mode="$(ask "  $label — [G]enerate a strong passphrase, or type your [o]wn?" G)"
  case "$mode" in
    o|own|O|OWN) ask_secret "  $label (min ${PASS_MIN} chars)" "$PASS_MIN" ;;
    *) pw="$(gen_passphrase 6)"
       { echo "  >> GENERATED $label:  $pw"
         echo "     SAVE THIS NOW (like a wallet seed phrase) — it is not stored or shown again."; } >&2
       printf '%s' "$pw" ;;
  esac
}
valid_user() {  # 0 if a legal, non-reserved username
  printf '%s' "$1" | grep -Eq '^[a-z_][a-z0-9_-]{0,30}$' || return 1
  case "$1" in core|root|tomcat|daemon|bin|sys|nobody) return 1 ;; esac
  return 0
}

# Lineage: xrdp (XFCE/X11, production) or grd (GNOME-Wayland headless, systemd-PID-1 —
# EXPERIMENTAL, needs a cgroup-v2-delegating host). Override non-interactively: LINEAGE=grd.
# The deploy-contract questions below are identical for both; only the run script differs.
# (Resolved HERE, after the helpers above, because the interactive selector uses ask().)
LINEAGE="${LINEAGE:-}"
if [ -z "$LINEAGE" ]; then
  while :; do
    LINEAGE="$(ask 'Lineage? (xrdp = XFCE/X11, production | grd = GNOME-Wayland headless, EXPERIMENTAL)' xrdp)"
    case "$LINEAGE" in xrdp|grd) break ;; *) echo "  pick: xrdp | grd" >&2 ;; esac
  done
fi
RUN_SCRIPT=./run.sh; [ "$LINEAGE" = grd ] && RUN_SCRIPT=./run.sh.grd
[ -x "$RUN_SCRIPT" ] || { echo "spin-up: $RUN_SCRIPT not found/executable in $(pwd)" >&2; exit 1; }
[ "$LINEAGE" = grd ] && echo "spin-up: grd lineage — needs a cgroup-v2-delegating host; EXPERIMENTAL (xrdp is production). On one host, give grd a DISTINCT WEB_PORT from any xrdp box." >&2

echo "=== fedora-desktop spin-up ===" >&2
RDP_PW="$(choose_password "core's RDP/system password")"
GUAC_PW="$(choose_password "core's Guacamole WEB password (the only public door)")"
WEB_PORT="$(ask 'Public web-door port' 8443)"
# Host deploy pulls the GHCR-published image; run.sh's localhost/ default is for in-box
# self-validation only (the host never builds locally — CI builds). Default to GHCR here.
IMAGE="${IMAGE:-$(ask 'Image ref (host deploy = ghcr.io; localhost/ = in-box self-validation only)' 'ghcr.io/oso-gato/fedora-desktop:latest')}"

# Fleet SSH tiles: clientless browser-SSH tiles to OTHER tailnet hosts, on the SAME public web door
# (VPN-slot-free fleet access — see ZTNA-ACCESS.md). Each tile's LABEL == its tailnet HOSTNAME; add
# as many as you like by picking from the live tailnet. core (admin) ALWAYS gets ALL tiles; each
# extra user gets a chosen SUBSET (asked per-user below). Auth is KEYLESS Tailscale-SSH — the
# target's tailnet `ssh` ACL must grant THIS node action `accept` (NOT `check`: a headless node
# can't satisfy check's browser re-auth, so the tile would hang — confirmed on a real deploy).
# FLEET_SSH_KEY is only for a target whose REAL sshd is on :22 (Tailscale SSH off / a non-tailnet
# bastion). Power users can export $FLEET_SSH ("label host port user", ';'-separated) to skip the picker.
tnet_peers() { tailscale status 2>/dev/null | awk '$1 ~ /^100\./ {print $1"\t"$2}'; }
declare -a FLEET_TILE=()                       # ordered tile labels (== tailnet hostnames), for the per-user grant prompt
if [ -z "${FLEET_SSH:-}" ]; then
  # List only SSH-REACHABLE peers (a live :22 probe — a host with no sshd, e.g. a phone, can't be a
  # tile), numbered. Store the resolved tailnet IP (the container's tailscaled runs without
  # --accept-dns, so MagicDNS names may not resolve in-container; the IP always does).
  declare -a _pk_ip=() _pk_name=()
  if command -v tailscale >/dev/null 2>&1; then
    echo "  Scanning tailnet for SSH-reachable hosts (:22)…" >&2
    while IFS=$'\t' read -r _ip _name; do
      [ -n "$_ip" ] || continue
      if timeout 2 bash -c ">/dev/tcp/${_ip}/22" 2>/dev/null; then
        _pk_ip+=("$_ip"); _pk_name+=("$_name")
        printf '    %2d) %-24s %s\n' "${#_pk_ip[@]}" "$_name" "$_ip" >&2
      fi
    done < <(tnet_peers)
    [ "${#_pk_ip[@]}" -eq 0 ] && echo "    (no SSH-reachable peers found — type a hostname/IP)" >&2
  else
    echo "  (tailscale CLI not on this host — type hostnames/IPs; can't validate or probe)" >&2
  fi
  echo "  Add fleet tiles — enter a NUMBER above, or a tailnet hostname/IP. Blank = done." >&2
  FLEET_SSH=""
  while :; do
    sel="$(ask '    tile (number | hostname | 100.x IP | blank=done)' '')"
    [ -z "$sel" ] && break
    _tn=""; _ti=""
    if printf '%s' "$sel" | grep -Eq '^[0-9]+$' && [ "$sel" -ge 1 ] && [ "$sel" -le "${#_pk_ip[@]}" ]; then
      _tn="${_pk_name[$((sel-1))]}"; _ti="${_pk_ip[$((sel-1))]}"
    elif printf '%s' "$sel" | grep -Eq '^100\.'; then
      _ti="$sel"; _tn="$(tnet_peers | awk -v ip="$sel" -F'\t' '$1==ip{print $2; exit}')"; [ -n "$_tn" ] || _tn="$sel"
    elif command -v tailscale >/dev/null 2>&1; then
      _ti="$(tnet_peers | awk -v n="$sel" -F'\t' '$2==n{print $1; exit}')"
      [ -n "$_ti" ] && _tn="$sel" || { echo "      ✗ '$sel' is not a live tailnet peer — use a number, a listed name, or a 100.x IP" >&2; continue; }
    else
      _tn="$sel"; _ti="$sel"                    # no CLI: accept verbatim (must resolve in-container)
    fi
    case " ${FLEET_TILE[*]:-} " in *" $_tn "*) echo "      (already added '$_tn')" >&2; continue ;; esac
    FLEET_SSH="${FLEET_SSH:+${FLEET_SSH};}${_tn} ${_ti} 22 core"
    FLEET_TILE+=("$_tn")
    echo "      ✓ tile '$_tn' → $_ti" >&2
  done
fi
# Tile labels for the per-user grant prompt — derive from FLEET_SSH so a pre-set $FLEET_SSH works too.
if [ -n "${FLEET_SSH:-}" ] && [ "${#FLEET_TILE[@]}" -eq 0 ]; then
  while IFS=' ' read -r _l _rest; do [ -n "$_l" ] && FLEET_TILE+=("$_l"); done < <(printf '%s\n' "$FLEET_SSH" | tr ';' '\n')
fi
TS_AUTHKEY="$(ask 'Tailscale auth key (blank = interactive join later)' '')"

# --- how many additional users, then per-user name / password / fleet access ---
N=""
while ! printf '%s' "$N" | grep -Eq '^[0-5]$'; do
  N="$(ask 'How many ADDITIONAL users beyond core? (0-5)' 0)"
done
seen=" core "
i=0
while [ "$i" -lt "$N" ]; do
  i=$((i + 1))
  echo "--- additional user $i of $N ---" >&2
  u=""
  while :; do
    u="$(ask "  username (lowercase, not core/root)")"
    valid_user "$u" || { echo "    invalid — need ^[a-z_][a-z0-9_-]{0,30}$, not reserved" >&2; continue; }
    case "$seen" in *" $u "*) echo "    duplicate username" >&2; continue ;; esac
    break
  done
  seen="$seen$u "
  p="$(choose_password "password for '$u'")"
  # Fleet grant: 'none', 'all', or a SUBSET of the tiles by number (e.g. '1,3'). Stored as
  # USER{i}_ACCESS = none | all | comma-list-of-hostnames; guac-db-provision exact-matches it.
  if [ "${#FLEET_TILE[@]}" -eq 0 ]; then
    a=none                                              # no fleet tiles exist -> nothing to grant
  else
    echo "    Fleet tiles available for '$u':" >&2
    _k=0; for _t in "${FLEET_TILE[@]}"; do _k=$((_k+1)); printf '      %2d) %s\n' "$_k" "$_t" >&2; done
    while :; do
      sel="$(ask "    which tiles for '$u'? (numbers like 1,3 | all | none)" none)"
      case "$sel" in
        none|NONE|None) a=none; break ;;
        all|ALL|All)    a=all;  break ;;
        *) a=""; _ok=1
           for _num in $(printf '%s' "$sel" | tr ',' ' '); do
             if printf '%s' "$_num" | grep -Eq '^[0-9]+$' && [ "$_num" -ge 1 ] && [ "$_num" -le "${#FLEET_TILE[@]}" ]; then
               a="${a:+$a,}${FLEET_TILE[$((_num-1))]}"
             else echo "      ✗ '$_num' is not a tile number (1-${#FLEET_TILE[@]})" >&2; _ok=0; break; fi
           done
           [ "$_ok" = 1 ] && [ -n "$a" ] && break ;;
      esac
    done
  fi
  export "USER${i}_NAME=$u" "USER${i}_PW=$p" "USER${i}_ACCESS=$a"
done

# --- optional shared collaboration folder (only meaningful with >=1 extra user) ---
# A 2770 group-owned /home/shared that core + every extra user can read/write (default POSIX ACL
# -> full read-write regardless of umask). Homes stay 0700-isolated; the shared GROUP is
# supplementary only. Host-validated (validation/user-volumes-spike.sh). Override: ENABLE_SHARED=1.
ENABLE_SHARED="${ENABLE_SHARED:-}"
if [ -z "$ENABLE_SHARED" ] && [ "$N" -gt 0 ]; then
  [ "$(ask 'Add a SHARED collaboration folder (/home/shared) all desktop users can read+write? (y/n)' n)" = y ] && ENABLE_SHARED=1
fi

# --- summary + confirm ---
{
  echo; echo "=== summary ==="
  echo "  web door  : https://<host>:${WEB_PORT}/guacamole/   (login: core / <GUAC_PW>)"
  echo "  fleet tiles: ${FLEET_SSH:-(none)}"
  echo "  shared fldr: ${ENABLE_SHARED:+/home/shared — all desktop users, read+write (group deskshare)}${ENABLE_SHARED:-(none)}"
  echo "  core       : admin — Desktop + Dev + VPS"
  j=0
  while [ "$j" -lt "$N" ]; do
    j=$((j + 1)); eval "echo \"  user $j     : \$USER${j}_NAME — own login + Desktop; fleet access = \$USER${j}_ACCESS\""
  done
} >&2
[ "$(ask 'Spin up the container now? (y/n)' y)" = y ] || { echo "aborted (nothing launched)" >&2; exit 0; }

export RDP_PW GUAC_PW WEB_PORT FLEET_SSH TS_AUTHKEY IMAGE ENABLE_SHARED
exec "$RUN_SCRIPT"
