# THE FLEET — the oso-gato container swarm

Three Claude Code agents ("claudeboxes") across one VPS host. Each carries a **stamped law** — its
`policy/CLAUDE.md`, re-stamped into `/etc/claude-code/CLAUDE.md` on every box rebuild, overriding
project files, prompts, and memory. All three open that law with the **identical `THE FLEET` block**,
so they share one merge model, one control-plane definition, and one spin-up pattern; their roles do
**not** overlap.

> This file is the human-readable **map**. The binding, mechanically-enforced **law** is each repo's
> `policy/CLAUDE.md` (`THE FLEET` block + the per-box ROLE). Keep this file and that block in sync —
> one wording, edited once and propagated to all three; the policy block is authoritative.

## At a glance

| Box | Role | Builds? | Merges? | Operates host? | Spin up |
|-----|------|:--:|:--:|:--:|---------|
| **fedora-dev** | develop · build · **merge** | ✅ nested | ✅ **(sole merger)** | ❌ | `./spin-up.sh` |
| **fedora-bootstrap** | operate host · live-diagnose → PR | ❌ (CI) | ❌ PR-only | ✅ incl. create/remove | `./day0.sh` (Day-0) |
| **fedora-desktop** | knowledge-work + own toolset → PR | ❌ (CI) | ❌ PR-only | ❌ | `./spin-up.sh` |

## The merge spine (shared by all three)

Everyone develops on branches and **opens PRs**. **Only `fedora-dev` merges to `main`** — any PR
including its own and any control-plane change — and **only** on Arthur's **discrete clickable
APPROVE** (a free-text "yes" is not approval).

**The merge gate.** The promotion gate is REFSPEC-AWARE and fail-closed: routine feature-branch pushes
(an explicit non-`main`, non-`HEAD`, non-tag destination refspec) run AUTONOMOUSLY with no prompt; only
a push that could touch `main` (a bare `git push`, a `main`/`HEAD`/`refs/tags/*` destination,
`--all`/`--mirror`/`--tags`, or any unparseable / quoted / chained target) PLUS the merge verbs
(`gh pr merge`, `gh pr create --merge|--squash|--rebase|--auto`, `gh api …/merge|/merges`) route to an
in-session clickable `ask` only Arthur can answer. There is NO approval-marker mechanism (the shipped
hook uses native `ask`); server-side branch protection on `main` is the PRIMARY backstop.

**The dev↔host loop.** The dev↔host loop runs autonomously EXCEPT the final merge: develop → open PR
(feature pushes are autonomous) → label it `live-validate` → the host live-gate (Gate B) DISCOVERS it
ORG-WIDE by that label (no repo list to maintain), fetches the PR head on-demand, applies a STRUCTURAL
GUARD (only builds a candidate carrying a `Containerfile`/`.live-gate`, else skips cleanly), builds it
DISPOSABLY per the repo's own in-repo `.live-gate` contract (PARSED, never executed) under loopback-only
fences, and posts a GREEN/RED verdict comment → iterate (RED: push a fix, or SUPERSEDE the branch if the
approach was wrong; GREEN: BUILD UPON it) until green → Arthur's discrete clickable APPROVE → fedora-dev
merges. The human is OUT of the per-iteration loop — only the merge is a click. Repos are discovered
DYNAMICALLY: create/rename/merge/delete freely; enroll one just by labelling its PR `live-validate` and
shipping a `.live-gate`.

Build is always CI; operate/deploy is always `fedora-bootstrap`; merge is always `fedora-dev` (or
Arthur on the web). Mechanically enforced by the `gate-push.sh` PreToolUse hook + `managed-settings.json`
+ the CI control-plane diff-guard — not prose-only.

## The three boxes

**`fedora-dev` — DEVELOP · BUILD · MERGE.** Develops image-source repos, builds them in its nested
`podman` engine (`CONTAINER_HOST`) to validate, opens PRs; **and** is the fleet's sole merge box
(lists open PRs → your APPROVE → merges, control-plane included). *Boundary:* never operates/deploys
a host or live container; `podman` only against its nested engine.

**`fedora-bootstrap` — OPERATE + LIVE-DIAGNOSE → PR** *(the genesis / mother-platform box, on the
VPS).* The only agent on the host: operates + maintains it (incl. creating/removing containers), the
only box that sees the live containers; live-diagnoses them and develops fixes to the fleet image
repos it operates → opens PRs. *Boundary:* never merges/pushes/tags `main` (`fedora-dev` does); never
`podman build` (CI does); never applies host changes itself (the operator re-runs `setup.sh` — no host
root). Host genesis path is `day0.sh` → `setup.sh` (there is no `spin-up.sh`/`run.sh`/Quadlet here).

**`fedora-desktop` — KNOWLEDGE WORK + TOOLSET DEV → PR** *(the application box).* Primary: operate +
maintain the LLM wiki + Obsidian vault (writer **under direction**). Secondary: develop, **only in its
own repo**, in-container tooling that supports the knowledge work (open to `core` + extra users).
*Boundary:* PR-only (never merges any `main`, incl. its own); every other repo off-limits; vault
content governed by the vault's own `CLAUDE.md` (discrete approval); untrusted content parsed in a
throwaway no-secret sandbox; never operates a host.

## Shared invariants (identical in all three)

- **Spin-up:** the wizard **asks for `TS_AUTHKEY`** (blank → `login.tailscale.com` web-login);
  `IMAGE=ghcr.io/oso-gato/<name>:latest` for a host deploy; **never hand-roll `podman`.**
- **Control-plane class** (`policy/**`, `managed-settings.json`, `gate-push.sh`,
  `.github/workflows/**`, `*.container`, `run.sh*` security flags, key-sync, `*sudoers*`): standalone,
  never bundled; needs the human-applied `control-plane-approved` label.
- **Sources** (dnf → vendor `.repo` → AppImage/`.war`, GPG/sha-verified) · **no secrets in image
  layers** · **headless everywhere** (software-GL); sensitive ports tailnet-only, the desktop's web
  gate the one public door.
