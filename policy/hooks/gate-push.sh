#!/usr/bin/env bash
# fedora-desktop — PROMOTION-GATE PreToolUse hook  (Bash matcher)
# ============================================================================
# Stamped into the claudebox at /etc/claude-code/hooks/gate-push.sh by
# claudebox-assemble.sh, alongside managed-settings.json which wires it as a
# MANAGED PreToolUse hook on the Bash tool. Because it is a *managed* hook and
# the box runs with `allowManagedHooksOnly: true`, the agent cannot remove,
# shadow, or disable it from project/user settings.
#
# THIS BOX IS PR-ONLY — it NEVER pushes or merges any `main` (`fedora-dev` is the
#   sole merge authority — see THE FLEET). But it MUST be able to push FEATURE
#   branches autonomously, because it develops its own knowledge-work toolset and
#   opens PRs (develop -> open PR -> iterate-on-RED). So this gate is the SAME
#   REFSPEC-AWARE shape as fedora-dev's, with ONE difference: where fedora-dev
#   routes a main-touching push / a merge verb to an interactive `ask` (it is the
#   box that merges, so the click is meaningful), THIS box has nothing to approve
#   — it never merges — so it routes them to a hard DENY instead. Feature-branch
#   pushes fall through autonomously.
#
#   (History: this hook previously DENIED every `git push` incl. feature branches,
#   mechanically severing this box's ability to open/iterate its own PRs and
#   contradicting this box's own stamped law, which states feature pushes are
#   autonomous. Converged here to the fleet refspec-aware model — see the fleet
#   control-plane convergence.)
#
# VAULT EXEMPTION (this box only) — the automatic Obsidian vault git-sync
#   `git -C <vault> push` is the history-preserving vault mirror (policy/CLAUDE.md
#   "VAULT & WIKI"). It is narrowly recognised by the `git -C <vault>` form and
#   allowed without a prompt, so the exemption can't be reused as a blanket
#   `git push` allow. (The automatic sync is entrypoint-launched and never
#   traverses this hook; this only covers an agent running the sync by hand.)
#
# REFSPEC-AWARE GATE (the discriminator):
#   `git push` is NOT blanket-blocked. A push is treated as SAFE (falls through
#   silently -> the agent pushes autonomously) IFF it carries at least one
#   EXPLICIT refspec after the remote AND every DESTINATION ref is an explicit
#   non-`main`, non-`HEAD`, non-tag branch. Anything that could land on `main`
#   — `main` / `refs/heads/main`, a `HEAD`/HEAD-relative destination, a
#   `refs/tags/*` destination, a bare `git push` / `git push <remote>` with NO
#   refspec, `--all` / `--mirror` / `--tags`, or anything the parser cannot
#   confidently decompose — is UNSAFE -> DENY. FAIL CLOSED: any ambiguity
#   resolves toward DENY. The merge verbs (gh pr merge / gh pr create
#   --merge|--squash|--rebase|--auto / gh api ...merge...) ALWAYS DENY.
#
# FAIL CLOSED — the load-bearing property. Claude Code does NOT bundle `jq`, and
#   the docs say a hook that errors on a missing tool FAILS OPEN (non-zero exit
#   other than 2 -> tool proceeds). So this hook must NOT depend on jq for its
#   decision: it isolates the candidate command from the raw stdin payload with
#   pure bash parameter expansion (jq is only an optional fast-path). The SAFE
#   refspec relaxation is attempted ONLY when the command was CLEANLY isolated;
#   if isolation is uncertain, any detected push/merge resolves to DENY. The deny
#   verdict is a hand-written JSON string AND exit 2, neither of which needs jq.
#
# RESIDUAL CEILING (no in-box hook closes this — documented, not papered over):
#   PreToolUse hooks do NOT fire under `claude -p` (headless) — anthropics/claude-code
#   #40506 — so a maliciously-injected agent that spawns `claude -p` bypasses THIS hook.
#   Hard containment is managed-settings (allowManagedHooksOnly + allowManagedPermissionRulesOnly
#   + disableBypassPermissionsMode) + this box being PR-only + the require-PR ruleset on `main`.
# ============================================================================
set -uo pipefail

# --- the vault clone path the git-sync pushes (exempt). Override via env. -----
VAULT_DIR="${VAULT_PATH:-/home/core/obsidian/2nd-brain}"

# ----------------------------------------------------------------------------
# read the hook stdin payload (raw text — NO jq dependency)
# ----------------------------------------------------------------------------
payload="$(cat 2>/dev/null || true)"

# Empty payload -> nothing to gate; fall through.
[ -n "$payload" ] || exit 0

# ----------------------------------------------------------------------------
# isolate the candidate command (NO jq dependency)
# ----------------------------------------------------------------------------
# `clean=1` means we isolated the command exactly (so the SAFE refspec
# relaxation may run). `clean=0` means we are scanning a looser text and MUST
# fail closed: any detected push/merge -> DENY, never the safe path.
cmd=""
clean=0

# Optional fast-path: if jq exists, use it for an exact isolation.
if command -v jq >/dev/null 2>&1; then
    cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
    [ -n "$cmd" ] && clean=1
fi

# No-jq path: extract the "command" string field with pure bash parameter
# expansion. JSON-escaped inner quotes appear as \" in the raw payload, so we
# stash them under a placeholder, cut at the FIRST bare (value-terminating)
# quote, restore, then unescape. Robust to additional fields after `command`.
if [ "$clean" -eq 0 ]; then
    case "$payload" in
        *'"command":"'*)
            rest="${payload#*\"command\":\"}"
            rest="${rest//\\\"/$'\x01'}"   # \"  -> SOH placeholder
            cmd="${rest%%\"*}"             # cut at first unescaped quote
            cmd="${cmd//$'\x01'/\"}"       # restore inner quotes
            cmd="${cmd//\\\\/\\}"          # \\  -> \
            cmd="${cmd//\\n/ }"            # \n  -> space
            cmd="${cmd//\\t/ }"            # \t  -> space
            cmd="${cmd//\\\//\/}"          # \/  -> /
            clean=1
            ;;
        *)
            cmd="$(printf '%s' "$payload" \
                | sed -e 's/\\"/"/g' -e 's/\\\\/\\/g' -e 's/\\n/ /g' -e 's/\\t/ /g')"
            clean=0
            ;;
    esac
fi

# ----------------------------------------------------------------------------
# helpers
# ----------------------------------------------------------------------------

# deny(reason): structured deny JSON (exit-0 path) + hard-stop (exit 2). This is
# the ACTIVE verdict for any flagged push/merge on this PR-only box. No jq.
deny() {
    local reason="$1" esc
    esc="$(printf '%s' "$reason" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' ')"
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$esc"
    printf 'PROMOTION GATE: %s\n' "$reason" >&2
    exit 2
}

# normalize_cmd(text): strip git/gh OPTION noise so the SUBCOMMAND verb becomes
# adjacent to the tool name, AND so a `git push`'s refspec tokens are the only
# non-option words left after the remote.
normalize_cmd() {
    printf '%s' "$1" | sed -E '
        s/[[:space:]]+-(c|C|R|H|X|o)[[:space:]]+[^[:space:]]+/ /g
        s/[[:space:]]+--(repo|git-dir|work-tree|field|raw-field|method|header|hostname|jq|template|cache)[[:space:]]+[^[:space:]]+/ /g
        s/[[:space:]]+--[A-Za-z0-9-]+=[^[:space:]]+/ /g
        s/[[:space:]]+-[A-Za-z0-9-]+/ /g
        s/[[:space:]]+/ /g'
}

# has_git_push(text): true iff TEXT contains a `git push` verb (any form).
has_git_push() {
    local text; text="$(normalize_cmd "$1")"
    printf '%s' "$text" | grep -Eq '(^|[^[:alnum:]_./-])git([[:space:]]+-[^[:space:]]+)*[[:space:]]+push([[:space:]"};&|]|$)'
}

# scan_merge_verbs(raw): true iff RAW contains a blocked MERGE verb (NOT a push).
scan_merge_verbs() {
    local raw="$1" text
    text="$(normalize_cmd "$raw")"
    printf '%s' "$text" | grep -Eq '(^|[^[:alnum:]_./-])gh[[:space:]]+pr[[:space:]]+merge([[:space:]"};&|]|$)' && return 0
    printf '%s' "$text" | grep -Eq '(^|[^[:alnum:]_./-])gh[[:space:]]+pr[[:space:]]+create([[:space:]]|$)' \
        && printf '%s' "$raw" | grep -Eq -- '--(merge|squash|rebase|auto)([[:space:]="};&|]|$)' && return 0
    printf '%s' "$text" | grep -Eq '(^|[^[:alnum:]_./-])gh[[:space:]]+api([[:space:]]|$)' \
        && printf '%s' "$raw" | grep -Eqi 'merge' && return 0
    return 1
}

# scan_text(text): true iff TEXT contains ANY blocked push OR merge verb. Used for
# WRAPPER-script contents only — FAIL CLOSED: it does NOT refspec-parse.
scan_text() {
    local raw="$1"
    has_git_push "$raw" && return 0
    scan_merge_verbs "$raw" && return 0
    return 1
}

# is_vault_sync_push(): true iff the command is the narrow, exempt vault push —
# `git -C <VAULT_DIR> … push …` AND NOTHING ELSE. HARDENED: rejects any compound /
# multi-command payload and any payload carrying a SECOND git or push, so the
# exemption can't be reused to smuggle an arbitrary `git push origin main`.
is_vault_sync_push() {
    local c vesc gits pushes
    c="$(printf '%s' "$cmd" | tr '\n' ' ')"
    printf '%s' "$c" | grep -Eq '[;&|`]|\$\(' && return 1
    gits="$(printf '%s' "$c" | grep -oE '(^|[^[:alnum:]_./-])git([[:space:]]|$)' | wc -l)"
    pushes="$(printf '%s' "$c" | grep -oE '(^|[^[:alnum:]_])push([[:space:]"}]|$)' | wc -l)"
    [ "$gits" -eq 1 ] && [ "$pushes" -eq 1 ] || return 1
    vesc="$(printf '%s' "$VAULT_DIR" | sed 's/[][\.*^$]/\\&/g')"
    printf '%s' "$c" | grep -Eq '(^|[^[:alnum:]_])git([[:space:]]+-[^[:space:]]+)*[[:space:]]+-C[[:space:]]+'"$vesc"'([[:space:]/"]|$)' \
        && printf '%s' "$c" | grep -Eq '(^|[^[:alnum:]_])push([[:space:]"}]|$)'
}

# is_safe_push(raw): true iff RAW is a `git push` that is SAFE to run autonomously
# — at least one EXPLICIT refspec after the remote, every DESTINATION an explicit
# non-main, non-HEAD, non-tag branch. FAIL CLOSED: any ambiguity -> false (-> DENY).
is_safe_push() {
    local raw="$1" text after remote tok dst

    printf '%s' "$raw" | grep -Eq -- '(^|[^[:alnum:]_-])--(all|mirror|tags)([[:space:]=]|$)' && return 1
    printf '%s' "$raw" | grep -Eq '[`]|\$\(' && return 1
    printf '%s' "$raw" | grep -Eq '[^A-Za-z0-9._/:+ -]' && return 1
    [ "$(printf '%s' "$raw" | grep -oE '(^|[^[:alnum:]_./-])git[[:space:]]+push' | wc -l)" -le 1 ] || return 1

    text="$(normalize_cmd "$raw")"
    after="$(printf '%s' "$text" | sed -E 's/^.*git[[:space:]]+push//')"
    after="${after%%[;&|]*}"

    set -f
    # shellcheck disable=SC2086
    set -- $after
    set +f

    [ "$#" -ge 1 ] || return 1     # bare `git push` -> unsafe
    remote="$1"; shift
    [ "$#" -ge 1 ] || return 1     # remote but NO refspec -> unsafe

    for tok in "$@"; do
        tok="${tok#+}"
        case "$tok" in
            *:*) dst="${tok##*:}";;
            *)   dst="$tok";;
        esac
        [ -n "$dst" ] || return 1
        case "$dst" in
            main|refs/heads/main) return 1;;
            HEAD|HEAD*)           return 1;;
            refs/tags/*)          return 1;;
        esac
    done
    return 0
}

# ----------------------------------------------------------------------------
# 0) VAULT SYNC EXEMPTION — allow the narrow `git -C <vault> push`, no prompt.
# ----------------------------------------------------------------------------
if is_vault_sync_push; then
    exit 0
fi

# ----------------------------------------------------------------------------
# 1) MERGE verbs in the candidate command -> always DENY (this box never merges).
# ----------------------------------------------------------------------------
if scan_merge_verbs "$cmd"; then
    deny "fedora-desktop is PR-only and NEVER merges: this MERGE verb (gh pr merge / --merge|--squash|--rebase|--auto / gh api merge) is denied. Open/iterate the PR and STOP — fedora-dev merges it on Arthur's APPROVE (THE FLEET)."
fi

# ----------------------------------------------------------------------------
# 2) git push in the candidate command -> REFSPEC-AWARE.
#    Safe feature-branch push (and only when cleanly isolated) falls through
#    silently -> AUTONOMOUS. Anything main-targeting / ambiguous -> DENY.
# ----------------------------------------------------------------------------
if has_git_push "$cmd"; then
    if [ "$clean" -eq 1 ] && is_safe_push "$cmd"; then
        exit 0
    fi
    deny "fedora-desktop is PR-only and NEVER pushes main: this push could touch main (bare push / main|HEAD|tag destination / --all|--mirror|--tags / unparseable). Push an explicit non-main FEATURE-branch refspec instead (those run autonomously), then open a PR — fedora-dev merges it on Arthur's APPROVE. (The vault git-sync 'git -C <vault> push' is the sole exemption.)"
fi

# ----------------------------------------------------------------------------
# 3) WRAPPER evasion: `bash X` / `sh X` / `source X` / `. X` whose target script
#    contains a push/merge. FAIL CLOSED — script contents are NOT refspec-parsed.
# ----------------------------------------------------------------------------
scripts="$(printf '%s' "$cmd" \
    | grep -Eo '(^|[;&|"'"'"'[:space:]])(bash|sh|zsh|source|\.)[[:space:]]+[^;&|[:space:]]+' \
    | sed -E 's/.*(bash|sh|zsh|source|\.)[[:space:]]+//' \
    | tr -d '"'"'"'' \
    | sed -E 's/[]},;)`]+$//' 2>/dev/null || true)"
if [ -n "$scripts" ]; then
    while IFS= read -r s; do
        [ -n "$s" ] || continue
        if [ -r "$s" ] && [ -f "$s" ]; then
            if scan_text "$(cat "$s" 2>/dev/null || true)"; then
                deny "fedora-desktop: a wrapper script containing a git push or merge verb is denied (script contents are not refspec-parsed; fail closed). Run an explicit feature-branch push directly instead."
            fi
        fi
    done <<EOF
$scripts
EOF
fi

# ----------------------------------------------------------------------------
# 4) Not a flagged push/merge -> normal permission flow.
# ----------------------------------------------------------------------------
exit 0
