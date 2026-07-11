# fedora-desktop — Requirements

**v3.2 — owner-approved 2026-07-11.** This document is the measuring stick: every design,
build, validation, and ship decision in this repo is graded against it. It states WHAT must be
observably true and contains no design decisions — no internal software names, no ports, no
config keys. Those belong to the design layer (CLAUDE.md, README.md, the code), which must
TRACE to this document but never constrains it. User-facing products, specifically selected
tools, and standard protocols are named only where they ARE the requirement.

**v3.2 folds in three owner decisions (2026-07-11):** (i) the VNC mirror covers **each** live
session including workers, and the operator may observe worker sessions through it — a scoped
carve-out to D2 (A7, D2). (ii) The admin uses **one** credential across all doors, like every
worker — the previous admin split is retired (already required by A9/D2; recorded here to close
the deviation). (iii) The platform is being **rebuilt zero-base from scratch**, using the prior
implementation as reference only — a build-method ruling, not a requirements change.

## 1. Objective

Deliver the owner a **personal cloud workstation**: a full graphical Linux desktop running on a
headless, GPU-less internet VPS, usable from any device, anywhere.

Two jobs, one desktop:
1. **Knowledge work (primary)** — operate and maintain the owner's second brain (the Obsidian
   vault + LLM wiki), with resident Claude agents as live-in librarians working under direction.
2. **Toolset development (secondary)** — the desktop's users, through their resident agents,
   develop **knowledge-management toolsets that run inside the desktop container** (e.g., the
   VoiceID repository under the oso-gato account). The desktop platform itself is maintained
   upstream by the fleet's dev apparatus, not by this box.

It must be **safe to leave exposed to the public internet indefinitely** (one hardened door, all
else private), **trustworthy with the owner's data** (the vault can never be silently destroyed;
collaborators can't read each other), and **self-maintaining** (patches itself, heals itself, a
failed upgrade rolls back).

**Mandate:** the repo ships **two independent implementations ("lineages") of these same
requirements**. Both must ship: each lineage individually satisfies every requirement below —
§5 records that no lineage deltas are approved.

## 2. Actors & environment

- **Owner/admin** — full desktop, dev tooling, their own resident agent.
- **Workers (dynamic set, provisioned at deploy)** — invited collaborators: desktop + vault work,
  each with their own resident agent. Cooperating, not mutually hostile (one shared kernel is an
  accepted, disclosed ceiling).
- **Resident agents (one per user)** — maintain wiki/vault under direction; develop
  knowledge-management toolsets; contribute via pull requests under their own identity.
- **Environment** — headless Linux VPS, no GPU, public internet; a private overlay network
  ("tailnet") connects the owner's devices and the fleet's hosts.

## 3. Functional requirements

### A. Access

| FR | Requirement |
|---|---|
| A1 | The full desktop is usable from a **standard web browser over HTTPS, from anywhere, with zero client software** (including iOS/iPadOS). |
| A2 | **Exactly one network endpoint is public** (the browser door, on one operator-chosen port). Every other access path is reachable **only over the private network** — by construction, not by convention. |
| A3 | The public door requires a **strong per-user credential PLUS a second factor** that works with standard authenticator apps (self-service enrollment at first login). |
| A4 | The public door **locks out brute force automatically** (repeated failed logins ⇒ temporary source ban). |
| A5 | The public door is **encrypted in transit**; no credential ever crosses the network in the clear. |
| A6 | The desktop is also reachable **natively via standard RDP** from the private network (interoperable with stock Windows/macOS/FreeRDP clients). |
| A7 | **Each** live session (the admin's and every worker's) can optionally be mirrored **via standard VNC** from the private network, armed by an operator-supplied credential at deploy; not armed ⇒ no listener. The operator may observe worker sessions through this mirror (see the D2 carve-out). **Applies to both lineages in full** — verification timelines differ only because one lineage must first build it. |
| A8 | **Terminal access** from the private network: key-only SSH plus a roaming-resilient shell; every terminal login lands in one shared multiplexer session that follows the most recently active device and degrades cleanly across screen sizes. |
| A9 | **One login, one desktop (SSO):** authenticating at any door lands the user on **their own** session without re-authenticating to a second layer; no user can reach another user's session. |
| A10 | The browser door can host **per-user-granted terminal tiles to other fleet hosts** (over the private network). Grants are per-user, exact-match, fail-closed, and **revocation actually revokes**. An ungranted user sees nothing. |

### B. Desktop & workloads

| FR | Requirement |
|---|---|
| B1 | A **complete graphical desktop** (windowing, file management, terminal) rendered **entirely server-side with no GPU, monitor, or login seat** — headless is a hard prerequisite, never a tunable. |
| B2 | Ships the owner's toolset: **Obsidian** (vault editor), **VS Code**, **Firefox**, **1Password** (GUI + CLI), **Ptyxis** (the specifically selected terminal, the default on both lineages), and **Claude Code** (the resident agent, kept current daily). |
| B3 | A user's agent environment can **build and test its toolsets — including in nested, unprivileged containers — entirely inside the box**, without any host access. |

### C. Sessions

| FR | Requirement |
|---|---|
| C1 | A session **survives disconnect indefinitely** — apps keep running unattended. |
| C2 | **Cross-device resume:** disconnect on device A, reconnect on device B (different network address, different screen) ⇒ the **same session**, apps intact, display adapted. No path may silently fork a second session. |
| C3 | Sessions come up **without any server-side manual action** — a freshly booted box serves every access path unaided. |

### D. Multi-user

| FR | Requirement |
|---|---|
| D1 | One always-present admin plus a **dynamic set of workers defined solely by the secret file** (§G): define N users ⇒ N are provisioned, with no code or configuration change. **Zero workers ⇒ behavior identical to a single-user box.** |
| D2 | Per user: own credentials (one credential per user across doors, plus their own second factor), **own desktop session, own persistent home** — private from every other user, including workers vs the admin's data. **Sole carve-out:** the operator/admin may observe a worker's **live session** through the armed VNC mirror (A7) — an intentional supervisory exception limited to live-session observation, disclosed per E6. It grants no access to any user's persistent home or data at rest, and no worker any reach into another user's session, home, or data. |
| D3 | **Workers hold no platform power by construction**: no admin escalation, no host or platform administration, no reach into any other user's home, session, or agent environment — enforced by mechanism, not policy prose. |
| D4 | Optional **shared folder**: full read-write collaboration for all desktop users regardless of their file-creation defaults, without weakening private homes. |
| D5 | Removing a user **disables** their web identity (preserving second-factor enrollment for reinstatement); a grant downgrade takes effect at next boot. |
| D6 | Invalid user definitions are **rejected fail-closed** (no phantom account, no phantom web login) without breaking the boot. |

### E. Data & safety

| FR | Requirement |
|---|---|
| E1 | **No secret or personal identity in any image or commit** — secrets enter only at deploy time, survive container restarts, and are never echoed to logs. |
| E2 | Missing **required** secrets ⇒ the box refuses to serve (fail-fast). Missing **optional** ones ⇒ clean degradation with a logged notice. |
| E3 | **All user data persists** across container recreation and image upgrades. |
| E4 | **Vault safety:** automated vault sync is non-destructive (append-only history, no forced overwrites, conflicts stop safely for a human) and general cloud sync is **mechanically unable** to touch the vault; bulk-delete accidents are bounded and recoverable. |
| E5 | **Untrusted-content processing** (feeding web content to the wiki) runs with no credentials, no vault access, and no network — a leak-proof one-shot sandbox. |
| E6 | The security posture is **honestly disclosed**: any accepted residual risk (shared kernel, in-box-readable vault, weak-auth mirror on the private net) is documented, never papered over with theater. |

### F. Operations

| FR | Requirement |
|---|---|
| F1 | **Deploy is zero-intervention** end-to-end: the host's setup reads all configuration from the secrets source (§G4) and brings up the full product — containers, users, agent environments — with no prompts and no manual steps. An interactive wizard remains available for by-hand spin-ups. The non-interactive contract is versioned in-repo and is the only sanctioned way to run the image. |
| F2 | **Truthful health:** a dead desktop is never reported healthy; a slow first boot is never falsely unhealthy; death of any core service self-heals by restart. |
| F3 | **Self-maintaining:** the image is rebuilt on a fixed cadence with current patches; every agent environment updates daily; the host can pull-refresh the running box with **automatic rollback** on health failure. |
| F4 | Both lineages are **co-deployable on one host** without collisions. |

### G. User agent environments (claudebox)

| FR | Requirement |
|---|---|
| G1 | **Every desktop user — the admin and every worker — has their own running claudebox**: an isolated resident-agent environment, one per user. |
| G2 | Each claudebox is bound to its **own dedicated GitHub App**; its credentials are **pre-authorized**, so no interactive authentication is ever needed at spin-up. |
| G3 | The environment count is **dynamic, driven entirely by the users defined in the secret file** (admin, user1, user2, …): two defined ⇒ two spin up; four defined ⇒ four spin up. No code or configuration change. |
| G4 | **Spinning up these environments on the host is completely zero-intervention**: the host's setup script reads the configuration directly from the **secret file in the ak-private repository** and creates every environment automatically. |
| G5 | That secret file stores **all per-user credentials**: (a) pre-authorized GitHub App credentials, (b) Tailscale tailnet-enrollment details, (c) per-user passwords, (d) usernames — entering the box only at deploy time, per E1. |

### H. Development scope & platform governance

| FR | Requirement |
|---|---|
| H1 | The in-desktop development function exists to build and maintain **toolsets that run inside the desktop container in support of knowledge-management work** — e.g., the **VoiceID** repository under the oso-gato account. |
| H2 | It does **NOT** develop the fedora-desktop platform repository and does **NOT** build or operate other container environments. Platform development belongs to the fleet's dev apparatus. |
| H3 | Toolset changes land via **pull requests under the acting user's own GitHub App identity** — attributable and least-privilege. |
| H4 | The desktop **platform** itself ships through the fleet pipeline: PR-only by mechanism; every change **empirically validated pre-merge** (a disposable candidate is built and actually run, its access paths functionally exercised, on infrastructure that can truly boot it); merged autonomously via **two independent machine gates**; failed validations are **self-diagnosing**. |

## 4. Constraints (bind every design; still not the design)

| # | Constraint |
|---|---|
| N1 | **Provenance:** every installed artifact comes from an official source and is integrity-verified fail-closed; pinned, or resolve-logged where pinning is impossible. |
| N2 | **Minimalism:** no package without a recorded justification; minimal footprint relative to the chosen capability. |
| N3 | **Headless invariant:** no design may ever require a GPU, display, or seat. |
| N4 | **No theater:** a guard or check that cannot deliver what it implies is removed or honestly re-scoped. |
| N5 | **Empiricism:** runtime behavior is proven by running it, never by reasoning about it. |
| N6 | **Control-plane discipline:** guardrail changes ship standalone and conspicuous, never bundled with features. |

## 5. Approved lineage deltas

**None.** Both lineages must satisfy §3 in full — including A7 (VNC). Where a lineage has not yet
built a required capability, that is unmet development work (§7), never a requirements delta; the
only permitted difference between lineages is how quickly each can be verified.

## 6. Acceptance bar — "shipped" means

For **each lineage independently**:

1. **Build green** from a clean tree (CI).
2. **Automated pre-merge gate GREEN**: a disposable candidate **boots headless and every required
   access path is functionally exercised** — browser door serves AND a real authentication
   round-trip proves the credential+second-factor chain live (valid credentials draw a
   second-factor challenge; invalid are rejected); RDP answers a real protocol handshake; VNC
   (both lineages, A7) answers its protocol handshake when armed and is absent when not; the
   desktop session is actually rendering; multi-user provisioning + isolation hold; health is
   truthful. A RED verdict is self-diagnosing (H4).
3. **Image published** to the registry by CI.
4. **Live-deploy dress rehearsal** on a real host per the runbook: real pixels painted through the
   browser and native RDP, second-factor enrollment + login, brute-force lockout observed,
   cross-device resume observed (C2), worker lockdown spot-checked (D3), fleet tiles reach real
   hosts (A10).

## 7. Gap register (as of 2026-07-11 — drives the build plan; update on every close)

**Gate-closable verification gaps:** the automated gate proves A2 (partially), B1, C3, D1
(partially), D6, E2, F2, and *port-level-only* A6; it does **not** yet prove A3/A4 (no real login
round-trip), A6 at protocol level, or A7 at all. C2, A10, A4-behavior, and D3 remain
dress-rehearsal items by nature.

**Requirements not met by the current implementation (net-new build work):**
- **A7 on grd:** the current grd design ships **no VNC mirror** and silently ignores the arming
  credential — the capability must be built and then gate-verified like every other path. The
  repo's internal doc contradiction resolves **toward implementing it**, not documenting its
  absence.
- **§G:** unmet — the current design provisions **one** agent environment for the admin only, on
  a shared fleet identity, with an interactive wizard; per-user claudeboxes (G1), per-user
  dedicated pre-authorized GitHub Apps (G2), dynamic secret-file-driven environment count (G3),
  and zero-intervention host provisioning from the ak-private secret file (G4–G5, F1) do not
  exist yet.
- **§H:** realigns development scope (the currently stamped law scopes the agent to the
  fedora-desktop repo itself — the inverse of H1/H2) — law/policy must be re-stamped to match.

**Ship status:** lineage 1 (incumbent) passed the dress rehearsal 2026-06-25 against the
pre-v3 bar; **neither lineage has yet shipped against THIS document.** Per the v3.2 build-method
ruling, the platform is being rebuilt zero-base from scratch — the prior tree is reference only,
and every file is re-derived from and re-justified against this document before it ships.
