# GRD go-live — SESSION RESUME HANDOVER (human readme)

> **STATUS: ⏸ PAUSED at Step 2 of 12.** The grd live validation is blocked by an **erebus
> rootless-podman ENGINE problem — NOT our code.** Recover the engine, then resume.
>
> **Resume this exact session (deterministic):**
> ```
> claude --resume 6ce43345-bc2e-4b11-85b9-b3a4543574fe
> ```
> Local working notes (fuller detail): `/home/core/grd-churn-notes.md` · This file also lives in
> the repo at `validation/GRD-RESUME-HANDOVER.md` and as a GitHub Issue (durable copy).

---

## 1. What are we doing?
Bringing the **grd** lineage (GNOME‑Wayland, systemd‑PID‑1) to functional equivalence with the
**frozen xrdp v1.0.0** production lineage, then host‑validating it **live on erebus** exactly like
xrdp's go‑live B‑gates. Session‑creation route = the host‑proven **GNOME‑50 turnkey** path (gdm
`CreateUserDisplay` autologin → per‑user `gnome-remote-desktop-headless` → `grdctl --headless`).
Re‑confirmed (ultra‑verify, 3 agents): my PRs do **not** change that route.

## 2. The total plan
- ✅ Build the grd equivalence — 5 PRs (#68–72), **all merged to main (`b544aef`)**, CI rebuilt + cosign‑signed `:grd`.
- ✅ Verify the route is unchanged + the PRs align with the validated turnkey path.
- ⏳ **Live host validation on erebus — 12 steps:**
  - Deploy: **1** pull scripts · **2** pull image+digest · **3** spin up · **4** verify running digest · **5** healthy
  - B‑gates: **6** ports/paint · **7** web+TOTP · **8** multi‑user paint · **9** grant matrix · **10** fleet shells · **11** claudebox/dev · **12** resume+auth‑ban+shared
- ⬜ If GREEN: record the grd go‑live result; grd graduates from experimental `:grd`.

## 3. Which step are we on?
**Step 2 of 12** (pull `:grd` on erebus) — **BLOCKED** by the engine problem (see §5).

## 4. What has been done?
- **5 PRs merged** (main = `b544aef`): **#68** session‑race two‑pass fix (the *paint* fix) · **#71** harness
  parity (claudebox dev + daily/rebuild machinery + sshd/fail2ban/host‑keys + cloud/vault sync) ·
  **#69** spin‑up lineage‑aware `:grd` default · **#70** run.sh.grd `:grd` default (control‑plane) ·
  **#72** the grd go‑live runbook.
- CI rebuilt + **cosign‑signed `:grd`** from `b544aef` (tip run grd job = success). `:grd` carries all fixes.
- Route verified unchanged vs the host‑validated GNOME‑50 turnkey path (ultra‑verify, no divergence).
- **Validation Step 1 done:** erebus pulled merged main (deploy scripts `spin-up.sh`/`run.sh.grd` updated).

## 5. Steps to follow (resume here)

### FIRST — recover erebus's engine (host‑OPERATE; NOT the build agent's job → host claudebox / `fedora-bootstrap`)
- **Symptoms:** `podman pull :grd` unpack fails — `insufficient UIDs/GIDs … requested 0:7 /etc/cups … run podman system migrate`
  (core subuid/subgid is **fine**: `524288:65536`; podman **5.8.2**, a recent upgrade). `podman exec fedora-desktop`
  dies on a **broken container cgroup** (`crun … cgroup.freeze: No such file or directory`). `fedora-desktop` +
  `fedora-dev` read **(unhealthy)** — **BUT `web8443=200`**, so the prod box is **still serving users**; the
  "unhealthy" is a **management‑layer artifact, not an outage.**
- **Likely cause (UNCONFIRMED trigger):** rootless engine left inconsistent by the podman 5.8.2 upgrade + a
  `systemd --user` / cgroup disruption (~9 h before 2026‑06‑26, matching the `fedora-desktop` restart).
- **Recovery (operate):** `podman system migrate` (fixes the *storage* half only) → **recreate the broken‑cgroup
  containers via their sanctioned deploy** (host workload‑refresh harness / `run.sh`), one at a time, in a
  low‑impact window (brief web‑door blip) → determine *why* the user‑manager cgroup reset so it doesn't recur.

### THEN — resume grd validation from Step 2
- On erebus: `podman pull ghcr.io/oso-gato/fedora-desktop:grd` (record the **digest**) →
  `LINEAGE=grd ./spin-up.sh` with **`WEB_PORT=8444`** (coexist with the xrdp prod box on 8443) + a couple extra
  users + fleet tiles (to exercise the multi‑user/fleet gates) → **verify the RUNNING container's image digest**
  (the `$IMAGE` lesson) → wait for **`(healthy)`** → walk **B‑gates 6–12**.
- Full runbook: **`validation/GO-LIVE-VALIDATION-grd.md`**.

## Key facts
- main HEAD: **`b544aef`** · image: **`ghcr.io/oso-gato/fedora-desktop:grd`** (cosign‑signed).
- **xrdp production is UNTOUCHED** by these PRs — frozen tag `xrdp-v1.0.0`, `:latest` rebuilds byte‑identical.
- grd is **systemd‑PID‑1** → needs a cgroup‑v2‑delegating host (erebus qualifies); it CANNOT boot in the
  nested build engine, so the live B‑gates are the only end‑to‑end proof (none of #68–72 is runtime‑proven yet).
