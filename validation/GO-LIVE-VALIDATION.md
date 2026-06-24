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

---

## B — real-deploy validation (the go-live gate)

Deploy on the **production-class host on the tailnet**, with the **dev box and host actually up
on the tailnet** and the fleet SSH path in place. Throwaway containers can't do this.

### B0 — preconditions (must be true first)
- The deploy host can run the image; for grd only, it needs cgroup-v2 delegation (xrdp doesn't).
- The **fleet hosts** (`fedora-dev`, the VPS/`erebus`) are **up, on the tailnet, sshd reachable**, and accept this node — either via **Tailscale-SSH ACL** (keyless) **or** the **`FLEET_SSH_KEY`** public half is in their `authorized_keys`.
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
- **Keyless Tailscale-SSH through guacd is UNVALIDATED** (libssh2 `none`-auth, per `ZTNA-ACCESS.md`) → if a tile prompts for a password, supply `FLEET_SSH_KEY` (the safe default).
- **No healthcheck probes a fleet tile** → a down/unauthorized bastion is invisible to health/rollback; B2-gate-5 is a **manual** click-probe.
- **TOTP enrollments live in the `/var/lib/mysql` volume** → losing it wipes all 2FA; do a backup/restore drill before go-live.
- **A `dev`/`host` grant = a `core`-admin shell** on that fleet box over keyless Tailscale-SSH (per CLAUDE.md) — confirm that's intended for the users you grant it to.

---

## grd (NOT go-live for multi-user/fleet)

grd's headless GNOME session is host-proven (single + multi-user) via `grd-headless-spike.sh`,
but as shipped `run.sh.grd` passes only `RDP_PW/GUAC_PW/RFB_PW/TS_AUTHKEY`, never joins the
tailnet (`entrypoint-grd.sh` has no `tailscale up`), and has no spin-up wizard — so grd is
**core-only, no fleet tiles**, and **has never been CI-built**. Ship **xrdp** for production;
grd's fleet/multi-user deploy gaps are a separate follow-up.
