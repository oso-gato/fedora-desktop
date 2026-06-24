# validation/ — host-run spikes (NOT part of the image)

These scripts are **host-validation experiments**, not baked into any fedora-desktop
image and not run by CI or any entrypoint. They exist because the grd lineage is
systemd-PID-1 and **cannot boot in the nested build engine** — the only way to prove
its runtime behaviour is on a cgroup-v2-delegating host.

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
