# Process — bootstrap the grd headless-paint spike on a host and validate

This is **operator/host work**, not build-box work. The fedora-dev claudebox *wrote*
`grd-headless-spike.sh` but cannot run it: the grd lineage is systemd-PID-1 and only a
**cgroup-v2-delegating host** can boot it. Execute this on the host claudebox
(`fedora-bootstrap`), the VPS, or any matching scratch host. Five phases.

---

## Phase 0 — Pick the validation host (match production)

The spike is only meaningful if the host reproduces production conditions. Use a
**headless, no-GPU, cgroup-v2** Linux host — the VPS itself, the `fedora-bootstrap`
host, or a throwaway Fedora-44 VM. The spike already passes **no `/dev/dri`**, so even
if the host *has* a GPU you still get the no-GPU result — but a host with a real login
seat can mask the seatless failure, so prefer a genuinely headless host.

Pre-flight (want `v2` + `crun` + `cgroup2fs`):

```sh
podman info --format 'cgroup={{.Host.CgroupVersion}} runtime={{.Host.OCIRuntime.Name}}'
stat -fc %T /sys/fs/cgroup        # expect: cgroup2fs
```

If running podman **rootless**, the user slice must delegate controllers (rootful needs
nothing). One-time, as root, then re-login:

```sh
mkdir -p /etc/systemd/system/user@.service.d
printf '[Service]\nDelegate=cpu cpuset io memory pids\n' \
  > /etc/systemd/system/user@.service.d/delegate.conf
systemctl daemon-reload
```

The real delegation test is **Gate A** of the spike itself — if systemd reaches
`running`/`degraded` inside the container, delegation is fine.

---

## Phase 1 — Get the spike onto the host

The script lives on branch `validation/grd-headless-spike` of `oso-gato/fedora-desktop`.
Pick one:

- **A — via merge (cleanest):** the build box opens the PR → maintainer merges → on the host:
  ```sh
  git clone https://github.com/oso-gato/fedora-desktop && cd fedora-desktop
  ```
- **B — pre-merge, fetch the branch directly** (once the branch is pushed):
  ```sh
  git clone -b validation/grd-headless-spike https://github.com/oso-gato/fedora-desktop
  cd fedora-desktop
  ```
- **C — copy the one file** (no clone needed): scp/paste `validation/grd-headless-spike.sh`
  to the host and `chmod +x` it. It is self-contained.

> The build box can `gh pr create` to make the branch fetchable (it is PR-only — it
> opens, a maintainer merges). Until then, route B/C.

---

## Phase 2 — Install the optional paint-check tools

Gates A–C/E run with just podman. **Gate D** (the actual "it paints + SSO" proof) needs
a freerdp client + a virtual X server + ImageMagick. On a Fedora host:

```sh
sudo dnf install -y freerdp xorg-x11-server-Xvfb ImageMagick
# freerdp provides xfreerdp / xfreerdp3 / sdl-freerdp — the spike auto-detects which.
```

Skip this and the spike still runs A–C/E and prints a manual `xfreerdp` command to
eyeball the desktop instead.

---

## Phase 3 — Run it

```sh
cd fedora-desktop
./validation/grd-headless-spike.sh          # builds the image (~few min), runs BOTH builds
```

Useful knobs:

```sh
VARIANTS=2 ./validation/grd-headless-spike.sh                 # GDM-free build only
VARIANTS=1 ./validation/grd-headless-spike.sh                 # GNOME-50 gnome-headless-session@ only
VARIANTS=2 KEEP=1 ./validation/grd-headless-spike.sh          # leave the container up to poke at
GNOME_SHELL_HEADLESS='/usr/bin/gnome-shell --headless --wayland --mode=user' \
  VARIANTS=2 ./validation/grd-headless-spike.sh               # tune the (unproven) headless invocation
```

---

## Phase 4 — Read the result

The script prints a PASS/FAIL table and writes per-variant diagnostics to
`./grd-spike-out/v{1,2}/`:

- **Gate D = PASS** (and a non-black `grd-spike-out/v*/frame.png`) → **the shared
  primitive WORKS** for that build. The grd lineage is buildable; proceed to wire that
  variant in. The build box then adds the next layer (out of the spike's scope): the
  Guacamole `:8443` hop with the RDP tile set to **`security=any` (not `tls`)** — GRD's
  front door is NLA-only — then TOTP, per-user ports for multi-user, and resume.
- **Gate D = FAIL for both** → the dominant shared risk is real in this shape. Do **not**
  invest in the grd session rewrite yet. The diagnostics localise it:
  | symptom (in `grd-spike-out/v*/`) | likely cause | next lever |
  |---|---|---|
  | variant 1: `container.log`/journal shows `CanGraphical … seat0` | gdm won't start seatless | drop to variant 2 (GDM-free) |
  | variant 2: `grd-headless-session.service` not active | gnome-shell `--headless` invocation | tune `GNOME_SHELL_HEADLESS=` |
  | Gate B fail: `no GPUs found` / `failed to create EGL` | mutter can't get surfaceless EGL with no `/dev/dri` | add a virtual render node (vgem/vkms) — a control-plane device decision |
  | Gate C fail: nothing on `:3389` | GRD daemon didn't attach to the session | check `journal.txt` for `org.gnome.Mutter.RemoteDesktop` |
  | Gate D fail but C pass: `freerdp.log` shows `wrong security type` | NLA/security mismatch | confirm client `/sec:nla`; this is the same class as the Guacamole `security=tls` bug |

---

## Phase 5 — Feed the result back to the build box

Hand back: the **PASS/FAIL table**, the winning variant (if any), `frame.png`, and the
`grd-spike-out/v*/{journal,ss,grdctl-status,freerdp}.txt` for any failing gate. With
that, the build box targets the grd session-rewrite at the **proven** variant (no blind
bet), or iterates on the localised blocker (e.g. the render-node decision) before
committing code.

---

### Optional one-shot bootstrap (Fedora host, rootful podman)

```sh
sudo dnf install -y podman git freerdp xorg-x11-server-Xvfb ImageMagick
git clone -b validation/grd-headless-spike https://github.com/oso-gato/fedora-desktop
cd fedora-desktop && ./validation/grd-headless-spike.sh
```

### Boundary

Per policy this is the **host claudebox / operator's** job, not the build box's. The
build box surfaces the tool + this process; the human routes the run and returns the
result. The spike never bind-mounts `$HOME`/the vault; its container + scratch volume
are torn down on exit.
