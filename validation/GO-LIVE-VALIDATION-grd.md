# Go-live validation — fedora-desktop **grd** lineage (GNOME-Wayland / GRD)

The grd-lineage equivalent of `GO-LIVE-VALIDATION.md` (which validated **xrdp v1.0.0**, now the
frozen, tagged production lineage `xrdp-v1.0.0`). Goal: bring the grd lineage to the SAME green
end-to-end production proof on a live host, mirroring xrdp's B-gates.

**grd is functionally equivalent to xrdp v1.0.0 by DESIGN — same web door (Apache Guacamole on
:8443), same multi-user + per-user fleet grants + TOTP + auth-ban + shared folder, same harness
(claudebox / key-only tailnet-only ssh / cloud+vault sync). Only the INIT contract + the desktop differ:**
systemd-PID-1 + GNOME-50-Wayland headless (gdm-spawned per-user `gnome-remote-desktop-headless`
on per-user loopback RDP ports), vs xrdp's supervised-bash + XFCE/X11.

> **HARD PREREQUISITE (STOP-AND-SURFACE).** grd is **systemd-PID-1** → it needs a host that grants
> **cgroup-v2 delegation + a writable `/sys/fs/cgroup`** (`run.sh.grd` passes `--systemd=always
> --cgroupns=host -v /sys/fs/cgroup`). It CANNOT boot in the nested build engine, so everything
> below is **real-deploy-only** on a delegating host — there is no "Part A spikeable" shortcut like
> xrdp had (the session primitive was already spiked separately: `validation/grd-headless-spike.sh`).

---

## What is already proven vs what this runbook proves

**HOST-PROVEN (erebus, 2026-06-24, `validation/grd-headless-spike.sh`):** the variant-1 session
primitive — per user, gdm `CreateUserDisplay` spawns a headless autologin GNOME session (no greeter,
real `class=user` logind session), `mutter` paints **surfaceless on llvmpipe with no GPU/seat**, GRD
`--headless` serves NLA RDP on a per-user loopback port, a SINGLE credential SSOs to a painted
desktop, and the session RESUMES on reconnect — for **single-user AND 2 concurrent users**.

**NOT yet proven end-to-end (this runbook):** the full path **through Apache Guacamole** on a real
deploy — web+TOTP, per-user paint through the tiles, the fleet-grant matrix, cross-device resume,
shared folder, auth-ban — AND that the **shipped code** (not the spike harness) brings it all up.

**MUST-MERGE-FIRST (the grd go-live PR set — without these the deploy is broken):**
- **#68** `feat/grd-session-race-twopass` — the session-bus race fix (the spike waited 25s before
  `grdctl`; the shipped entrypoint had dropped it → black desktop). **Without this grd does not paint.**
- **#71** `feat/grd-harness-parity` — claudebox dev capability (podman.socket + eager assemble) +
  the daily-refresh timer + rebuild-watcher + sshd-hardening/host-keys + cloud/vault sync.
  **Without #71, `claude`/claudebox is dead on grd and ssh is unhardened.**
- **#69** `feat/grd-spinup-image-default` — `spin-up.sh` defaults to `:grd` for LINEAGE=grd
  (else it pulls the **xrdp** image and runs it under `--systemd=always` → box never comes up).
- **#70** `control-plane/grd-runsh-image-default` — `run.sh.grd` defaults to GHCR `:grd`
  (CONTROL-PLANE → needs the `control-plane-approved` label to merge).

After all four merge, CI republishes a signed `ghcr.io/oso-gato/fedora-desktop:grd` carrying the
fixes. **Validate against THAT image — verify the running digest (the xrdp `$IMAGE` lesson).**

---

## B — real-deploy validation (the go-live gate)

Deploy on a **cgroup-v2-delegating host on the tailnet**, with the dev box + host up on the tailnet
and the fleet SSH path in place. Identical access model to xrdp; only the deploy contract differs.

### B0 — preconditions (must be true first)
- **The host grants cgroup-v2 delegation + writable `/sys/fs/cgroup`.** (erebus, Fedora-CoreOS-class,
  qualifies.) If absent, PID-1 systemd never reaches `graphical.target` and the box never goes healthy
  — `run.sh.grd` discloses this; check `podman logs -f fedora-desktop-grd`.
- **The four go-live PRs are merged** and CI has republished a signed `:grd` (see above).
- **The fleet hosts** (`fedora-dev`, `erebus`) are up, on the tailnet, sshd reachable, and the tailnet
  **`ssh` ACL grants this desktop node action `accept` (NOT `check`)** — keyless Tailscale-SSH then
  authenticates by tailnet identity (see `fleet-tile-keyless-tailscale-ssh-acl`, `ZTNA-ACCESS.md`).
- **Distinct `WEB_PORT` from any xrdp box on the same host** (the only collision — both default 8443;
  all volume/container/hostname names are already grd-distinct).

### B1 — deploy grd
```sh
# Interactive (recommended): the wizard now defaults the image to :grd for LINEAGE=grd.
LINEAGE=grd ./spin-up.sh
# or non-interactive:
RDP_PW='<strong>' GUAC_PW='<strong>' WEB_PORT=8444 \
  FLEET_SSH='fedora-dev 100.x.x.dev 22 core;erebus 100.x.x.host 22 core' \
  USER1_NAME=jenny USER1_PW='<strong>' USER1_ACCESS=none \
  USER2_NAME=bob   USER2_PW='<strong>' USER2_ACCESS=all \
  TS_AUTHKEY=tskey-… ./run.sh.grd
```
**★ Verify the running image (the xrdp $IMAGE lesson):**
`podman inspect fedora-desktop-grd --format '{{.Image}}'` == the digest of the freshly-published
`:grd`. Do NOT trust the tag; verify the digest.

### B2 — the go/no-go gates (ALL must pass — mirrors xrdp B2)
1. **Healthy:** `podman inspect -f '{{.State.Health.Status}}' fedora-desktop-grd` → `healthy`
   (web :8443 200 **and** `/dev/tcp :3389` **and** `mariadb-admin ping`). With the #68 fail-closed,
   a dead **core** desktop now keeps the box UNHEALTHY instead of false-green — so `healthy` here is
   a stronger signal than before, but still see gate 3 (health does not probe per-USER ports).
2. **Web + TOTP:** browse `https://<public-ip>:<WEB_PORT>/guacamole/` → login `core`/`GUAC_PW` →
   TOTP QR on first login, code on next → **painted GNOME desktop** in the browser.
3. **Multi-user paint:** log in as `jenny` (USER1) → her **own** painted GNOME session on her own
   loopback port (:3390). **This is the gate the #68 race fix de-risks** — if jenny is black while
   core paints, the per-user bus-settle still lost the race; check
   `journalctl -u 'gnome-headless-session@jenny'` + the `[grd]` lines in the firstboot journal.
4. **Access-grant matrix:** `jenny`(none)→Desktop only · `bob`(all)→Desktop + every fleet tile ·
   `core`→Desktop + all tiles. Then **downgrade** bob (`USER2_ACCESS=fedora-dev`) and redeploy →
   the `erebus` tile is **revoked** (the shared `guac-db-provision.sh` DELETE-then-INSERT reconcile).
5. **★ Fleet over Tailscale (the primary ask):** as `core`, click each tile → a real `core@` shell on
   that fleet host **over the tailnet** (keyless Tailscale-SSH; ACL `accept`). Confirm the source is
   this node's tailnet IP.
6. **Cross-device resume:** RDP/web as `jenny` from device A, disconnect, reconnect from device B at a
   **different** geometry → the **same** GNOME session resumes (apps still open). **NOTE: grd has NO
   bpp=24 invariant** (that is an xrdp/sesman key) — GRD's session is a resident logind session
   decoupled from the transient RDP connection (persistent resume landed GNOME 47), so IP/resolution
   are not session keys. Resume should be cleaner than xrdp's.
7. **auth-ban:** 3 bad web logins → source IP locked out ~900s (same extension as xrdp).
8. **claudebox / dev capability (core only) — the #71 gate:** open a desktop terminal as `core`
   (or ssh in) → run `claude --version` (the wrapper is `0750 core:core`); confirm `echo
   $CONTAINER_HOST` is the podman socket and `podman info` reaches fedora-desktop-grd's engine; confirm
   `~/.local/share/fedora-dev/.git` exists (the live clone) and `~/.local/state/claudebox/.assembled`
   is present. As a **worker** (jenny): `sudo -v` denied, `claude` not executable, no `CONTAINER_HOST`,
   cannot read `/home/core`.

### B3 — grd-specific traps to watch
- **The session-bus race (#68):** the fix polls `/run/user/$uid/bus` (≤40s) before `grdctl`. If a
  user is black, that user's bus likely never came up in 40s — inspect
  `journalctl -u 'gnome-headless-session@<user>'` and the firstboot `[grd]` lines.
- **Per-user port binding:** confirm each user's GRD bound its pinned loopback port with negotiation
  OFF (`ss -ltnp` in the container should show :3389 core, :3390 USER1, …). A negotiated port would
  cross-wire a tile to the wrong desktop. (set-port/disable-port-negotiation verified present in
  grdctl 50.1.)
- **`security=any` NLA handshake:** the Guacamole RDP tiles use `security=any` (GRD is NLA-only;
  `tls`/RDSTLS would refuse). The spike proved `/sec:nla` directly; the through-Guacamole leg is the
  new bit.
- **cgroup delegation (B0):** the #1 silent host-precondition failure — box stuck not-healthy.
- **Healthcheck depth:** health probes only core's :3389, not USER ports or TOTP — gate 3 (paint) and
  gate 8 (claudebox) are MANUAL click/shell probes, as on xrdp.

---

## Known follow-ups (P2 — NOT go-live-blocking; tracked for after the green)
- **claudebox daily-refresh `.timer` + rebuild-watcher `.path`** — now **wired in #71** (the
  systemd-PID-1 equivalent of xrdp `entrypoint.sh:539-553, 523-533`); host-validation-only like the
  rest. No longer an open gap.
- **ENABLE_AUDIO passthrough** is a no-op on BOTH lineages (not exported by spin-up / not in
  secrets.env). Default-off (reading desktop), so non-blocking; a both-lineage fix (the xrdp half is
  frozen, so grd-only or a deliberate de-freeze).
- **Native VNC mirror (:5900)** — grd v1 has none (RFB_PW accepted+ignored); `grdctl --headless vnc`
  can expose it per user as a follow-up.
- **Richer healthcheck** probing per-user ports — touches run.sh.grd (control-plane), optional.

## Build-validation status (what was proven WITHOUT a live host)
- **Build-green:** the grd image builds clean with every fix (local `podman build --isolation chroot`,
  exit 0; CI PR builds are the proof of record).
- **Assembly-verified:** the fixes are present in the built image — `default.target.wants/{claudebox-
  bootstrap,cloud-sync,vault-gitsync}.service` + `sockets.target.wants/podman.socket` enabled; the sshd
  hardening drop-in, persistent-host-key drop-in, and bootstrap script all present;
  baked host keys stripped.
- **Static-verified:** `bash -n` on all scripts, `systemd-analyze` on the units, the session bring-up
  diffed against the host-proven spike (two-pass + bus-poll), the web-door params (`security=any`,
  per-user ports, no bpp pin) checked against the shared `guac-db-provision.sh` contract.
- **NOT proven locally (host-only, by design):** the systemd-PID-1 boot, the per-user paint through
  Guacamole, TOTP, the fleet shells, resume, and the claudebox assemble at runtime — i.e. every B2 gate.

Related: `GO-LIVE-VALIDATION.md` (xrdp v1.0.0, GREEN), `grd-headless-spike.sh`, `ZTNA-ACCESS.md`.
