# validation/ — host-run spikes + go-live runbooks (NOT part of the image)

The scripts here are **host-validation experiments** and the `.md`s are **operator
runbooks** — none are baked into any fedora-desktop image or run by CI or any
entrypoint. They exist because the decisive behaviours (systemd-PID-1 boot, multi-user
paint, per-user volume ownership, fleet tiles) can only be proven on a real host — the
grd lineage cannot even boot in the nested build engine.

## Index

- **`grd-headless-spike.sh`** — the grd session primitive: does a headless GNOME-50 session
  paint behind loopback RDP in a seatless/no-GPU/systemd-PID-1 container, with SSO + resume?
  (Detailed below.)
- **`xrdp-headless-spike.sh`** — the xrdp multi-user primitive: N distinct users → ONE `:3389` →
  N distinct painted per-user Xorg `:1x` sessions, on the production xorgxrdp/Xorg backend
  (fails a run that silently falls back to Xvnc). Plain `podman run` — no cgroup delegation needed.
- **`user-volumes-spike.sh`** — per-user volume ownership (pinned uid `1000+n`/gid `8000+n`,
  `0700` isolation) + the optional `2770 root:deskshare` shared folder with default-ACL
  read-write collaboration.
- **`guac-fleet-provision-spike.sh`** — runs the REAL `bin/guac-db-provision.sh` against a
  throwaway MariaDB + the real Guacamole schema: tile/grant matrix, downgrade-revokes,
  exact-whole-token (fail-closed) grant matching.
- **`GO-LIVE-VALIDATION.md`** — the xrdp go-live runbook — **GREEN end-to-end (erebus,
  2026-06-25)**; the production proof of record.
- **`GO-LIVE-VALIDATION-grd.md`** — the grd go-live runbook (mirrors xrdp's B-gates;
  full-lineage deploy validation still pending).
- **`HOST-VALIDATION-PROCESS.md`** — the operator/host process for running the grd spike on a
  cgroup-v2-delegating host and feeding the result back to the build box.

## grd-headless-spike.sh

Answers the single question that gates **every** grd SSO build, before any code is
written for it:

> Does a headless GNOME-50 session actually **paint** behind a loopback RDP port in a
> seatless, no-GPU, rootless, systemd-PID-1 container — and does one RDP credential
> land on it (SSO)?

Per the analysis, ~60–70% of the failure probability for both candidate builds (GDM
`gnome-headless-session@` vs GDM-free `gnome-shell --headless`) is this **shared**
primitive. The GDM-vs-GDM-free choice is a secondary completeness tweak you make
*after* this passes — so run this first and don't invest in the session rewrite until
Gate D is green.

### Run it (on the delegating host)

```sh
# minimal — runs both builds, prints a PASS/FAIL table, leaves diagnostics in ./grd-spike-out/
./validation/grd-headless-spike.sh

# just the GDM-free build, keep the container up to poke at it:
VARIANTS=2 KEEP=1 ./validation/grd-headless-spike.sh

# tune the (unproven) headless gnome-shell invocation while iterating variant 2:
GNOME_SHELL_HEADLESS='/usr/bin/gnome-shell --headless --wayland --mode=user' \
  VARIANTS=2 ./validation/grd-headless-spike.sh
```

**Host prereqs:** `podman` (with cgroup-v2 delegation). For the automated paint check
(Gate D) also: a freerdp client (`xfreerdp`/`xfreerdp3`/`sdl-freerdp`), `Xvfb`, and
ImageMagick (`import`/`convert`). Without them, Gates A–C/E still run and the script
prints a manual `xfreerdp` command to eyeball the desktop.

### Gates

| Gate | Proves |
|---|---|
| A | systemd-PID-1 comes up in the container |
| B | a headless GNOME session exists + mutter paints surfaceless on llvmpipe (no `/dev/dri`) |
| C | the GRD `--headless` daemon binds loopback `:3389` |
| **D** | **a real RDP client completes the NLA handshake and renders a NON-BLACK frame** — the actual paint+SSO proof (`grd-spike-out/v*/frame.png`) |
| E | reconnect resumes the same session (persistence) |

### After it passes

Gate D green → wire the winning build into the grd lineage, then add the *next* layer
(out of scope here): the Guacamole `:8443` hop — its RDP tile must use **`security=any`,
not `tls`** (GRD's front door is NLA-only) — then TOTP, per-user ports for multi-user,
and cross-device resume from a different geometry.

### Scope / safety

- Never bind-mounts `$HOME` or the vault; all state is a scratch named volume, removed
  on exit. The test RDP port is published on `127.0.0.1` only.
- This proves the **primitive**, not the full product: it does not test Guacamole,
  TOTP, multi-user, or the security-mode fix — those are follow-ons once paint works.
