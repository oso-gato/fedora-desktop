# Go-live validation — fedora-desktop (current main)

The pre-go-live end-to-end check. Verdict from the design pass: **xrdp is the full,
wired product — validate and ship it; grd is NOT a multi-user/fleet box yet** (its
session primitive is proven, but `run.sh.grd` doesn't pass `USER*`/`FLEET_SSH`, the
entrypoint never `tailscale up`s, and there's no grd wizard — a tracked follow-up).
So **this runbook validates the xrdp lineage** as the go-live product.

Two parts: **(A) spikeable** (throwaway container on any host) and **(B) real-deploy-only**
(needs a live tailnet + the dev box and host actually up — *this* is the maintainer's
"fleet tiles reachable through Tailscale + Guacamole working" ask, and it cannot be faked).

---

## A — spikeable (cheap, run first, any host)

Proves the session + the **multi-user** mechanism (the one thing not yet exercised on main):

```sh
./validation/xrdp-headless-spike.sh            # core + u1, one :3389, each paints its own :1x
NUSERS=4 ./validation/xrdp-headless-spike.sh   # core + u1..u3
```
**PASS** = `A/C:3389 PASS` + every user `paint=PASS` + one `:1x` per user in the session list.
(The grd session primitive is already proven: `./validation/grd-headless-spike.sh` + `NUSERS=3 …`.)

**VALIDATED GREEN on erebus 2026-06-24** (NUSERS=2): core + u1 each painted their own XFCE
`:1x` over the shared `:3389`, live `xfwm4`+`xfce4-panel` per user. Getting there surfaced a
**load-bearing dependency for the desktop to paint at all on Fedora 44**: SVG icons now decode
via `glycin` inside a **`bwrap` sandbox**, which needs the container security flags
(`--security-opt label=disable` + `--cap-add SYS_ADMIN` + `--device /dev/fuse`) — without them
GTK can't load an icon, hits `g_error()`, and the whole XFCE session **aborts (exit 134)**.
Both production deploy paths already carry these (`run.sh:108-113`, the Quadlet's
`SecurityLabelDisable=true`/`AddCapability=…SYS_ADMIN`/`AddDevice=/dev/fuse`). **Treat them as
desktop-critical, not just nested-podman plumbing — a future "SELinux hardening" that drops
`label=disable` would silently stop the desktop painting.** (The other three spike fixes —
xrdp key ownership, `~/.Xclients`, `dbus-uuidgen` machine-id — are things production already
does; they were throwaway-image gaps, not product gaps.)

**BACKEND finding + fix (2026-06-24).** The first green above used xrdp's *auto-selected* session,
which on Fedora 44's stock `xrdp.ini` (`[Xorg]` commented, only `[Xvnc]` active) is **Xvnc** — so
it validated the Xvnc backend, not the xorgxrdp/Xorg one the lineage is built for. Investigation
(see PR #38 thread) found production was effectively serving **Xvnc** too: the `xrdp-sesrun -t Xorg`
pre-warm *does* create an Xorg session (it reads `sesman.ini`, where `[Xorg]` is enabled), but
every incoming connection took the only-active `[Xvnc]` section and forked a **separate Xvnc**
session — orphaning the pre-warm. **Fix: PR #41** uncomments `[Xorg]` + sets `autorun=Xorg` in
`install.sh`. **Re-VALIDATED GREEN on the Xorg backend** (`RDP_BACKEND=xorg`, NUSERS=2): core + u1
each paint their own `/usr/libexec/Xorg` `:1x` (backend gate: Xorg procs=2, Xvnc procs=0). The
spike now defaults to `RDP_BACKEND=xorg` and **fails** a run that silently falls back to Xvnc.
Still real-deploy-only on Xorg: the pre-warm + cross-device resume (bpp=24), and audio/H.264 on
the native-RDP-over-tailnet path.

---

## B — real-deploy validation (the go-live gate)

Deploy on the **production-class host on the tailnet**, with the **dev box and host actually up
on the tailnet** and the fleet SSH path in place. Throwaway containers can't do this.

### B0 — preconditions (must be true first)
- The deploy host can run the image; for grd only, it needs cgroup-v2 delegation (xrdp doesn't).
- The **fleet hosts** (`fedora-dev`, the VPS/`erebus`) are **up, on the tailnet, sshd reachable**, and have the **`FLEET_SSH_KEY`** public half in their `authorized_keys`. (Keyless Tailscale-SSH ACL is **NOT** a usable path for the browser-SSH tiles — confirmed dead through guacd, see B3 + `ZTNA-ACCESS.md`.)
- Decide MagicDNS vs IP: `tailscale up` here omits `--accept-dns`, so in-container name resolution of `fedora-dev`/`erebus` is **not guaranteed** — prefer the `100.x` tailnet IPs in `FLEET_SSH` unless you've confirmed MagicDNS resolves inside the container.

### B1 — deploy xrdp with the full secret set
```sh
RDP_PW='<strong>' GUAC_PW='<strong>' WEB_PORT=8443 \
FLEET_SSH_KEY=/path/to/fleet_key \
FLEET_SSH='dev 100.x.x.dev 22 core;vps 100.x.x.host 22 core' \
USER1_NAME=jenny USER1_PW='<strong>' USER1_ACCESS=none \
USER2_NAME=bob   USER2_PW='<strong>' USER2_ACCESS=both \
USER3_NAME=dev1  USER3_PW='<strong>' USER3_ACCESS=dev \
USER4_NAME=ops1  USER4_PW='<strong>' USER4_ACCESS=host \
TS_AUTHKEY=tskey-... IMAGE=ghcr.io/oso-gato/fedora-desktop:latest ./run.sh
```
(or `./spin-up.sh` interactively — it drives `run.sh`). Use **canonical** fleet labels `dev`/`vps`
(grant matching is substring-based: `dev` matches any `*dev*`, `host` matches `*vps*|*host*`).
If deploying via the **Quadlet** instead of `run.sh`, first **uncomment** the per-user `Volume=` lines
in `fedora-desktop.container` (else extra users lose `/home` on recreation) and note the Quadlet has
**no fleet env** — fleet tiles work only via `run.sh` today.

### B2 — the go/no-go gates (ALL must pass)
1. **Healthy:** `podman inspect -f '{{.State.Health.Status}}' fedora-desktop` → `healthy` (the #32 cmd = `:8443` 200 **and** `/dev/tcp :3389` open **and** `mariadb-admin ping`).
2. **Web + TOTP:** browse `https://<public-ip>:8443/guacamole/` → login `core`/`GUAC_PW` → TOTP QR on first login, code on next → painted **XFCE** desktop in the browser.
3. **Multi-user paint:** log in as `jenny` (USER1) → her **own** painted session (the least-proven path — watch for a black second session).
4. **Access-grant matrix:** `jenny`(none)→Desktop only · `dev1`(dev)→Desktop+`ssh-dev` · `ops1`(host)→Desktop+`ssh-vps` · `bob`(both)→Desktop+`ssh-dev`+`ssh-vps` · `core`→Desktop+all. Then **downgrade** `bob` to `dev` and redeploy → the `ssh-vps` tile is **revoked**.
5. **★ Fleet over Tailscale (the primary ask):** as `core`, click **`ssh-dev`** → a real shell on the **dev box**; click **`ssh-vps`** → a real shell on the **host** — both **over the tailnet** (not public). Confirm the source is this node's tailnet IP.
6. **Cross-device resume:** RDP as `jenny` from device A, disconnect, reconnect from device B at a **different** geometry → the **same** session resumes (apps still open) — the bpp=24 invariant.
7. **auth-ban:** 3 bad web logins → source IP locked out ~900s.

### B3 — known traps to watch (from the design pass)
- **MagicDNS:** fleet tiles dial nothing if names don't resolve in-container → use `100.x` IPs (see B0).
- **Keyless Tailscale-SSH through guacd is CONFIRMED DEAD** (erebus 2026-06-25): on a check-mode tailnet it demands a browser re-auth guacd's libssh2 can't surface, so the tile hangs forever → **`FLEET_SSH_KEY` is REQUIRED**, not a fallback (per `ZTNA-ACCESS.md`).
- **No healthcheck probes a fleet tile** → a down/unauthorized bastion is invisible to health/rollback; B2-gate-5 is a **manual** click-probe.
- **TOTP enrollments live in the `/var/lib/mysql` volume** → losing it wipes all 2FA; do a backup/restore drill before go-live.
- **A `dev`/`host` grant = a `core`-admin shell** on that fleet box via `FLEET_SSH_KEY` publickey to `core@<target>` (per CLAUDE.md) — confirm that's intended for the users you grant it to.

---

## B — RESULTS (real deploy on erebus, 2026-06-25)

xrdp lineage, image `ghcr.io/oso-gato/fedora-desktop:latest`, multi-user (core + jenny/none +
bob/both). **Caught and fixed a production-only crash during this pass** (see the gid note below).

| Gate | Status | Evidence |
|---|---|---|
| B2-1 Healthy | ✅ PASS | `podman inspect` → `healthy` (web 200 + `:3389` open + mariadb ping) |
| B1 Xorg backend | ✅ PASS | Xorg procs=1, Xvnc procs=0, session on `:10` — #41 backend live + `xrdp-sesrun` pre-warm present |
| B2-2 Web + TOTP | ✅ PASS | public-IP `:8443` login `core`/`GUAC_PW` → TOTP QR enroll → painted XFCE in the browser |
| B7 Shared folder | ✅ PASS | jenny WROTE `/home/shared`, bob READ + APPENDED via the default `group:deskshare:rwx` ACL; `/home/shared` = `root:deskshare 2770`; bob DENIED jenny's `0700` home |
| gid-collision fix | ✅ PASS | jenny home `jenny:jenny` **gid 8001** (the reserved 8000+n range) — the #45 `gid==uid==1000+n` scheme had collided with 1Password's baked gid 1001-1003 and crashed PID 1; **#48** moved GID→8000+n + made the chown numeric/non-fatal; redeploy clean |
| B2-5 ★ Fleet tiles | ⚠️ **OPEN** | routing OK (`fedora-dev:22`, `erebus:22` both reachable) but **keyless Tailscale-SSH is dead through guacd** (check-mode browser re-auth, tile hangs). Fix = `FLEET_SSH_KEY` (publickey) — **not yet demonstrated**: the host has no usable private key (`~/.ssh` holds only `authorized_keys`; `oso-gato.keys` are public). **Operational follow-up: supply a private key whose pubkey is trusted on the fleet hosts, then re-run gate 5.** |
| B2-3/4 Multi-user/grant | ⏳ pending eyeball | jenny's own session + the access-grant matrix (UI click-through) |
| B2-6 Cross-device resume | ⏳ pending | the bpp=24 device-A→device-B resume drill |
| B2-7 auth-ban | ⏳ pending | 3 bad logins → ~900s lockout |

**Verdict so far:** the deploy is healthy and the core web/desktop/shared-folder/ownership paths
are real-deploy-proven; **B5 (fleet shells) is the one gate that is diagnosed-but-not-passing** —
its blocker (keyless dead) is understood and the fix (`FLEET_SSH_KEY`) is known and requires no
code change, but it has **not been demonstrated** because no private key is present on the host.
B3/B4 (UI eyeball) + B6 (resume) + B7-auth-ban remain to click through.

---

## grd (NOT go-live for multi-user/fleet)

grd's headless GNOME session is host-proven (single + multi-user) via `grd-headless-spike.sh`,
but as shipped `run.sh.grd` passes only `RDP_PW/GUAC_PW/RFB_PW/TS_AUTHKEY`, never joins the
tailnet (`entrypoint-grd.sh` has no `tailscale up`), and has no spin-up wizard — so grd is
**core-only, no fleet tiles**, and **has never been CI-built**. Ship **xrdp** for production;
grd's fleet/multi-user deploy gaps are a separate follow-up.
