#!/usr/bin/env bash
# gate-push.test.sh — full-matrix harness for fedora-desktop's PR-ONLY,
# REFSPEC-AWARE promotion gate (with the narrow vault-sync exemption).
#
# Verdict classes:
#   ALLOW = exit 0 AND stdout has NO permissionDecision   (autonomous fall-through)
#   ASK   = stdout contains "permissionDecision":"ask"     (Arthur's clickable prompt)
#   DENY  = exit 2 OR stdout contains "permissionDecision":"deny"  (hard stop)
#
# fedora-desktop is PR-ONLY: it must push FEATURE branches autonomously (ALLOW)
# and the automatic Obsidian vault git-sync `git -C <vault> push` is the SOLE
# exempted push (ALLOW); it NEVER merges or pushes `main`, so every main-touching
# push and every merge verb is a hard DENY (NOT an ask — fedora-dev merges).
# Run:  bash policy/hooks/gate-push.test.sh   (exit 0 = all rows pass)
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
GATE="$HERE/gate-push.sh"
VAULT="/home/core/obsidian/2nd-brain"   # gate-push.sh default VAULT_DIR

pass=0
fail=0

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '%s' "$s"
}

classify() {
    local cmd="$1" payload out rc
    payload="$(printf '{"tool_input":{"command":"%s"}}' "$(json_escape "$cmd")")"
    out="$(printf '%s' "$payload" | bash "$GATE" 2>/dev/null)"
    rc=$?
    if [ "$rc" -eq 2 ] || printf '%s' "$out" | grep -q '"permissionDecision":"deny"'; then
        printf 'DENY'
    elif printf '%s' "$out" | grep -q '"permissionDecision":"ask"'; then
        printf 'ASK'
    elif [ "$rc" -eq 0 ]; then
        printf 'ALLOW'
    else
        printf 'UNKNOWN(rc=%s)' "$rc"
    fi
}

check() {
    local want="$1" cmd="$2" got
    got="$(classify "$cmd")"
    if [ "$got" = "$want" ]; then
        printf 'PASS  %-5s  %s\n' "$got" "$cmd"
        pass=$((pass + 1))
    else
        printf 'FAIL  want=%-5s got=%-5s  %s\n' "$want" "$got" "$cmd"
        fail=$((fail + 1))
    fi
}

echo "== ALLOW (autonomous feature-branch work) =="
check ALLOW 'git push -u origin feat/x'
check ALLOW 'git push origin feat/x'
check ALLOW 'git push --force origin feat/x'
check ALLOW 'git push origin +feat/x'
check ALLOW 'git push origin --delete feat/x'
check ALLOW 'git push origin HEAD:feat/x'
check ALLOW 'git push origin feat/x:feature/main'
check ALLOW 'gh pr create -t a -b b'
check ALLOW 'gh pr edit 5 --add-label live-validate'
check ALLOW 'gh pr comment 5 -b hi'

echo
echo "== ALLOW (the SOLE vault-sync exemption — git -C <vault> push) =="
check ALLOW "git -C $VAULT push"
check ALLOW "git -C $VAULT push origin main"
check ALLOW "git -C $VAULT push origin HEAD"
check ALLOW "git -C $VAULT/notes push origin main"

echo
echo "== DENY (could touch main / ambiguous — this box never pushes main) =="
check DENY 'git push origin main'
check DENY 'git push origin HEAD:main'
check DENY 'git push origin feat/x:main'
check DENY 'git push origin feat/x:heads/main'
check DENY 'git push origin HEAD:heads/main'
check DENY 'git push origin heads/main'
check DENY 'git push origin refs/heads/main'
check DENY 'git push --force origin main'
check DENY 'git push'
check DENY 'git push origin'
check DENY 'git push origin HEAD'
check DENY 'git push --all origin'
check DENY 'git push --mirror origin'
check DENY 'git push origin refs/tags/v1'
check DENY 'git -C /tmp/x push origin main'
check DENY "git -C $VAULT/../../.local/share/fedora-desktop push origin main"
check DENY "git -C $VAULT/.. push origin main"
check DENY "git -C $VAULT/../evil push origin main"

echo
echo "== DENY (merge verbs — this box never merges) =="
check DENY 'gh pr merge 5'
check DENY 'gh pr create --squash'
check DENY 'gh pr create -t a -b b --merge'
check DENY 'gh api repos/o/r/merges -f base=main'

echo
echo "== DENY (adversarial: chained / quoted / escaped / variable; vault exemption can't smuggle) =="
check DENY 'git push origin main && git push origin feat/x'
check DENY 'git push origin feat/x && git push origin main'
check DENY 'git push origin "main"'
check DENY "git push origin ma''in"
check DENY 'X=main git push origin $X'
check DENY "git -C $VAULT push && git push origin main"

echo
echo "== TOTAL: $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
