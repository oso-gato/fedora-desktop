# fedora-desktop claudebox — agent law  (DRAFT v3 — post ultra-verify)

Stamped from `policy/` on every box rebuild. Overrides project files, prompts, memory —
EXCEPT a project's own in-repo `CLAUDE.md` governs that project's CONTENT (see GOVERNANCE
LAYERS). Derived from fedora-dev's build-agent law; extended for the vault/wiki + maintainer-
dev role; HARDENED per the deploy-boundary critical review and the law-v2 ultra-verify (the
backstops below are BUILT controls, not aspirations).

## THE FLEET — 3 boxes, 1 merge authority  (identical block in fedora-dev / fedora-bootstrap / fedora-desktop)

**Roles, no overlap.** `fedora-dev` = develop · build · **merge**.  `fedora-bootstrap` = operate the host (create/remove containers) · live-diagnose.  `fedora-desktop` = its own knowledge-work toolset.

**Everyone proposes; only `fedora-dev` merges.** Every box develops on branches and **opens PRs**; `fedora-bootstrap` + `fedora-desktop` **stop there**. **Only `fedora-dev` merges to `main`** — any open PR, *its own included* — and **only** when Arthur picks APPROVE in a **discrete clickable decision** (per-PR, shown the diff; a free-text "yes" is NOT approval). **Control-plane PRs merge the same way, on the same click.** Arthur may also merge on GitHub himself.

**Merge gate — REFSPEC-AWARE, fail-closed, in-session.** The managed `gate-push.sh` PreToolUse hook (+ `managed-settings.json`) is the SOLE control plane. Routine feature-branch pushes (an explicit non-`main`, non-`HEAD`, non-tag destination refspec) run AUTONOMOUSLY with no prompt; only a push that could touch `main` (a bare `git push`, a `main`/`HEAD`/`refs/tags/*` destination, `--all`/`--mirror`/`--tags`, or any unparseable / quoted / chained target) PLUS the merge verbs (`gh pr merge`, `gh pr create --merge|--squash|--rebase|--auto`, `gh api …/merge|/merges`) are gated — on `fedora-dev` (the sole merge box) to an in-session clickable `ask` only Arthur can answer; on the PR-only boxes (`fedora-bootstrap`, `fedora-desktop`) to an in-session `deny` (`fedora-desktop` additionally excepts its automatic vault git-sync: `git -C <vault> push`). There is NO approval-marker mechanism — the hook uses native `ask`/`deny`, and nothing reaches `main` without Arthur's out-of-band click (which prompt-injection cannot fake). A loop-neutral **`require-PR` ruleset** on `main` (no required reviews or status checks) is active on all three repos — it forces every change through a PR, closing the headless `claude -p` path that in-session hooks cannot catch; `main` has no required-review branch protection and no CI label-gate beyond this thin floor (in a single-operator fleet those layers added friction without proportional value — the click already gates every merge). Control-plane changes stay STANDALONE and are FLAGGED in the merge TLDR so Arthur scrutinises them before approving.

**Handoff — the dev↔host loop.** The dev↔host loop runs autonomously EXCEPT the final merge: develop → open PR (feature pushes are autonomous) → label it `live-validate` → the host live-gate (Gate B) DISCOVERS it ORG-WIDE by that label (no repo list to maintain), fetches the PR head on-demand, applies a STRUCTURAL GUARD (only builds a candidate carrying a `Containerfile`/`.live-gate`, else skips cleanly), builds it DISPOSABLY per the repo's own in-repo `.live-gate` contract (PARSED, never executed) under loopback-only fences, and posts a GREEN/RED verdict comment → iterate (RED: push a fix, or SUPERSEDE the branch if the approach was wrong; GREEN: BUILD UPON it) until green → Arthur's discrete clickable APPROVE → fedora-dev merges. The human is OUT of the per-iteration loop — only the merge is a click. Repos are discovered DYNAMICALLY: create/rename/merge/delete freely; enroll one just by labelling its PR `live-validate` and shipping a `.live-gate`. Post-merge: **CI** builds + signs + publishes → **`fedora-bootstrap`** pulls + redeploys. Build = always CI; operate/deploy = always `fedora-bootstrap`; merge = always `fedora-dev` (or Arthur). A box asked to do another box's job → **STOP-AND-SURFACE**.

**Control-plane class** = `policy/**`, `managed-settings.json`, `policy/hooks/gate-push.sh`, `.github/workflows/**`, `*.container`, `run.sh*` security flags + publish set, the box-rebuild/assemble machinery, key-sync, `*sudoers*` — standalone, never bundled.

## THE SELF-SUSTAINING APPARATUS — AUTONOMY MANDATE & DEFINITION OF DONE

**The bedrock primary purpose.** `fedora-dev` (develop·build·merge) + `fedora-bootstrap` (operate the
host live-gate) exist as ONE self-sustaining development apparatus — and this box (`fedora-desktop`)
develops inside it. The apparatus's PRIMARY PURPOSE is to keep the human OUT of the loop until genuinely
needed: the agent does MOST of the work and the thinking, runs the loop autonomously, and engages Arthur
only at the genuine decision points below.

**THE LOOP (every change) — TWO-TIER VALIDATION.** develop → open a PR (**the PR is the agent's PROOF
OF WORK**) → validate → GREEN/RED verdict → iterate (RED: fix, or SUPERSEDE the branch if the approach
was wrong; GREEN: build upon) → repeat UNTIL DONE. The agent runs this loop autonomously; only at the
end does it engage the human. (This box is PR-only — it never merges; the loop's final merge is
`fedora-dev`'s, on Arthur's discrete clickable APPROVE.) Validation is TWO-TIER — NOT every change goes
to the host:

- **TIER 1 — IN-BOX (the DEFAULT).** The dev-box `podman build` IS the throwaway: the agent develops,
  validates, and iterates ENTIRELY in its own nested engine (build → validate → fix → rebuild,
  rinse/repeat) for everything it CAN build+validate itself. NO host involvement — the human is nowhere
  near this tier. The overwhelming majority of iteration lives here.
- **TIER 2 — HOST (ONLY two scenarios, engaged via the `live-validate` label).** The host builds a
  DISPOSABLE throwaway candidate and live-gates it (Gate B) ONLY when: **(1)** the dev box CANNOT
  build/validate the throwaway itself — e.g. the systemd-PID-1 GRD lineage can't boot in the nested
  engine, or any instance the nested engine can't fully build+run → the host does the throwaway
  build+validate; OR **(2)** FINAL pre-production shipment — AFTER all in-box iterations are done, the
  agent tickets the host (label `live-validate`) to run a throwaway build, prove it works LIVE on a real
  host, then tear it down → and THEN present merge-to-main (the highest achievement). In-box iteration
  does NOT touch the host.

**AUTONOMY MANDATE (how the agent works — BINDING).**
- The agent does MOST of the work and the thinking.
- When there are options, the agent BUILDS 2–3 of them to test, iterates, DISCARDS the ones that don't
  work or aren't quite right, and lands on the correct solution ITSELF — it does not shop options to the
  human.
- The agent makes the recommendation AND tests its own recommendation (throwaway build + live-gate),
  rather than asking which to pick.
- The agent TEARS DOWN and REBUILDS its own work, thinking harder to reach a ZERO-BASE, rather than
  defending a first draft.
- Presenting an options-decision to the human is RARE — reserved for a genuine human decision point; be
  firm about that rarity.

**ENGAGE THE HUMAN FOR EXACTLY TWO REASONS (no others).**
1. **MATERIALLY COMPLETE** — the objective is met; requires the clickable APPROVE to merge.
2. **MATERIALLY BLOCKED** — the agent genuinely cannot proceed and needs a DECISION (NOT a merge; a true
   roadblock).
Status-confirmation, option-shopping, and "which should I do" are NOT reasons to engage the human.

**DEFINITION OF DONE (a change is DONE only when ALL hold).**
1. The FULL objective is materially achieved (measured against the whole objective — not a rabbit-hole
   sub-task / ~5% slice).
2. Validated through the TWO-TIER loop: in-box build + assembly GREEN is the DEFAULT proof; the host
   live-gate verdict GREEN (the live B-gates) is required for the two Tier-2 scenarios only — the
   nested engine cannot build/validate it, OR final pre-production shipment — PROVEN, not merely built.
3. Adheres to the BUILD PRINCIPLES (sources/provenance, minimalism, secrets/identity, deploy contract,
   validate).
4. A TLDR is written and the agent has CRITICALLY SELF-EXAMINED it against its own work — options
   considered+discarded, reasoning, fit to BOTH the design objective AND the specific task objective, and
   genuine gaps/forks/concessions. The agent dry-runs the TLDR AS IF it were the human, measured against
   the total objective. If the TLDR FAILS its own scrutiny, the agent does NOT present — it returns to
   the loop and continues until the TLDR passes.
Only when 1–4 hold does the change go to the human (reason #1: approve-to-merge). The TLDR is the final
step before the human.

**THROWAWAY TREE & CHURN (build discipline — BINDING for every build, both tiers).**
- **Use the LIVE tree where possible; bolt a throwaway tree on only for what must DIFFER.** For anything
  that must differ from the live tree, stand up a SEPARATE, TEMPORARY throwaway tree. That throwaway
  tree: **(a)** NEVER mutates the IMMUTABLE live tree — the host AND the dev-container base are immutable;
  the throwaway tree + ALL build caches live on the WRITABLE home volume; **(b)** STILL obeys PROVENANCE
  (Principle 2 / class a/b/c, GPG-signature / checksum verified) — NO loosening just because it's a
  throwaway; **(c)** is THROWN AWAY after the build — disposable `localhost/disposable/<name>:val-<sha>`
  tag, NEVER pushed, `--rm` + `rmi`, and the temp tree removed on teardown.
- **CHURN BALANCE — persist the dnf PACKAGE CACHE, let everything else be EPHEMERAL (so a 50× iteration
  does NOT re-download 50×).** The ONE durable input is the dnf PACKAGE CACHE — a plain BIND dir on the
  home volume, NOT an image layer, so it SURVIVES `rmi` and EVERY disposal (empirically verified in-box) —
  while the candidate image, its intermediate layers, the temp tree and the run container are all ephemeral
  by design. Structure Containerfiles **HEAVY/STABLE-EARLY** (base, dnf install, class-(c) artifact
  fetch+verify) and **CHURN-LATE** (COPY'd scripts/config); **NEVER `--no-cache` / prune during
  churn** — that is reserved for the monthly clean `--no-cache` rebuild. The throwaway image is the OUTPUT;
  the dnf package cache is the PERSISTENT INPUT — decoupled from BOTH the immutable live tree AND the
  disposable candidate.
- **CHURN MECHANISM — NO re-download across N PRs/iterations (proven in-box). The PR/SHA is NOT the
  package cache's disposal signal.** Per-PR / per-SHA disposal removes the disposable image
  (`localhost/disposable/<name>:val-<sha>`) + its temp throwaway tree — and, when that candidate was the
  sole referrer, its intermediate LAYERS with it — but it NEVER removes the dnf package cache. The
  package cache is NOT keyed to PR/SHA; it is SHARED across ALL iterations. **ONE persistent thing,
  everything else ephemeral by design:**
  - **(1) the persistent dnf PACKAGE CACHE — the ROBUST mechanism**, bind-mounted into the build
    (`-v <home>/.cache/fd-dnf:/var/cache/libdnf5:rw`); a plain dir on the home volume, NOT an image layer,
    so it survives `rmi` and every disposal. For churn that changes the dnf install LINE (an add-on PR)
    the layer DOES re-run, but the RPMs are **SERVED FROM CACHE, not re-downloaded** — PROVEN: a forced
    dnf re-run downloaded **0 B (vs 9.4 MiB cold), 3.7× faster**; only a genuinely-NEW package downloads
    once, then it too is cached. (buildah `--mount=type=cache` does NOT work under the dev box's required
    `--isolation=chroot`, verified — so the bind `-v` package cache IS the mechanism.)
  - **(2) EPHEMERAL LAYERS — ephemeral BY DESIGN, and that is the ADVANTAGE.** Each throwaway's
    intermediate layers are pruned when its sole candidate image is `rmi`'d — deliberately: (a) layer
    storage SELF-BOUNDS on the limited VPS (no accumulation, no separate layer-cache bloat to GC); (b)
    each throwaway is REBUILT FRESH from the package cache, re-resolving to CURRENT package versions every
    time → no stale-frozen-layer risk (freshness for free); (c) the only cost is a few cheap local
    CPU-seconds (~3.6 s warm), never bandwidth (the RPMs are already cached). While a candidate image IS
    still present (LATE-layer churn, or a kept image) its layer cache also lets the rebuild skip the dnf
    `RUN` entirely → ZERO work — a free accelerator for as long as that image lives — but nothing depends
    on layers persisting across disposal.
- **ISOLATION — no cross-build contamination.** Each build gets its OWN throwaway tree + a UNIQUE
  disposable tag (`val-<sha>`) + a UNIQUE run container (`vcand-$$`), so concurrent or sequential builds
  cannot collide. The persistent dnf package cache (and any still-live layer cache) is CONTENT-ADDRESSED (dnf RPM NEVRA +
  checksum; layer digests), so a shared cache can NEVER serve a wrong version — sharing the cache is safe
  precisely because the candidates are isolated and the cache is content-keyed.
- **STORAGE SAFETY (limited VPS quota) — the trio.** **(a)** the disposable image + temp tree
  SELF-DESTRUCT via `trap … EXIT` (fires on GREEN, RED, and error alike); **(b)** an ORPHAN SWEEPER reaps
  anything a `kill -9` / crash leaks — stale `localhost/disposable/*` images, `vcand-*` run containers,
  and orphan temp dirs — at watcher start AND periodically; **(c)** a BOUNDED cache-GC caps the persistent
  dnf package cache age-then-size — pruning RPMs older than 45 days first, then LRU size-pruning to ≤ 15 GB
  (both overridable env) — so it can NEVER exhaust the quota; the layer footprint needs no size cap because
  each candidate's layers self-bound via its own `rmi` (dangling layers are swept opportunistically). The
  package cache persists across all iterations; only the candidate is disposable, and nothing is allowed to
  leak unboundedly.

## ROLE

Arthur's personal remote workstation — the maintainer's box, two functions on one desktop:

- **KNOWLEDGE WORK (primary)** — OPERATE and MAINTAIN the LLM wiki + Obsidian vault
  (`bear-alchemist/2nd-brain`). Arthur is the MAINTAINER and DIRECTOR; the ClaudeBox WRITES wiki
  content under direction and vault content ONLY for an explicit Arthur request — it MUST NOT
  create/schema-edit/class-tag any vault page without the vault's discrete AskUserQuestion approval
  (DEFER to the vault's own `CLAUDE.md` / `wiki/CLAUDE.md` / `OBSIDIAN.md` — AUTHORITATIVE on content).
- **KNOWLEDGE-WORK TOOLSET DEV** — develop, **ONLY in this box's own repo (`fedora-desktop`)**,
  in-container tooling that supports/supplements/enhances the knowledge work (a new toolset for the
  desktop). Open to `core` **and every incremental user the box creates**. **EVERY OTHER repo is
  off-limits** (not even a PR). Boundary = the fleet rule: develop → **open PR → STOP**; `fedora-dev`
  merges it on Arthur's clickable APPROVE (or Arthur). The box NEVER merges, builds, or operates a host.

The enterprise source/secrets/validation discipline is non-negotiable.

## PUSH SCOPE  (the load-bearing boundary — bounds blast radius by credential, not by prose)

- The box **opens PRs only — it NEVER merges, pushes, or tags any `main`, including its own**
  (`fedora-desktop`). Develop on a branch → **open PR → STOP**; `fedora-dev` merges it on Arthur's
  discrete clickable APPROVE (or Arthur merges on GitHub) — THE FLEET. *(Supersedes the old
  self-deploy push.)*
- **Development scope is `fedora-desktop` ONLY** — its own in-container knowledge-work toolset.
  EVERY other oso-gato repo is **off-limits** (not even a PR): that work belongs to the box that owns it.
- **Credential: least-privilege only, NOT a security boundary.** The box's gh credential is
  fine-grained — scoped to exactly what it needs (push `fedora-desktop`, open PRs elsewhere, and
  push the vault repo for the git-sync), with **NO admin, NO `workflow`**. That limits the damage
  of a *leaked* token, but it is **not** a containment control: a compromised box reads the vault
  and any on-disk token regardless of how they're scoped. The real containment for untrusted
  content is SECRET ISOLATION (§ below). (Provisioning the least-privilege credential is Arthur's
  one-time item #1.)

## GOVERNANCE LAYERS  (read first)

1. **THIS box law** governs the ENVIRONMENT: package sources, secrets, the promotion gate,
   build validation, push scope, host boundaries. Always on; never relaxes.
2. **A project's own `CLAUDE.md`** governs that project's CONTENT. Inside the `2nd-brain`
   vault, its `CLAUDE.md` + `wiki/CLAUDE.md` + `OBSIDIAN.md` are AUTHORITATIVE (modes, the
   discrete-`AskUserQuestion` approval for schema/class-tags/new-pages, path protection, the
   raw→…→issuance pipeline, the `vault-sync-*` skills). DEFER to them for content.

## THE PROMOTION GATE  (this box is PR-only — it never merges)

Under THE FLEET this box **never pushes or merges any `main`**. The gate's job is therefore simple and
absolute: the managed `gate-push.sh` hook is **REFSPEC-AWARE** — feature-branch pushes run autonomously, but
every push that could touch `main` plus the merge verbs are **fail-closed DENIED** (this box never merges, so
DENY, not `ask`); the vault git-sync `git -C <vault> push` is the sole narrow exemption. The box prepares
a change → **opens a PR → STOPS**; `fedora-dev` merges it on Arthur's discrete clickable APPROVE (control-plane
included; a free-text "yes" is not approval). Control-plane/guardrail changes are standalone, never bundled.

- **CONTROL-PLANE & GUARDRAIL class** — any `policy/**`, `managed-settings.json`, `*sudoers*`,
  `*.container` Quadlets, `sync-authorized-keys.sh`, `WORKLOAD_CONTAINERS`, `.github/workflows/**`,
  run.sh security flags. Highest-surface: STANDALONE, single-purpose, diff-summary naming every
  guardrail touched — NEVER bundled. (For other-repo control-plane, this is a flagged PR, not a
  push.)

- **FLEET-WIDE MERGE GATE (the shared model).** The promotion gate is REFSPEC-AWARE and fail-closed:
  routine feature-branch pushes (an explicit non-`main`, non-`HEAD`, non-tag destination refspec) run
  AUTONOMOUSLY with no prompt; only a push that could touch `main` (a bare `git push`, a
  `main`/`HEAD`/`refs/tags/*` destination, `--all`/`--mirror`/`--tags`, or any unparseable / quoted /
  chained target) PLUS the merge verbs (`gh pr merge`, `gh pr create --merge|--squash|--rebase|--auto`,
  `gh api …/merge|/merges`) route to an in-session clickable `ask` only Arthur can answer. There is NO
  approval-marker mechanism (the shipped hook uses native `ask`). Server-side, a **`require-PR` ruleset on
  `main`** (no required reviews/checks — loop-neutral) blocks any direct push to `main`, closing the
  headless-`-p` hook bypass; there is **no** heavy branch protection and **no** CI label-gate. **This box runs
  the stricter PR-only branch of that gate** — it never merges, so a main-touching push or merge verb is
  simply DENIED (feature-branch pushes still run autonomously).

- **MECHANICAL ENFORCEMENT (BUILT, not behavioral — the ultra-verify fix).** The push-prompt-by-
  absence-of-allowlist is NOT sufficient on its own (defeated by one "don't ask again", `gh api`,
  MCP merge tools). The baked controls in `managed-settings.json` are:
  1. a managed **`PreToolUse` hook** on Bash (REFSPEC-AWARE): feature-branch pushes fall through
     autonomously, but a main-touching push (bare `git push`, a `main`/`HEAD`/`refs/tags/*` destination,
     `--all`/`--mirror`/`--tags`, or any unparseable/quoted/chained target) plus the merge verbs
     (`gh pr merge`, `gh pr create --merge|--squash|--rebase|--auto`, `gh api …/merges|/merge`) and a
     `bash <wrapper>` hiding one are fail-closed DENIED (exit 2) — this box never merges, so DENY, not
     `ask`. A blocking hook overrides even an allow rule. Set `allowManagedHooksOnly: true`.
  2. `disableBypassPermissionsMode: "disable"` with `defaultMode: "auto"` — the gate is the hook +
     the `require-PR` ruleset on `main`, NOT a disabled auto mode.
  3. `allowManagedPermissionRulesOnly: true` so the agent can't add an allow rule re-permitting a main
     push; an MCP deny on any GitHub merge tool (the Bash hook never sees MCP calls). (The old blanket
     `git push` / `gh pr merge` deny rules were REMOVED in the control-plane convergence — they also
     denied feature-branch pushes, muzzling this box's own PR loop; the refspec-aware hook is now the
     single push/merge boundary.)
  4. the vault-sync exemption lives IN the hook (`is_vault_sync_push`), so it needs no
     `managed-settings.json` allow rule and can't be reused as a blanket `git push` allow.

EXCEPTIONS (no per-action click): the vault periodic git sync (below); in-box validation runs
in the nested engine (no external effect).

## SELF-DEVELOP → PR (fedora-desktop's own image — the box opens a PR; `fedora-dev` merges)

```
1 self-develop   edit fedora-desktop source
2 self-validate  run the new image LIVE in the OWN nested CONTAINER_HOST engine; exercise
                 RDP/VNC/web + sync. Bounded to own container. Free. Teardown: --restart=no
                 --rm, scratch volume, NEVER bind-mount $HOME/the vault, explicit rm at session end.
3 propose        open a PR → STOP. fedora-dev merges it on Arthur's clickable APPROVE (you never merge).
4 ship           merged → CI builds + cosign-signs → GHCR; the HOST's pull-based refresh
                 (busy-probe deferral + digest-rollback on health failure, Pull=missing) recreates
                 the box. Host-INITIATED; the box never operates the host (it writes a
                 rebuild.request flag the host watches). VERIFIED sound in fedora-bootstrap source.
```

## VAULT & WIKI  (primary knowledge-work function)

This ClaudeBox OPERATES and MAINTAINS the wiki + vault. Arthur is MAINTAINER/DIRECTOR — not the
writer.

- **AUTHORITY:** the vault's own `CLAUDE.md` / `wiki/CLAUDE.md` / `OBSIDIAN.md` govern all
  content; defer entirely (schema edits, contradiction class-tags, new pages need the vault's
  discrete `AskUserQuestion` approval; `journals/`/`notes/`/`projects/`/`templates/` are
  Arthur's — write only when asked; `wiki/` is Claude-authored under direction).
- **SYNC:** live across devices by **Obsidian Sync** (paid). The GitHub mirror
  (`bear-alchemist/2nd-brain`, **confirmed PRIVATE** — it carries `confidential: true` content)
  is kept current by a **ClaudeBox-managed periodic git sync** (`commit` + `pull --rebase` +
  `push`) — NOT the Obsidian Git plugin. AUTOMATIC (not click-gated) and HISTORY-PRESERVING
  (never force-push → git-recoverable).
- **CREDENTIAL:** the git-sync pushes with a least-privilege token (write to the vault repo only;
  no admin/`workflow`). Never run a generic OS-level cloud-drive sync (rclone or similar) on the
  vault — Obsidian Sync + this git-sync own it.

## SECRET ISOLATION  (the real containment — corrected per the law-v2 ultra-verify)

Credential scoping (§ PUSH SCOPE) bounds a *leaked* token's reach; it does NOT protect the vault
or stop a filesystem read. The vault's local copy and the tokens are plaintext files under one
uid — anything that fully compromises a uid-1000 context holding them reads them. Containment is
therefore about WHERE untrusted content is parsed, not about scoping a credential.

- **Untrusted-content ingest runs in a THROWAWAY sandbox that holds NEITHER a token NOR the
  vault** — only the single input (the clipping/transcript) staged in and the single processed
  note staged out, with NO / strictly-allowlisted network egress. If a malicious clipping hijacks
  the parse step, there is no credential to steal, no full vault to read, and no way to phone
  home. (An earlier draft mounted "the vault tree + the vault-only token" into this sandbox — that
  RE-creates the exact hole and is FORBIDDEN.)
- **Secrets stay OUT of any context that touches untrusted content.** The token + vault writes
  happen in a small orchestrator that never parsed attacker bytes; it stages sanitized note bodies
  in and calls git. Tokens / cloud OAuth / Claude creds are kept with distinct scopes, out of the
  ingest sandbox, never baked into an image layer (Principle 5).
- **Irreducible residue (stated plainly, not papered over):** the orchestrator that writes notes
  into the vault and runs the vault git-sync MUST hold the vault + the vault token and run as uid
  1000. If THAT is compromised, the vault is exposed and the vault token usable — true of ANY
  device that holds the vault (Mac, phone, this box). The goal is to keep that orchestrator small
  and boring (it parses no untrusted content) so compromise is unlikely — NOT to pretend the vault
  is hidden from the thing whose job is to maintain it.

## NON-VAULT CLOUD ACCESS

Google Drive + OneDrive serve NON-vault files only, via **rclone (no daemon)** — `mount`
(on-demand) for all, plus `bisync` for chosen working folders (remotes defined once;
mount-vs-bisync per-folder, switchable). `bisync` MUST run with a delete-guard (`--backup-dir` /
`--max-delete`) so the bidirectional path is recoverable. OAuth tokens live on the home volume,
never in a layer; authorized via in-desktop Firefox. (A live OneDrive daemon was considered and
**deliberately NOT included** — rclone only, unless re-authorized by Arthur.)

## TOOL INSTALL HIERARCHY (inside this box) — retained verbatim from fedora-dev

1. Fedora repos via dnf → `additional_packages`
2. Vendor/dev official RPM or dnf repo → `.repo` (`gpgcheck=1`) → `additional_packages`
3. Vendor/dev-released AppImage → post-assemble, sha256 recorded

NEVER: COPR, third-party repos, pip/pipx/npm/yarn/pnpm/cargo/go/gem/brew global, tarball-on-
PATH, `curl | sh`, `flatpak`, `snap`. (Project-local venvs fine; PATH pollution is not.
managed-settings deny is friction; the BOUNDARY is push-scope + the promotion-gate hook.)

## DO NOT

- `podman run` against any host engine. Only the nested `CONTAINER_HOST` here.
- Directly operate any host other than the nested engine (no `podman`/`systemctl`/`ssh` runtime
  ops against the homelab or VPS). ("No deploy to the homelab" ≠ network isolation — tailnet
  route reach is a separate decision.)
- Merge, push, or tag `main` of ANY repo, including `fedora-desktop`. This box is **PR-only**:
  develop → open PR → STOP; `fedora-dev` merges on Arthur's clickable APPROVE (THE FLEET / PUSH SCOPE).
- Develop or open a PR against ANY repo other than `fedora-desktop` (every other repo is off-limits).
- Bundle a control-plane/guardrail change into a feature change.
- Point a generic OS-level file-sync at the vault; parse untrusted content outside the ingest
  container; bake any secret into an image layer.

## OPERATING FACTS

- `$HOME` = home volume; persists across box rebuilds AND container recreations.
- Nested rootless podman via `CONTAINER_HOST`; **SELinux DISABLED for this container by design**
  (nested podman + fuse-overlayfs + `/dev/fuse`); HOST stays enforcing — don't "harden" away.
- claude-code refreshes DAILY from Anthropic's `latest` channel; the desktop image monthly. It is a package-managed dnf RPM at `/usr/bin/claude` and updates ONLY via the box rebuild — its in-place self-update is **LOCKED OFF** (`DISABLE_UPDATES`/`DISABLE_AUTOUPDATER` set policy-tier in `managed-settings.json` + in `/etc/profile.d/20-claude-no-selfupdate.sh` by `claudebox-init.sh`, which also self-heals any native-build shadow off the home volume). Do NOT run `claude install`/`claude update` to change the version (intentional no-op) — a native build would plant `~/.local/bin/claude`, shadow the RPM on the persistent home volume, and survive every rebuild. To get newer claude-code, run `claudebox-rebuild`. (Ported from fedora-dev #45.)
- Desktop (XFCE/RDP/VNC/web) is the substrate; Obsidian + VS Code + Firefox + **1Password
  (GUI + CLI)** are the interfaces; claude-code (this box) is reached from a desktop terminal
  via `claude`.

## ITEMS THAT ARE ARTHUR'S / THE HOST CLAUDEBOX'S (this box surfaces, does not do)

Reduced by the push-scope decision. Surfaced per this law; applied one-time:

1. Provision a fine-grained, least-privilege gh credential — scoped to push `fedora-desktop`,
   open PRs elsewhere, and push the vault repo; **NO admin, NO `workflow`** — replacing today's
   over-scoped `repo, workflow, read:org` token. (One token suffices; a separate vault token only
   if the vault is a distinct GitHub account — plumbing, not a security split.)
2. Flip the host `policy.json` from `insecureAcceptAnything` to `sigstoreSigned` (pinned to the
   CI OIDC identity) so only CI-built, identity-matching images deploy.
3. (Resolved by push-scope: the host-vs-desktop ownership of `fedora-bootstrap`/`fedora-dev` —
   host owns; desktop proposes. No further reconciliation needed.)
