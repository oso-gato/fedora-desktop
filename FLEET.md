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
hook uses native `ask`/`deny`). A loop-neutral **`require-PR` ruleset** on `main` (no required
reviews or status checks) is active on all three repos — it forces every change through a PR,
closing the headless `claude -p` bypass; `main` has no heavy branch protection beyond this thin
floor (the in-session gate + require-PR + Arthur's click are the whole gate).

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
+ the server-side `require-PR` ruleset on `main` — not prose-only. (The CI control-plane label-gate
was removed; control-plane PRs are gated by the merge click + the standalone-PR convention.)

## The autonomy mandate — the apparatus's primary purpose

Full law: `policy/CLAUDE.md` (THE SELF-SUSTAINING APPARATUS section); always in context. This box's role: develop knowledge-work tooling; every change → open a PR (this box never merges).

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

### The two-axis model — how the three claudeboxes relate

Each box hosts the same thing — Claude Code in a Distrobox ("claudebox") — so the three are **not**
three bespoke builds. Each is **one shared invariant plus a point in a grid of two ORTHOGONAL axes.**
A difference between any two boxes is therefore always exactly one of: the invariant (never — that is
*drift*, and CI fails it), the **substrate** axis, or the **role** axis. Nothing else.

**The invariant — the claude-code guard payload (identical in all three, ENFORCED).**
`policy/managed-settings.json` (the agent deny-list + the `DISABLE_UPDATES`/`DISABLE_AUTOUPDATER`
self-update lockout + bypass/mode/allowManaged + the `gate-push` hook *wiring*), the `claudebox-init.sh`
self-update lockout + native-build-shadow self-heal, and the claude-code **provenance** (Anthropic
`latest` channel, `gpgcheck=1`, pinned signing key). `fedora-dev`'s `bin/fleet-guard-parity.sh` (CI on
push/PR **+ daily**) compares this payload across all three public repos and **fails the build on any
drift** — so it cannot silently diverge. It once did: the self-update lockout landed in `fedora-dev`
but was missing from **both** other boxes until an audit caught it; the parity check is what makes that
recurrence impossible.

**Axis A — SUBSTRATE (the architecture).** How the box is built and supervised. Drives supervision,
rebuild serialization, and the init-bridge channel — and *only* those.

| box | substrate |
|---|---|
| `fedora-dev` | **container** — `Containerfile` + `entrypoint.sh` as PID 1; *no systemd* (inotify rebuild-watcher + `flock` serialization + `podman exec` init bridge) |
| `fedora-desktop` | **container** — `Containerfile`(+`.grd`) + `entrypoint.sh`; the `grd` lineage runs **systemd as PID 1** |
| `fedora-bootstrap` | **host** — `setup.sh` on the VPS; **systemd --user** (timer/unit serialization + `distrobox enter -- sudo` init bridge) |

**Axis B — ROLE (merge authority + job).** Expressed by the `gate-push.sh` terminal verb (the refspec
parser is identical; only the verb differs) plus each box's job.

| box | role | `gate-push` verb |
|---|---|---|
| `fedora-dev` | **MERGER** (sole merge authority) | main-touching push + merge verbs → **ASK** (Arthur's in-session click) |
| `fedora-bootstrap` | **proposer** (PR-only) | → **DENY** |
| `fedora-desktop` | **proposer** (PR-only) | → **DENY** |

Role also sets: live-gate ownership (`fedora-bootstrap` *operates* Gate B; `fedora-dev` + `fedora-desktop`
are *clients* via the `live-validate` label), per-box package sets, and the role-divergent
`policy/CLAUDE.md`.

**The grid, and the key reading:**

| box | Axis A (substrate) | Axis B (role) |
|---|---|---|
| `fedora-dev` | container | **MERGER** (ask) |
| `fedora-bootstrap` | **host** | proposer (deny) |
| `fedora-desktop` | container | proposer (deny) |

The axes are independent. **`fedora-bootstrap` and `fedora-desktop` are wired the SAME on role** — both
proposer/**DENY**, both live-gate clients — so they differ from each other **only on substrate** (bootstrap
is the host, desktop is a container). **`fedora-dev` differs from both only on role** (it is the sole
merger) — *not* on substrate (it is a container, like desktop). The familiar "2 containers + 1 host"
split is Axis A; the "1 merger + 2 proposers" split is Axis B; the two cut across each other, and the
guard payload underneath is held identical by the parity check.

## Shared invariants (identical in all three)

- **Spin-up:** the wizard **asks for `TS_AUTHKEY`** (blank → `login.tailscale.com` web-login);
  `IMAGE=ghcr.io/oso-gato/<name>:latest` for a host deploy; **never hand-roll `podman`.**
- **Control-plane class** (`policy/**`, `managed-settings.json`, `gate-push.sh`,
  `.github/workflows/**`, `*.container`, `run.sh*` security flags, key-sync, `*sudoers*`): standalone,
  never bundled; gated by Arthur's merge click on the standalone PR (no CI label gate — the
  label-gate job was removed).
- **Claude-code guard payload** (the `managed-settings.json` deny-list + self-update lockout, the
  `claudebox-init.sh` lockout + native-shadow self-heal, the claude-code provenance): **byte-identical
  in all three, CI-enforced** by `fedora-dev`'s `bin/fleet-guard-parity.sh` (push/PR + daily). This is the
  *invariant* underneath the two-axis model — Axes A/B may diverge; this may not. See *The two-axis model* above.
- **Sources** (dnf → vendor `.repo` → AppImage/`.war`, GPG/sha-verified) · **no secrets in image
  layers** · **headless everywhere** (software-GL); sensitive ports tailnet-only, the desktop's web
  gate the one public door.
- **Multi-device terminal:** one shared `main` tmux group; a tmux window has ONE size shared by all
  co-viewing clients, so `/etc/tmux.conf` is `window-size latest` (the device that last sent input
  wins → whole session rescales) + `fill-character ' '` (idle larger device blank-letterboxes, never
  `·`-garbles) + `prefix+g` to cycle latest/smallest/largest. Differently-sized devices on the SAME
  tab can NEVER both be full-size (one program = one pty = one cell grid) — a tmux invariant, not a
  bug to "fix"; the active device wins and the rest degrade cleanly (crop/blank-letterbox).
