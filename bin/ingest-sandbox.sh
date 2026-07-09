#!/bin/bash
# fedora-desktop — UNTRUSTED-CONTENT INGEST SANDBOX (the real containment).
# =============================================================================
# THREAT MODEL (policy/CLAUDE.md "SECRET ISOLATION"):
#   The wiki pipeline ingests untrusted bytes — web clippings, PDFs, audio
#   transcripts, pasted articles. PARSING attacker-controlled content is the
#   highest-risk step: a malicious clipping could exploit a parser, exfiltrate
#   secrets, or read the vault if it ran with ambient authority.
#
#   ATTACKER GOAL we deny: (1) steal a token (gh/vault/cloud OAuth/Claude creds);
#   (2) read or corrupt the full vault; (3) phone home / exfiltrate.
#
#   CONTAINMENT (corrected per the law-v2 ultra-verify — the earlier draft that
#   mounted the vault tree + the vault token into the parse step is FORBIDDEN):
#     * Run the parse in a THROWAWAY context that holds NEITHER a token NOR the
#       vault. Only ONE input file is staged IN (read-only) and ONE output path
#       staged OUT. NEVER $HOME, ~/.config, ~/.ssh, the gh/vault tokens, the
#       rclone config, or the vault directory.
#     * NO network egress, period — the sandbox namespace has no interface.
#       (An egress mode was removed as theatre: podman cannot start at this
#       nesting depth, bwrap has no NAT, and the old podman path's "single-host
#       allowlist" was trust-the-command, not an enforced boundary. Fetch
#       OUTSIDE the sandbox, then stage the fetched FILE in.)
#     * Throwaway: a fresh bwrap each call. Nothing persists; a compromise
#       dies with the sandbox.
#   If a malicious input hijacks the parser here, there is no credential to
#   steal, no full vault to read, and (default) no way to phone home. The
#   small, boring orchestrator that LATER writes the sanitized note into the
#   vault + runs vault-gitsync.sh is a SEPARATE process that never saw these
#   bytes (SECRET ISOLATION "irreducible residue").
#
# INVOCATION: on-demand by the wiki pipeline — NOT by the entrypoint.
#   ingest-sandbox.sh --in <input-file> --out <output-file> [--] CMD [ARGS...]
#     --in   FILE        single untrusted input, mounted read-only at /in/input
#     --out  FILE        single output file the sandbox may write at /out/output
#     CMD ARGS           the parse/transcribe command to run INSIDE the sandbox,
#                        referencing /in/input and /out/output (NOT host paths)
#   Options:
#     --timeout SECS     hard wall-clock kill (default 300)
#   Env equivalent: INGEST_TIMEOUT.
#   (--image / --allow-host / --bwrap were removed with the dead podman path;
#    --allow-host now fails fast — no supported egress exists in-container.)
#
# EXAMPLE (transcribe one audio file with a tool that lives in the image):
#   ingest-sandbox.sh --in /tmp/clip.m4a --out /tmp/note.md -- \
#       myparser --input /in/input --output /out/output
# =============================================================================
set -eu

log()  { printf '%s [ingest-sandbox] %s\n' "$(date -Iseconds)" "$*" >&2; }
die()  { log "ERROR: $*"; exit 1; }

# ---- defaults ---------------------------------------------------------------
INGEST_TIMEOUT="${INGEST_TIMEOUT:-300}"
IN_FILE=""
OUT_FILE=""

# ---- arg parse --------------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        --in)         IN_FILE="$2"; shift 2 ;;
        --out)        OUT_FILE="$2"; shift 2 ;;
        --timeout)    INGEST_TIMEOUT="$2"; shift 2 ;;
        --allow-host|--image|--bwrap)
                      die "egress/podman modes were removed (podman cannot start at this nesting depth; bwrap has no NAT; the old 'allowlist' was not an enforced boundary). Fetch OUTSIDE the sandbox and stage the file with --in." ;;
        --)           shift; break ;;
        -*)           die "unknown option: $1" ;;
        *)            break ;;
    esac
done
[ -n "$IN_FILE" ]  || die "--in <input-file> is required"
[ -n "$OUT_FILE" ] || die "--out <output-file> is required"
[ $# -ge 1 ]       || die "a command to run inside the sandbox is required (after --)"
[ -f "$IN_FILE" ]  || die "input file does not exist: $IN_FILE"

# Resolve to absolute, real paths so the bind mounts are exactly one file each.
IN_ABS="$(readlink -f -- "$IN_FILE")" || die "cannot resolve --in"
OUT_DIR="$(dirname -- "$OUT_FILE")"
mkdir -p "$OUT_DIR"
OUT_DIR_ABS="$(readlink -f -- "$OUT_DIR")" || die "cannot resolve --out dir"
OUT_BASE="$(basename -- "$OUT_FILE")"
OUT_ABS="$OUT_DIR_ABS/$OUT_BASE"
: > "$OUT_ABS"   # pre-create so we bind a file, not a missing path

# ---- refuse to leak the sensitive trees -------------------------------------
# Mechanical backstop: the input/output must NOT live inside the vault, the gh
# config, the ssh dir, or the rclone config — staging untrusted bytes there (or
# writing output there) would re-introduce the exact hole this script closes.
# The wiki pipeline is expected to stage into a scratch dir (e.g. /tmp/ingest).
HOME_DIR="${HOME:-/home/core}"
VAULT_PATH="${VAULT_PATH:-/home/core/obsidian/2nd-brain}"
for forbidden in \
    "$(readlink -m "$VAULT_PATH")" \
    "$(readlink -m "$HOME_DIR/.config")" \
    "$(readlink -m "$HOME_DIR/.ssh")" \
    "$(readlink -m "$HOME_DIR/.local/share/fedora-dev")" \
; do
    [ -n "$forbidden" ] || continue
    for p in "$IN_ABS" "$OUT_ABS"; do
        case "$p/" in
            "$forbidden"/*) die "refusing: $p is inside a protected tree ($forbidden). Stage into a scratch dir (e.g. /tmp/ingest)." ;;
        esac
    done
done

log "input  (ro): $IN_ABS  -> /in/input"
log "output (rw): $OUT_ABS  -> /out/output"
log "network    : NONE (isolated)"
log "timeout    : ${INGEST_TIMEOUT}s"

# =============================================================================
# bwrap (unprivileged user-namespace sandbox) — the ONLY path in this nested box
# =============================================================================
# Why bwrap (verified live 2026-06-20): rootless podman UNCONDITIONALLY writes
# `net.ipv4.ping_group_range` during netns setup (independent of
# `default_sysctls`), and at this nesting depth `/proc/sys/net` is read-only —
# crun fails `open /proc/sys/net/ipv4/ping_group_range: Read-only file system`.
# So even a bare `podman run` cannot start here. bwrap builds the sandbox
# directly with the kernel's userns/netns syscalls and does NOT touch that
# sysctl. (A ~60-line podman path + an egress "allowlist" that merely trusted
# the command were removed as unreachable/theatre.)
#
# CONTAINMENT under bwrap:
#   * --unshare-user/net/ipc/uts/cgroup  -> own NET namespace with NO interface
#     => NO egress (the strong default guarantee). We deliberately do NOT
#     --unshare-pid: a new PID ns forces mounting a FRESH procfs (`--proc`),
#     which the kernel denies at this nesting depth; instead we --ro-bind the
#     existing /proc read-only. (PID visibility is not a secret-exfil vector
#     here — there is no token in this namespace to find.)
#   * read-only /usr + /etc; a FRESH tmpfs $HOME (so ~/.config, ~/.ssh, tokens,
#     the rclone config are all absent); the two single-file binds are the ONLY
#     shared data. The vault is never bound.
#   * --die-with-parent: the sandbox dies if the orchestrator does (throwaway).
run_bwrap() {
    command -v bwrap >/dev/null 2>&1 || die "bwrap not available — cannot sandbox ingest"
    log "using bwrap sandbox (network fully isolated)"
    timeout --signal=KILL "$INGEST_TIMEOUT" \
    bwrap \
        --unshare-user --unshare-net --unshare-ipc --unshare-uts --unshare-cgroup \
        --die-with-parent \
        --ro-bind /usr /usr \
        --ro-bind /etc /etc \
        --symlink usr/bin /bin \
        --symlink usr/lib /lib \
        --symlink usr/lib64 /lib64 \
        --symlink usr/sbin /sbin \
        --ro-bind /proc /proc \
        --dev /dev \
        --tmpfs /tmp \
        --tmpfs /home \
        --setenv HOME /home \
        --ro-bind "$IN_ABS" /in/input \
        --bind "$OUT_ABS" /out/output \
        --chdir /tmp \
        -- \
        "$@"
}

# ---- dispatch ---------------------------------------------------------------
rc=0
run_bwrap "$@" || rc=$?

if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    log "ingest TIMED OUT after ${INGEST_TIMEOUT}s and was killed"
elif [ "$rc" -ne 0 ]; then
    log "ingest command exited non-zero ($rc)"
else
    log "ingest complete -> $OUT_ABS"
fi
exit "$rc"
