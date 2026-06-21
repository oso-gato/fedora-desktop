#!/bin/bash
# fedora-desktop — VAULT git-sync (periodic, history-preserving).
# =============================================================================
# PURPOSE (policy/CLAUDE.md "VAULT & WIKI" -> SYNC):
#   Keep the GitHub mirror of the Obsidian vault (bear-alchemist/2nd-brain,
#   PRIVATE — it carries `confidential: true` content) current with a
#   ClaudeBox-managed periodic git sync: add/commit + pull --rebase + push, on
#   an interval. This is NOT the Obsidian Git plugin and NOT a generic OS-level
#   cloud-drive sync (rclone never touches the vault — see bin/cloud-sync.sh).
#   Live cross-device editing is Obsidian Sync (paid); this git mirror is the
#   versioned, history-preserving backstop.
#
#   AUTOMATIC (not click-gated) and HISTORY-PRESERVING: we NEVER force-push, so
#   every state stays git-recoverable. The promotion-gate hook (gate-push.sh)
#   exempts EXACTLY this vault push via a narrow allowlist; everything here is
#   confined to `git -C "$VAULT_PATH"`.
#
# HOW THE ENTRYPOINT RUNS THIS:
#   PID-1 launches us as `core` in a respawn loop with XDG_RUNTIME_DIR set. We
#   are a long-running FOREGROUND loop: sync, sleep the interval, repeat. We are
#   launched ONLY if this file exists, and we SKIP CLEANLY (sleep-loop, no
#   crash) when the vault or its git remote isn't present yet — so the box boots
#   fine before Arthur has cloned the vault locally.
#
# CREDENTIAL (policy "CREDENTIAL", SECRET ISOLATION "irreducible residue"):
#   Pushes with a LEAST-PRIVILEGE, vault-scoped credential (write to the vault
#   repo only; no admin/`workflow`). This orchestrator holds the vault + that
#   token and runs as uid 1000 — that residue is acknowledged in the law. It
#   parses NO untrusted content (that is ingest-sandbox.sh's job), so it stays
#   "small and boring". The credential is provided by the git remote/credential
#   helper on the home volume (e.g. a `https://x-access-token:<PAT>@github.com/`
#   remote URL, or gh's credential helper), NEVER baked into a layer and NEVER
#   echoed here.
# =============================================================================
set -u

log() { printf '%s [vault-gitsync] %s\n' "$(date -Iseconds)" "$*"; }

# ---- configuration ----------------------------------------------------------
VAULT_CONF="${VAULT_CONF:-/home/core/.config/fedora-desktop/vault-gitsync.conf}"

VAULT_PATH="${VAULT_PATH:-/home/core/obsidian/2nd-brain}"
VAULT_REMOTE="${VAULT_REMOTE:-origin}"
VAULT_BRANCH="${VAULT_BRANCH:-}"          # empty => current branch
VAULT_SYNC_INTERVAL="${VAULT_SYNC_INTERVAL:-900}"   # 15 min default
# Identity for the auto-commits (distinct from the per-repo claudebox identity
# so vault history is attributable to the sync, not to dev work).
VAULT_GIT_NAME="${VAULT_GIT_NAME:-fedora-desktop vault-sync}"
VAULT_GIT_EMAIL="${VAULT_GIT_EMAIL:-vault-sync@fedora-desktop.local}"

# shellcheck disable=SC1090
[ -f "$VAULT_CONF" ] && { log "loading config $VAULT_CONF"; . "$VAULT_CONF"; }

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/1000}"
export HOME="${HOME:-/home/core}"
# Non-interactive: never block the loop on a credential prompt. A missing
# credential => push fails => logged => retried next interval (no hang).
export GIT_TERMINAL_PROMPT=0
export GIT_ASKPASS=/bin/true

# ---- presence guards (skip cleanly, never crash) ----------------------------
if ! command -v git >/dev/null 2>&1; then
    log "git not on PATH — vault sync disabled (box still runs). Sleeping."
    while true; do sleep 3600; done
fi

vault_ready() {
    if [ ! -d "$VAULT_PATH" ]; then
        log "vault path '$VAULT_PATH' absent — not cloned locally yet; skipping this pass"
        return 1
    fi
    if [ ! -d "$VAULT_PATH/.git" ]; then
        log "'$VAULT_PATH' is not a git repo (no .git) — Obsidian Sync may own it but no mirror; skipping"
        return 1
    fi
    if ! git -C "$VAULT_PATH" remote get-url "$VAULT_REMOTE" >/dev/null 2>&1; then
        log "vault has no remote '$VAULT_REMOTE' — set it once to enable the mirror push; skipping push"
        return 2   # repo exists but no remote: we can commit locally, not push
    fi
    return 0
}

ensure_identity() {
    # Set the commit identity locally (idempotent; vault-scoped, not global).
    git -C "$VAULT_PATH" config user.name  >/dev/null 2>&1 || \
        git -C "$VAULT_PATH" config user.name  "$VAULT_GIT_NAME"
    git -C "$VAULT_PATH" config user.email >/dev/null 2>&1 || \
        git -C "$VAULT_PATH" config user.email "$VAULT_GIT_EMAIL"
}

current_branch() {
    if [ -n "$VAULT_BRANCH" ]; then printf '%s' "$VAULT_BRANCH"; return; fi
    git -C "$VAULT_PATH" symbolic-ref --quiet --short HEAD 2>/dev/null || printf 'main'
}

# ---- one sync pass: commit local edits, rebase remote, push -----------------
sync_once() {
    local ready branch
    vault_ready; ready=$?
    [ "$ready" -eq 1 ] && return 0     # vault not present — nothing to do
    ensure_identity
    branch="$(current_branch)"

    # 1) Stage + commit any local changes. Obsidian writes plain files; we
    #    snapshot whatever changed since last pass. -A captures adds, edits,
    #    deletes, renames. A meaningful message records the host + a file count.
    git -C "$VAULT_PATH" add -A
    if git -C "$VAULT_PATH" diff --cached --quiet; then
        log "no local vault changes to commit"
    else
        local n; n="$(git -C "$VAULT_PATH" diff --cached --name-only | wc -l | tr -d ' ')"
        local msg; msg="vault sync: ${n} change(s) @ $(date -Iseconds) [fedora-desktop]"
        if git -C "$VAULT_PATH" commit -q -m "$msg"; then
            log "committed: $msg"
        else
            log "commit failed (see git output) — continuing to rebase/push attempt"
        fi
    fi

    # If there's no usable remote, we're done after the local commit. The vault
    # is still versioned locally and recoverable; the push resumes once Arthur
    # adds the remote.
    if [ "$ready" -eq 2 ]; then
        log "no remote configured — local commit only this pass"
        return 0
    fi

    # 2) Integrate remote changes BEFORE pushing — HISTORY-PRESERVING.
    #    pull --rebase replays our local commits on top of the remote tip; on a
    #    real content conflict we ABORT the rebase (leaving the working tree
    #    intact) rather than auto-resolve, and retry next pass. We never reset
    #    or force, so nothing is lost.
    if ! git -C "$VAULT_PATH" pull --rebase --autostash "$VAULT_REMOTE" "$branch" \
            >/dev/null 2>&1; then
        log "pull --rebase hit a conflict or transient error on '$branch' — aborting rebase, will retry next pass"
        git -C "$VAULT_PATH" rebase --abort 2>/dev/null || true
        # Autostash is popped automatically on abort; ensure no stash residue.
        return 0
    fi

    # 3) Push. NEVER --force / --force-with-lease: a non-fast-forward push fails
    #    loudly and we re-pull next pass. History stays append-only + recoverable.
    if git -C "$VAULT_PATH" push "$VAULT_REMOTE" "$branch" >/dev/null 2>&1; then
        log "pushed '$branch' -> $VAULT_REMOTE"
    else
        log "push failed (auth/network/non-ff?) on '$branch' — NOT forcing; retry next pass"
    fi
}

# =============================================================================
# main loop
# =============================================================================
log "starting (vault=$VAULT_PATH remote=$VAULT_REMOTE interval=${VAULT_SYNC_INTERVAL}s; never force-push)"
trap 'log "received signal, exiting"; exit 0' TERM INT

while true; do
    sync_once || log "sync pass errored (handled) — continuing"
    sleep "$VAULT_SYNC_INTERVAL"
done
