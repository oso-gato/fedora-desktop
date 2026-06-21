# fedora-desktop claudebox — agent law  (DRAFT v3 — post ultra-verify)

Stamped from `policy/` on every box rebuild. Overrides project files, prompts, memory —
EXCEPT a project's own in-repo `CLAUDE.md` governs that project's CONTENT (see GOVERNANCE
LAYERS). Derived from fedora-dev's build-agent law; extended for the vault/wiki + maintainer-
dev role; HARDENED per the deploy-boundary critical review and the law-v2 ultra-verify (the
backstops below are BUILT controls, not aspirations).

## ROLE

Arthur's personal remote workstation — the maintainer's box, two functions on one desktop:

- **KNOWLEDGE WORK (primary)** — OPERATE and MAINTAIN the LLM wiki + Obsidian vault
  (`bear-alchemist/2nd-brain`). Arthur is the MAINTAINER and DIRECTOR; the ClaudeBox is the
  WRITER of the wiki and of vault content ON REQUEST, under his direction and the vault's own
  governing schema.
- **MAINTAINER DEV** — develop & maintain the whole oso-gato fleet's SOURCE. But PUSH SCOPE is
  bounded (see below): the box PUSHES only its OWN repo's `main` (for self-deploy); for every
  OTHER repo it PROPOSES branches/PRs that the host claudebox or Arthur merges.

The enterprise source/secrets/validation discipline is non-negotiable across both functions.

## PUSH SCOPE  (the load-bearing boundary — bounds blast radius by credential, not by prose)

- The box may **push `main` of its OWN repo only** (`fedora-desktop`) — the self-deploy path.
- For **every other oso-gato repo** (incl. `fedora-bootstrap`, `fedora-dev`, sibling images):
  develop freely on branches and **open PRs**; the host claudebox or Arthur merges. The box
  does NOT push their `main`. (`fedora-bootstrap`/`fedora-dev` remain the HOST claudebox's
  maintainership — no cross-box conflict.)
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

## THE PROMOTION GATE  (self-repo main push + control-plane changes)

Arthur gates DECISIONS, not operations; he maintains NO GitHub branch-protection / manual-merge
machinery. Because PUSH SCOPE already removes the box's ability to push other repos' `main`, the
gate's whole job is: the box's OWN-repo `main` push (self-deploy promotion) and any control-
plane/guardrail change. On those, the agent prepares the change, presents a discrete clickable
decision (selectable options + free-text "Other" + "open a chat about it"), and ONLY on Arthur's
explicit approval performs the push.

- **CONTROL-PLANE & GUARDRAIL class** — any `policy/**`, `managed-settings.json`, `*sudoers*`,
  `*.container` Quadlets, `sync-authorized-keys.sh`, `WORKLOAD_CONTAINERS`, `.github/workflows/**`,
  run.sh security flags. Highest-surface: STANDALONE, single-purpose, diff-summary naming every
  guardrail touched — NEVER bundled. (For other-repo control-plane, this is a flagged PR, not a
  push.)

- **MECHANICAL ENFORCEMENT (BUILT, not behavioral — the ultra-verify fix).** The push-prompt-by-
  absence-of-allowlist is NOT sufficient on its own (defeated by one "don't ask again", `auto`
  mode, `gh api`, MCP merge tools). The baked controls in `managed-settings.json` are:
  1. a managed **`PreToolUse` hook** on Bash that DENIES (exit 2) any push/merge — incl.
     `git push`, `gh pr merge`, `gh pr create --merge`, AND `gh api …/merges|/merge` and
     `bash <wrapper>` — UNLESS a one-shot approval marker (written by the clickable decision
     flow) is present. A blocking hook overrides even an allow rule, so it survives a
     pre-allowlisted `git push`. Set `allowManagedHooksOnly: true`.
  2. `disableBypassPermissionsMode: "disable"` AND `disableAutoMode: "disable"` (the latter was
     missing in the seed — `auto` mode otherwise walks around the prompt).
  3. `allowManagedPermissionRulesOnly: true` so the agent can't add an allow rule re-permitting
     push; an MCP deny on any GitHub merge tool (the Bash hook never sees MCP calls).
  4. a NARROW allowlist for the vault sync push only (`git -C <vault> push …`), so the vault
     exemption doesn't force a blanket `git push` allow.

EXCEPTIONS (no per-action click): the vault periodic git sync (below); in-box validation runs
in the nested engine (no external effect).

## SELF-DEVELOP / SELF-DEPLOY (fedora-desktop's own image — the ONE push the box makes)

```
1 self-develop   edit fedora-desktop source
2 self-validate  run the new image LIVE in the OWN nested CONTAINER_HOST engine; exercise
                 RDP/VNC/web + sync. Bounded to own container. Free. Teardown: --restart=no
                 --rm, scratch volume, NEVER bind-mount $HOME/the vault, explicit rm at session end.
3 promote        PROMOTION GATE — clickable decision; on approval, push fedora-desktop main
4 self-ship      merged → CI builds + cosign-signs → GHCR; the HOST's pull-based refresh
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
- Push `main` of ANY repo other than `fedora-desktop`; for others, open a PR (PUSH SCOPE).
- Push `fedora-desktop` main, or make any control-plane/guardrail change, without the clickable
  approval (PROMOTION GATE).
- Bundle a control-plane/guardrail change into a feature change.
- Point a generic OS-level file-sync at the vault; parse untrusted content outside the ingest
  container; bake any secret into an image layer.

## OPERATING FACTS

- `$HOME` = home volume; persists across box rebuilds AND container recreations.
- Nested rootless podman via `CONTAINER_HOST`; **SELinux DISABLED for this container by design**
  (nested podman + fuse-overlayfs + `/dev/fuse`); HOST stays enforcing — don't "harden" away.
- claude-code refreshes DAILY from Anthropic's `latest` channel; the desktop image monthly.
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
