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

## The autonomy mandate — the apparatus's primary purpose

`fedora-dev` + `fedora-bootstrap` are ONE self-sustaining development apparatus (every box develops
inside it). Its PRIMARY PURPOSE: keep the human OUT of the loop until genuinely needed. The agent does
MOST of the work + the thinking and runs the loop above autonomously — **the PR is its proof of work.**

- **Build-and-discard, don't option-shop.** When there are options, the agent BUILDS 2–3, tests them
  through the live-gate, DISCARDS what doesn't fit, and lands the right one ITSELF — it recommends AND
  self-tests its own recommendation, and TEARS DOWN + REBUILDS to a zero-base rather than defend a first
  draft. Presenting an options-decision is RARE.
- **Engage the human for EXACTLY TWO reasons:** (1) MATERIALLY COMPLETE → the clickable APPROVE to
  merge; (2) MATERIALLY BLOCKED → a genuine roadblock needing a DECISION (not a merge). Status-checks,
  option-shopping, and "which should I do" are NOT reasons.
- **Two-tier validation — NOT every change goes to the host.** *Tier 1 — IN-BOX (the DEFAULT):* the
  dev-box `podman build` IS the throwaway — develop + validate + iterate ENTIRELY in the nested engine
  for everything it CAN build+validate itself, with NO host involvement (the overwhelming majority of
  iteration). *Tier 2 — HOST (via the `live-validate` label, ONLY two scenarios):* (1) the nested engine
  CANNOT build/run the throwaway (e.g. the systemd-PID-1 GRD lineage that can't boot nested) → the host
  does the throwaway build+validate; (2) FINAL pre-production shipment — after all in-box iterations, the
  agent tickets the host to throwaway-build, prove it works LIVE, and tear it down, THEN presents
  merge-to-main. In-box iteration does NOT touch the host.
- **Throwaway tree & churn (build discipline).** Build off the LIVE tree where possible; for anything
  that must DIFFER, bolt on a SEPARATE, TEMPORARY throwaway tree that never mutates the IMMUTABLE live
  tree (host + dev-container base are immutable; throwaway tree + caches live on the writable home
  volume), still obeys PROVENANCE (no loosening), and is THROWN AWAY after the build (disposable tag,
  `--rm` + `rmi`). Churn balance: persist the ONE durable input — the dnf PACKAGE CACHE (a plain bind dir
  on the home volume, NOT an image layer, so it survives `rmi` and every disposal) — and let everything
  else (candidate image, its layers, temp tree, run container) be ephemeral by design; Containerfiles go
  HEAVY/STABLE-EARLY + CHURN-LATE and never `--no-cache` mid-churn — a 50× iteration re-downloads nothing.
- **Churn mechanism — NO re-download across N PRs/iterations (proven in-box).** The PR/SHA is NOT the
  package cache's disposal signal: per-PR/per-SHA disposal removes the candidate image + temp tree — and,
  when it was the sole referrer, its intermediate layers too — but NEVER the dnf package cache, which is
  NOT keyed to PR/SHA and is SHARED across every iteration. One persistent thing, everything else ephemeral
  by design: (1) the persistent dnf PACKAGE CACHE — the ROBUST mechanism, bind-mounted into the build
  (`-v <home>/.cache/fd-dnf:/var/cache/libdnf5:rw`); a plain dir, NOT an image layer, so it survives `rmi`
  and every disposal — churn that changes the dnf install LINE (an add-on PR) re-runs that layer but serves
  the RPMs FROM CACHE instead of re-downloading (proven: a forced dnf re-run downloaded 0 B (vs 9.4 MiB
  cold), 3.7× faster; only a genuinely-new package downloads once). `--mount=type=cache` does NOT work
  under the box's required `--isolation=chroot`, so the bind `-v` package cache is the mechanism. (2)
  EPHEMERAL LAYERS — ephemeral by design, and that is the advantage: a throwaway's layers are pruned with
  its sole candidate's `rmi`, so (a) layer storage self-bounds on the limited VPS (no accumulation, no
  separate layer cache to GC), (b) each throwaway rebuilds fresh from the package cache → current package
  versions, no stale-frozen-layer risk (freshness for free), (c) the only cost is a few local CPU-seconds
  (~3.6 s warm), never bandwidth. While a candidate image still lives (LATE-layer churn, or a kept image)
  its layer cache also lets the rebuild skip the dnf RUN → zero work — a free accelerator — but nothing
  depends on layers surviving disposal. ISOLATION: each build owns its throwaway tree + a unique disposable
  tag (`val-<sha>`) + a unique run container (`vcand-$$`) → no cross-build contamination, and the
  content-addressed dnf package cache (and any live layer cache) can never serve a wrong version. STORAGE
  SAFETY on the limited VPS is a trio: (a) the disposable image+tree self-destruct via a `trap … EXIT`
  (GREEN/RED/error alike); (b) an ORPHAN SWEEPER reaps anything a `kill -9`/crash leaks (stale
  `localhost/disposable/*`, `vcand-*`, orphan temp dirs) at watcher start + periodically; (c) a BOUNDED
  cache-GC caps the persistent dnf package cache age-then-size (RPMs older than 45 days first, then LRU
  size-prune to ≤15 GB; both overridable) so it cannot exhaust the quota — layers self-bound via `rmi`.
- **Definition of Done (all four).** (1) the FULL objective materially achieved (not a ~5% slice); (2)
  validated through the two-tier loop — in-box build GREEN is the default proof, with the host live-gate
  verdict GREEN required for the two Tier-2 scenarios only (nested engine can't validate it, OR final
  pre-production shipment); (3) adheres to the BUILD PRINCIPLES; (4) a self-examined TLDR that the agent
  dry-runs AS IF it were the human — if it fails its own scrutiny the agent returns to the loop instead
  of presenting. Only then does the change go to the human.

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
  never bundled; needs the human-applied `control-plane-approved` label.
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
