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
[ -x ./run.sh ] || { echo "spin-up: ./run.sh not found/executable in $(pwd)" >&2; exit 1; }

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

echo "=== fedora-desktop spin-up ===" >&2
RDP_PW="$(choose_password "core's RDP/system password")"
GUAC_PW="$(choose_password "core's Guacamole WEB password (the only public door)")"
WEB_PORT="$(ask 'Public web-door port' 8443)"

# core is the admin and ALWAYS gets the Dev/VPS fleet tiles — there is NO gate at the
# core level. FLEET_SSH just DEFINES where the fleet targets live (env-overridable for
# non-standard hostnames); WHICH additional users ALSO get them is asked per-user below.
FLEET_SSH="${FLEET_SSH:-dev fedora-dev 22 core;vps fedora-bootstrap 22 core}"
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
  a=""
  while :; do
    a="$(ask "  Show the Dev/VPS fleet SSH tiles for '$u'? (none|dev|host|both)" none)"
    case "$a" in none|dev|host|both) break ;; *) echo "    pick: none | dev | host | both" >&2 ;; esac
  done
  export "USER${i}_NAME=$u" "USER${i}_PW=$p" "USER${i}_ACCESS=$a"
done

# --- summary + confirm ---
{
  echo; echo "=== summary ==="
  echo "  web door  : https://<host>:${WEB_PORT}/guacamole/   (login: core / <GUAC_PW>)"
  echo "  fleet tiles: ${FLEET_SSH:-(none)}"
  echo "  core       : admin — Desktop + Dev + VPS"
  j=0
  while [ "$j" -lt "$N" ]; do
    j=$((j + 1)); eval "echo \"  user $j     : \$USER${j}_NAME — own login + Desktop; fleet access = \$USER${j}_ACCESS\""
  done
} >&2
[ "$(ask 'Spin up the container now? (y/n)' y)" = y ] || { echo "aborted (nothing launched)" >&2; exit 0; }

export RDP_PW GUAC_PW WEB_PORT FLEET_SSH TS_AUTHKEY
exec ./run.sh
