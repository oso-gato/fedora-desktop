#!/bin/bash
# fedora-desktop — NON-VAULT cloud sync (rclone only; NO daemon).
# =============================================================================
# PURPOSE (policy/CLAUDE.md "NON-VAULT CLOUD ACCESS"):
#   Google Drive + OneDrive serve NON-vault files only, via rclone — `mount`
#   (on-demand) for browsing, plus delete-guarded `bisync` for chosen working
#   folders. NO abraunegg onedrive daemon. NEVER touches the Obsidian vault
#   (Obsidian Sync + bin/vault-gitsync.sh own that — see the hard guard below).
#
# HOW THE ENTRYPOINT RUNS THIS:
#   The PID-1 entrypoint launches us as `core` inside a respawn loop with
#   XDG_RUNTIME_DIR=/run/user/1000 exported. We are therefore a long-running
#   FOREGROUND loop: we set up the mounts + do one bisync pass, then sleep the
#   interval and loop. If we exit, the entrypoint waits 30s and re-launches us.
#   We are launched ONLY if this file exists; absence is tolerated (box still
#   boots). We also no-op cleanly when nothing is configured.
#
# RUNS AS: core (uid 1000). rclone config + OAuth tokens live on the home
#   volume at ~/.config/rclone/rclone.conf (authorized in-desktop via Firefox,
#   per policy). Tokens never enter an image layer (Principle 5).
#
# SAFETY MODEL for the bidirectional path (bisync MUST be recoverable):
#   * --resync runs EXACTLY ONCE per folder, gated by a sentinel in ~/.cache,
#     so a transient empty side can never trigger a destructive resync again.
#   * --check-access requires a RCLONE_TEST marker on BOTH ends → bisync aborts
#     rather than mirror a half-mounted / empty remote.
#   * --max-delete 25 caps deletions per run; a mass-delete aborts the run.
#   * --conflict-resolve newer keeps both sides' edits sane (loser is renamed).
#   * --backup-dir keeps every overwritten/deleted file → nothing is truly lost.
# =============================================================================
set -u

log() { printf '%s [cloud-sync] %s\n' "$(date -Iseconds)" "$*"; }

# ---- configuration (override via env or the config file below) --------------
# A small, sourced config lets Arthur pick remotes + folders without editing
# this script. Absent → built-in defaults (which themselves no-op if the
# remotes don't exist). Lives on the home volume, outside any image layer.
CLOUD_SYNC_CONF="${CLOUD_SYNC_CONF:-/home/core/.config/fedora-desktop/cloud-sync.conf}"

# Defaults (overridable in the conf file):
#   VAULT_PATH        — the Obsidian vault; HARD-EXCLUDED from every sync path.
#   SYNC_INTERVAL     — seconds between bisync passes.
#   RCLONE_REMOTES    — space-separated remote names to MOUNT on-demand.
#   BISYNC_PAIRS      — newline/space list of "remote:subpath|/local/path"
#                       entries to keep bidirectionally in sync.
#   MOUNT_BASE        — where on-demand mounts land.
VAULT_PATH="${VAULT_PATH:-/home/core/obsidian/2nd-brain}"
SYNC_INTERVAL="${SYNC_INTERVAL:-300}"
RCLONE_REMOTES="${RCLONE_REMOTES:-gdrive onedrive}"
MOUNT_BASE="${MOUNT_BASE:-/home/core/cloud}"
MAX_DELETE="${MAX_DELETE:-25}"
# Default bisync pairs: empty. Arthur opts folders in via the conf file, e.g.
#   BISYNC_PAIRS="gdrive:Working|/home/core/cloud-sync/gdrive-working
#                 onedrive:Documents|/home/core/cloud-sync/onedrive-docs"
BISYNC_PAIRS="${BISYNC_PAIRS:-}"

# shellcheck disable=SC1090
[ -f "$CLOUD_SYNC_CONF" ] && { log "loading config $CLOUD_SYNC_CONF"; . "$CLOUD_SYNC_CONF"; }

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/1000}"
export HOME="${HOME:-/home/core}"

CACHE_DIR="$HOME/.cache/fedora-desktop/cloud-sync"
BACKUP_ROOT="$HOME/.cloud-sync-backups"
mkdir -p "$CACHE_DIR" "$BACKUP_ROOT" "$MOUNT_BASE"

# ---- hard vault guard -------------------------------------------------------
# Refuse to mount or bisync anything whose LOCAL path falls inside the vault.
# This is the mechanical backstop for the policy rule "never point a generic
# OS-level file-sync at the vault". A misconfiguration that aimed a bisync pair
# at the vault would shadow it with a remote and risk vault data loss — so we
# normalize both paths and reject overlap in either direction.
canon() { readlink -m -- "$1" 2>/dev/null || printf '%s' "$1"; }
VAULT_CANON="$(canon "$VAULT_PATH")"
inside_vault() {
    local p; p="$(canon "$1")"
    case "$p/" in
        "$VAULT_CANON"/*) return 0 ;;   # p is the vault or below it
    esac
    case "$VAULT_CANON/" in
        "$p"/*) return 0 ;;             # p is an ancestor that contains the vault
    esac
    [ "$p" = "$VAULT_CANON" ] && return 0
    return 1
}

# ---- rclone presence (defense; the rpm is baked, but tolerate absence) ------
if ! command -v rclone >/dev/null 2>&1; then
    log "rclone not found on PATH — cloud sync disabled (box still runs). Sleeping."
    while true; do sleep 3600; done
fi

# ---- which remotes actually exist in the rclone config? ---------------------
# rclone listremotes prints "name:" per configured remote. We only act on
# remotes that are BOTH requested and configured — an un-authorized remote is
# simply skipped (no error spam), so first boot before Firefox-OAuth is clean.
configured_remotes() { rclone listremotes 2>/dev/null | sed 's/:$//'; }

remote_is_configured() {
    local want="$1" r
    for r in $(configured_remotes); do [ "$r" = "$want" ] && return 0; done
    return 1
}

# =============================================================================
# on-demand MOUNTs (browse the whole remote; writes cached then flushed)
# =============================================================================
# --vfs-cache-mode writes: local writes are staged then uploaded (needed for
# normal editor save semantics over a network FS). --daemon would background
# rclone; we DON'T use it — we keep mounts as tracked children of THIS loop so
# they die with us and the entrypoint's respawn re-establishes them cleanly.
declare -a MOUNT_PIDS=()
declare -a MOUNT_POINTS=()

start_mounts() {
    local r mp
    for r in $RCLONE_REMOTES; do
        if ! remote_is_configured "$r"; then
            log "remote '$r' not configured yet (authorize in Firefox) — skipping mount"
            continue
        fi
        mp="$MOUNT_BASE/$r"
        if inside_vault "$mp"; then
            log "REFUSING to mount '$r' at $mp — inside the vault ($VAULT_CANON)"
            continue
        fi
        mkdir -p "$mp"
        # Already mounted (e.g. a stale mount survived a crash)? skip.
        if mountpoint -q "$mp" 2>/dev/null; then
            log "mount $mp already live — skipping"
            continue
        fi
        log "mounting $r: -> $mp (vfs-cache-mode=writes)"
        rclone mount "$r:" "$mp" \
            --vfs-cache-mode writes \
            --vfs-cache-max-age 24h \
            --dir-cache-time 12h \
            --umask 077 \
            --log-level INFO \
            >>"$CACHE_DIR/mount-$r.log" 2>&1 &
        MOUNT_PIDS+=("$!")
        MOUNT_POINTS+=("$mp")
    done
}

cleanup_mounts() {
    local i
    for i in "${!MOUNT_PIDS[@]}"; do
        kill "${MOUNT_PIDS[$i]}" 2>/dev/null || true
    done
    for i in "${!MOUNT_POINTS[@]}"; do
        fusermount -uz "${MOUNT_POINTS[$i]}" 2>/dev/null || true
    done
}
# On exit (incl. the entrypoint's SIGTERM to the process group), unmount cleanly
# so we don't leave broken FUSE mounts the respawn would trip over.
trap 'log "received signal, tearing down mounts"; cleanup_mounts; exit 0' TERM INT
trap 'cleanup_mounts' EXIT

# =============================================================================
# delete-guarded BISYNC for chosen working folders
# =============================================================================
# Each BISYNC_PAIRS entry is "remote:subpath|/local/path".
parse_pairs() {
    # Emit one "remote:subpath /local/path" line per configured pair.
    printf '%s\n' $BISYNC_PAIRS | while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        local remote_side local_side
        remote_side="${entry%%|*}"
        local_side="${entry#*|}"
        [ "$remote_side" = "$entry" ] && { log "bad BISYNC_PAIRS entry (no '|'): $entry" >&2; continue; }
        printf '%s\t%s\n' "$remote_side" "$local_side"
    done
}

bisync_one() {
    local remote_side="$1" local_side="$2"
    local remote_name="${remote_side%%:*}"
    local key; key="$(printf '%s' "$remote_side" | tr '/:' '__')"
    local sentinel="$CACHE_DIR/resynced-$key"
    local backup_dir="$BACKUP_ROOT/$key/$(date +%Y%m%d-%H%M%S)"

    if ! remote_is_configured "$remote_name"; then
        log "bisync '$remote_side' skipped — remote '$remote_name' not configured"
        return 0
    fi
    if inside_vault "$local_side"; then
        log "REFUSING bisync '$remote_side' <-> '$local_side' — local side is inside the vault"
        return 0
    fi
    mkdir -p "$local_side"

    # Common, recoverable flags.
    local -a common=(
        --create-empty-src-dirs
        --conflict-resolve newer
        --conflict-loser pathname
        --max-delete "$MAX_DELETE"
        --backup-dir1 "$backup_dir/local"
        --backup-dir2 "$backup_dir/remote"
        --log-level INFO
    )

    if [ ! -f "$sentinel" ]; then
        # FIRST EVER pass for this pair: establish baseline listings. --resync
        # is the only non-delete-guarded mode, so we run it exactly once and
        # stamp the sentinel. We still pass --max-delete as a backstop.
        log "bisync FIRST-RUN --resync for $remote_side <-> $local_side"
        if rclone bisync "$remote_side" "$local_side" \
                --resync --resync-mode newer "${common[@]}" \
                >>"$CACHE_DIR/bisync-$key.log" 2>&1; then
            date -Iseconds > "$sentinel"
            log "bisync baseline established for $remote_side (sentinel written)"
        else
            log "bisync --resync FAILED for $remote_side — see bisync-$key.log; will retry next pass"
        fi
        return 0
    fi

    # STEADY STATE: delete-guarded, access-checked bidirectional sync.
    # --check-access aborts unless a RCLONE_TEST marker exists on BOTH ends —
    # the guard against syncing into a half-mounted / wiped remote.
    log "bisync $remote_side <-> $local_side (max-delete=$MAX_DELETE, backups -> $backup_dir)"
    if ! rclone bisync "$remote_side" "$local_side" \
            --check-access --check-filename RCLONE_TEST \
            "${common[@]}" \
            >>"$CACHE_DIR/bisync-$key.log" 2>&1; then
        log "bisync run failed for $remote_side (guard tripped or transient) — see bisync-$key.log"
        log "  if intentional (you reorganized a side), re-baseline: rm '$sentinel' to force one --resync"
    fi
}

run_bisync_pass() {
    [ -n "$BISYNC_PAIRS" ] || { log "no BISYNC_PAIRS configured — mounts only"; return 0; }
    parse_pairs | while IFS=$'\t' read -r remote_side local_side; do
        [ -n "$remote_side" ] || continue
        bisync_one "$remote_side" "$local_side"
    done
}

# =============================================================================
# main loop
# =============================================================================
log "starting (vault HARD-EXCLUDED at $VAULT_CANON; interval=${SYNC_INTERVAL}s)"
start_mounts

while true; do
    # Re-establish any mount that died (rclone child crashed) without a full
    # restart — keeps the desktop's cloud folders live between bisync passes.
    for i in "${!MOUNT_POINTS[@]}"; do
        mp="${MOUNT_POINTS[$i]}"
        if ! mountpoint -q "$mp" 2>/dev/null; then
            log "mount $mp dropped — re-establishing on next start_mounts sweep"
            MOUNT_PIDS=(); MOUNT_POINTS=()
            start_mounts
            break
        fi
    done

    run_bisync_pass
    sleep "$SYNC_INTERVAL"
done
