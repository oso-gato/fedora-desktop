# fedora-desktop

## TL;DR — in plain words

A cloud Linux **desktop where Claude helps you run your "second brain"** (your Obsidian
vault + an LLM wiki) — capable enough to build and update *its own* code, but fenced so it
can't reach out and disturb your wider setup.

It's the **fedora-dev harness** (a self-refreshing Claude Code box: nested rootless podman,
key-only SSH, fail2ban, Tailscale, a daily-rebuilt "claudebox") with an **XFCE desktop**
layered on (recipe lifted from **fedora-xrdp**). Claude Code refreshes itself *daily*,
independent of the heavier desktop. The vault/wiki are governed by their *own* rules —
Claude is the writer, you are the director.

- 🌐 **How you get in (public, from anywhere):** the **web desktop** — your whole desktop in
  a browser tab over HTTPS. It is the one *hardened* public door: real TLS, web login,
  brute-force-protected, patched. Plus **key-only SSH + Mosh** for a terminal.
- 🖥️ **How you get in (private, Tailscale only):** native **RDP** (the nicest experience) and
  **VNC**, plus password logins for SSH — all **deliberately kept off the open internet.**
  RDP is the #1 ransomware door, so it's one Tailscale tap away instead of public.
- 📝 **What it does:** a full desktop with **Obsidian** (notes), **VS Code** (code),
  **Firefox**, **1Password** (credentials), and **Claude Code** (the AI, auto-updated daily).
- ✋ **How changes ship — the workflow:** Claude can rebuild *itself*, but it tests the new
  version in its own walls and **self-deploys only after you click OK.** For every *other*
  repo it only **opens a PR** — it never pushes their `main`. A workshop that can't wander
  out and rearrange the house.
- 🗄️ **Your vault & wiki:** Claude is the live-in librarian — it writes and maintains, **you
  direct and approve** — under the vault's own governing schema. Notes sync live via Obsidian
  Sync + auto-back-up to a private GitHub mirror.
- 🔒 **The honest security story:** the box's GitHub key is least-privilege (limits damage if
  it leaks) but does **not** lock your notes — your vault is plain files anything in the box
  can read. The real protection is that the **risky step — chewing on untrusted web content —
  runs in a throwaway sandbox with no keys, no vault, and no internet.**

## Purpose

`fedora-desktop` is Arthur's **personal remote workstation** — one desktop, two functions:

- **Knowledge work (primary)** — operate and maintain the LLM wiki + Obsidian vault
  (`bear-alchemist/2nd-brain`). Arthur is the **maintainer and director**; the box is the
  **writer of the wiki** and of vault content **on request**, under his direction and the
  vault's own governing schema.
- **Maintainer dev** — develop and maintain the whole oso-gato fleet's source. **Push scope
  is bounded:** the box pushes only its **own** repo's `main` (its self-deploy path); for
  every other repo it **opens a PR** that Arthur or the host claudebox merges.

It is the **fedora-dev harness extended**, not a fork — the nested-podman + sshd/fail2ban +
tailscale + daily-claudebox machinery is lifted verbatim and the XFCE remote desktop
(fedora-xrdp recipe) is layered on top.

```
self-develop → self-validate in the OWN nested engine → clickable approval → push fedora-desktop main
            → CI builds + cosign-signs → ghcr.io/oso-gato/fedora-desktop:latest → host pull-refresh recreates the box
```

For **any other repo**, the box stops at "open a PR" — it never deploys or operates a
container on any host.

## Headless (binding prerequisite)

Every fedora-desktop image runs **fully headless** — no monitor, GPU, or local login seat is
ever needed for it to work. The desktop is a *virtual* display rendered in software (llvmpipe):
the **xrdp** lineage via `xorgxrdp`'s headless Xorg server, the **grd** lineage via
`mutter --headless` / GRD's headless session. This holds for every desktop environment and
every lineage (incl. any future variant); a variant that
requires a physical display is a defect, not an option.

## Build Principles (binding)

Every code change in this repo obeys these. Full agent-facing detail (with the example
metapackage traps) lives in [CLAUDE.md](CLAUDE.md).

| # | Principle | Rule |
|---|---|---|
| 1 | BASE | Build only from `registry.fedoraproject.org/fedora:${FEDORA_VERSION}`. Version is a Containerfile `ARG`, never inlined. |
| 2 | SOURCES | Every package from exactly one official source: (a) Fedora's own repos via dnf; (b) the vendor's/developer's own RPM or dnf repo (`.repo`, `gpgcheck=1`); (c) at worst a developer/vendor-released AppImage (sha256 logged). NEVER COPR, pip/npm/cargo/gem/brew global, curl-pipe-sh, tarball-on-PATH, flatpak, snap. Applies to BOTH the base image AND the claudebox `additional_packages`. **Current waivers: none.** |
| 3 | MINIMAL | dnf with `--setopt=install_weak_deps=False`; install the **leaf** package, never a convenience metapackage (weak-dep blocking does NOT stop a metapackage's hard Requires — e.g. `fail2ban` hard-pulls firewalld + esmtp; we install `fail2ban-server`). Every package gets a justifying row in the Packages table; a package without a row is a violation. |
| 4 | VERIFY FIRST | Before adopting/bumping any source or pin, fact-check it against the live source. Gate risky installs in a scratch container before editing build files. |
| 5 | NO SECRETS / NO IDENTITY | No passwords, keys, or personal usernames in any layer, file, or commit. User is the generic `core` (uid 1000). `RDP_PW` / `GUAC_PW` (required) + `RFB_PW` / `TS_AUTHKEY` (optional) enter ONLY at runtime; the entrypoint fails fast when a required one is missing. |
| 6 | PINS | Vendor/Apache artifact versions are Containerfile `ARG`s (`GUAC_VERSION`, `JEEMIG_VERSION`, `RCLONE_VERSION`) or pinned in `distrobox.ini`; bump there only, after a rule-4 check. (Obsidian is intentionally latest-at-build, sha256-logged.) |
| 7 | DEPLOY CONTRACT | `run.sh` is the only sanctioned way to run the image: it carries the runtime `--health-cmd` (OCI drops the Containerfile HEALTHCHECK), devices, volumes, restart policy, and the **port-publish set**. The Quadlet `fedora-desktop.container` is the systemd-managed equivalent. Sensitive ports (RDP/VNC + password-auth) stay tailnet-only — never `-p`. |
| 8 | CI + LAYERED CADENCE | `.github/workflows/build.yml` builds → cosign-signs → pushes the base image to GHCR on push to `main`, on the 15th monthly (`--no-cache`), and on dispatch; PRs build-validate only. A **control-plane diff-guard** fails any PR touching guardrail files without an explicit waiver label. The in-container claudebox refreshes claude-code DAILY on its own timer; it never touches CI. |
| 9 | VALIDATE | After any change: build, deploy via `run.sh`, confirm `(healthy)`, functional-probe each access path (web/RDP/VNC/ssh + sync). Final proof is CI green + a host-side deploy. |
| 10 | PROMOTION GATE | The box pushes only `fedora-desktop` `main`, and only after a clickable approval; control-plane/guardrail changes are standalone, never bundled, and approval-gated. Other repos: PR only. Enforced mechanically by the managed PreToolUse hook (`policy/hooks/gate-push.sh`) + managed-settings + the CI diff-guard. |

## Packages

Everything installed, with a justifying row each (Build Principle 3). **Tier** = what role it
plays; **Src** = the rule-2 source class. claude-code is **deliberately NOT here** — it lives
in the claudebox (`distrobox.ini` `additional_packages`, daily-refreshed); see *Box Packages*
in [CLAUDE.md](CLAUDE.md). `onedrive` (abraunegg daemon) is **deliberately NOT installed** —
cloud is rclone-only.

### Base image (`install.sh`, refreshed monthly by CI)

| Package | Tier | Src | Why required |
|---|---|---|---|
| podman | harness | a | the container ENGINE — the claudebox runs on it; the in-box agent's `podman build` lands here via `CONTAINER_HOST` |
| shadow-utils | harness | a | `newuidmap`/`newgidmap` setuid helpers — mandatory for nested rootless podman |
| fuse-overlayfs | harness | a | nested rootless storage driver (kernel forbids native overlay-on-overlay) |
| passt | harness | a | pasta — podman 5's default rootless network backend |
| nftables | harness | a | firewall backend: tailscaled programs rules via the nftables Netlink API, netavark defaults to nftables on Fedora 41+, fail2ban bans via `nftables[type=multiport]`. (No iptables — verified unnecessary.) |
| openssh-server | harness | a | the login door (key-only; keys synced from `github.com/oso-gato.keys` each start). Public ssh on host :4444 → :22 AND keyless Tailscale SSH on the tailnet; mosh bootstraps over either |
| mosh | harness | a | roaming-resilient remote shell (UDP, AEAD-authenticated). Public UDP range 61001-62000 (non-default, to avoid colliding with the bootstrap host's own mosh) |
| tmux | harness | a | session multiplexer; every interactive login auto-attaches `main`; survives disconnects/restarts |
| distrobox | harness | a | declaratively bootstraps the in-container claudebox via `distrobox assemble create --file distrobox.ini` |
| inotify-tools | harness | a | `inotifywait` watches the in-box `rebuild.request` flag (no systemd `.path` units — no systemd inside, by design) |
| fail2ban-server | harness | a | brute-force mitigation on public :4444; bans via `nftables[type=multiport]`; tailnet CGNAT 100.64.0.0/10 is `ignoreip`'d. The **leaf** package (the `fail2ban` metapackage hard-pulls firewalld + esmtp — see Principle 3) |
| rsyslog | harness | a | captures sshd's AUTHPRIV to `/var/log/secure` so fail2ban can read it (no journald in this container) |
| sudo | harness | a | break-glass escalation (`core` in `wheel`); near-zero footprint (host-side `podman exec -u 0` is the real recovery door) |
| procps-ng | harness | a | `pgrep` for the entrypoint watchdog AND the `--health-cmd` |
| glibc-langpack-en | harness | a | UTF-8 rendering for tmux/terminal |
| nano | harness | a | one break-glass editor (Fedora's minimal base doesn't ship `vi` reliably) |
| tailscale | remote-access | b | tailnet node + keyless Tailscale SSH (primary maintenance path); RDP/VNC/password-auth are reachable ONLY over the tailnet IP it provides. Official Tailscale dnf repo |
| xrdp | desktop | a | the RDP server (:3389, **tailnet-only**). Pulls `tigervnc-x11-server` as a hard dep — which powers the optional VNC mirror |
| xorgxrdp | desktop | a | the Xorg backend modules xrdp drives (the X session xrdp/guacd/x0vncserver all attach to) |
| openh264 | desktop | a | H.264 encoder for xrdp's GFX pipeline (the `gfx.toml` H.264-first tuning) — efficient remote-desktop video |
| guacd | remote-access | a | Apache Guacamole proxy daemon (loopback `-b 127.0.0.1`); translates the browser's protocol to local RDP |
| libguac-client-rdp | remote-access | a | guacd's RDP client plugin — the web door connects to the local RDP session through this |
| tomcat | remote-access | a | servlet container that serves the Guacamole webapp on the TLS :8443 public door |
| xfce4-session | desktop | a | the XFCE session manager (`startxfce4` entry point for the X session) |
| xfwm4 | desktop | a | XFCE window manager |
| xfce4-panel | desktop | a | XFCE panel (taskbar / launchers) |
| xfdesktop | desktop | a | XFCE desktop background + icons |
| xfce4-terminal | desktop | a | terminal emulator inside the desktop — where the operator runs `claude` |
| Thunar | desktop | a | XFCE file manager (browsing the vault / cloud-mount folders) |
| dbus-x11 | desktop | a | `dbus-launch` / session bus for the X session (Electron apps + gnome-keyring need it) |
| xorg-x11-xauth | desktop | a | X authority cookie management for the xrdp-spawned X session |
| xdpyinfo | desktop | a | X display probe used by session-startup scripting / health checks |
| xterm | desktop | a | fallback terminal guaranteeing a usable X client if XFCE's own fails to start |
| mesa-dri-drivers | desktop | a | software/GL rendering for the headless X server (no GPU in the container) |
| mesa-libgbm | desktop | a | GBM buffer management Electron/Chromium graphics expect |
| dejavu-sans-fonts | desktop | a | base UI font (otherwise tofu in apps + terminal) |
| google-noto-sans-fonts | desktop | a | wide Unicode coverage for vault/wiki content rendering |
| adwaita-icon-theme | desktop | a | GTK icon theme so app menus/toolbars aren't blank |
| nss | apps | a | Electron/Chromium (Obsidian, VS Code, 1Password) TLS/crypto runtime dep |
| atk | apps | a | accessibility toolkit — GTK/Electron hard runtime dep |
| at-spi2-atk | apps | a | ATK↔AT-SPI bridge — GTK3/Electron runtime dep |
| cups-libs | apps | a | printing client libs GTK/Electron link against (apps fail to start without) |
| gtk3 | apps | a | GTK3 runtime for Firefox + Electron apps |
| alsa-lib | apps | a | audio runtime (Electron + RDP/Guacamole audio path) |
| libnotify | apps | a | desktop notifications used by Obsidian / VS Code / 1Password |
| libsecret | apps | a | Secret Service client — VS Code / apps store tokens via it (backed by gnome-keyring) |
| xdg-utils | apps | a | `xdg-open` etc. — `obsidian://` scheme handling + opening links from apps |
| gnome-keyring | apps | a | Secret Service provider (the keyring backing libsecret for app credential storage) |
| openssl | remote-access | a | `keytool`/PKCS12 plumbing context for minting the Guacamole TLS keystore at runtime |
| firefox | apps | a | the in-desktop browser — authorizes rclone OAuth, reaches claude.ai, web login flows |
| code | apps | b | VS Code — the maintainer-dev editor. Official Microsoft yum repo (`gpgcheck=1`) |
| 1password | apps | b | 1Password GUI — credential vault. Official 1Password dnf repo (`gpgcheck=1`, `repo_gpgcheck=1`) |
| 1password-cli | apps | b | 1Password CLI (`op`) — scripted secret retrieval. Same 1Password repo |
| rclone | sync | c | the ONLY cloud-sync engine (NON-vault Google Drive + OneDrive; mount + delete-guarded bisync). Pinned developer rpm `RCLONE_VERSION` (no abraunegg `onedrive` daemon) |
| Obsidian | apps | c | the vault editor — primary knowledge-work interface. Developer AppImage, latest-at-build, sha256 logged → `/opt/obsidian` + a `.desktop` (no rpm exists) |
| guacamole.war | remote-access | c | the Guacamole webapp on :8443. Official Apache `.war` pinned by `GUAC_VERSION`, GPG-verified against the pinned Apache key (`GUAC_GPG_FP`), converted javax→jakarta with Apache's `jakartaee-migration` (Fedora ships only Tomcat 10.1). No rpm exists |
| guacamole-auth-ban | remote-access | c | brute-force lockout on the PUBLIC :8443 door — a second Apache Guacamole `.jar` extension (same `GUAC_VERSION`, same pinned key `GUAC_GPG_FP`, same fetch+GPG-verify+extract pattern) dropped into `/etc/guacamole/extensions/`. What makes a single strong `GUAC_PW` a defensible public door (a password with no lockout is brute-forceable). No rpm exists |
| guacamole-auth-jdbc | remote-access | c | the MySQL JDBC auth backend — moves the public door to MariaDB so TOTP 2FA can store enrollment seeds. Third Apache `.jar` extension (same key/pattern). Only the `mysql/` jar is installed + only `001-create-schema.sql` is stashed; the `002` guacadmin backdoor is never shipped/loaded. No rpm exists |
| guacamole-auth-totp | remote-access | c | TOTP / Google-Authenticator 2FA on the public door (QR at first login, seed in the DB). Fourth Apache `.jar` extension (same key/pattern). No rpm exists |
| mariadb-server / mariadb / mariadb-java-client | remote-access | a | the DB the public door authenticates against (TOTP needs a DB), its client, and the JDBC driver Guacamole loads from `/etc/guacamole/lib`. Fedora **leaf** packages; the DB binds **127.0.0.1 only** (3306 never published) and runs under the supervised-bash watchdog (xrdp) or as `mariadb.service` (grd) |
| jakartaee-migration | (build tool) | c | Apache's own converter (pinned `JEEMIG_VERSION`) used at build time to make `guacamole.war` Tomcat-10-compatible; not installed into the image |

### Box packages

Inside the claudebox (`distrobox.ini` `additional_packages`), refreshed daily — the full
table with per-package justification is in [CLAUDE.md](CLAUDE.md). Summary:
`claude-code` (Anthropic `latest`-channel dnf repo, b), `git`, `gh` (GitHub repo, b),
`openssh-clients`, `podman` (client), `bubblewrap`, `socat`, `host-spawn`, `rclone`.

## Deploy

Two paths, same image. The deploy contract carries the health-cmd, devices, volumes, restart
policy, and — critically — the **port-publish set** (Principle 7). Never hand-roll `podman run`.

### DEPLOY CONTRACT — the host claudebox MUST ASK the operator at spin-up

fedora-desktop is **operator-parameterised** and is **NOT auto-deployed on day-0**. When the
maintainer asks the host (`fedora-bootstrap`) claudebox to spin up fedora-desktop, the host
claudebox **MUST ask the operator for** the following (never hardcode, never invent), then deploy
with them via `run.sh` / the Quadlet:

1. **Lineage + variant** — `xrdp` (proven; `DESKTOP_ENV` ∈ `xfce`/`mate`/`lxqt`/`kde`) is the
   deployable default; `grd` is **EXPERIMENTAL** (Wayland headless host-validation pending).
   (`krdp` was REMOVED — KRdp has no headless mode, the wrong tool for a headless RDP door.)
   CI publishes every variant to GHCR — pull the tag you want:
   `:xfce` (= `:latest`) · `:mate` · `:lxqt` · `:kde` (xrdp lineage) · `:grd`
   (plus `:<tag>-<date>` / `:<tag>-<sha>` immutable tags). The grd image builds + signs, but
   its *runtime* (booting the Wayland session) is host-validation-pending — a green build ≠ boots.
2. **`WEB_PORT`** — the public web-door host port (**default 8443**; the only public port). The
   web gateway is **Apache Guacamole only** (no selector — noVNC was removed fleet-wide; a public,
   non-tailnet door demands strong auth and noVNC's 8-char VncAuth is unacceptable there).
3. **Secrets, per door** — `./spin-up.sh` offers to **generate a diceware passphrase** (6 EFF words
   ≈ 77 bits, wallet-seed style, shown once to save) for each, or accepts your own with a **≥20-char
   floor**. The public door is further backed by `guacamole-auth-ban` tightened to **3 attempts → 15-min
   IP ban**:
   - **`RDP_PW`** — **strong** (`core`'s system/RDP password; the RDP door + the web SSO).
   - **`GUAC_PW`** — **strong** (the public web login; the Guacamole gateway is the only public
     door, hardened by the `guacamole-auth-ban` brute-force lockout **and TOTP 2FA**). Note: 2FA is
     **additive** — keep the password strong anyway. TOTP is phishable (a real-time relay captures
     password + live code together) and its seed lives in the same DB, so the password remains an
     independent barrier; 2FA does NOT license a weak password.
   - `RFB_PW` (optional) — arms the **tailnet-only** `:5900` native-VNC mirror (not a gateway choice).
4. **Additional users (optional)** — how many ADDITIONAL desktop users beyond `core` (**0 to 5**)?
   `core` is always the admin (full dev). For each extra user ask: a **username** (lowercase
   `^[a-z_][a-z0-9_-]{0,30}$`, not `core`/`root`), a **strong password**, and a **fleet-access grant**
   — **`none`** (Desktop only) / **`dev`** / **`host`** / **`both`** — passed as
   `USER{n}_NAME` / `USER{n}_PW` / `USER{n}_ACCESS`. Each user gets their OWN Guacamole web login that
   SSOs into their OWN desktop session + only the fleet tiles their grant allows, and their OWN persisted
   `/home` volume (`fedora-desktop-userN`). A user with `none` is a non-privileged "wiki worker" (desktop +
   Obsidian/vault, no dev); a grant of `dev`/`host`/`both` adds the matching bastion tile(s) — note that is
   **bastion reach as `core`** on that box (an admin-level grant; see CLAUDE.md MULTI-USER). **0 extra
   users = today's single-`core` behavior, byte-identical.** Each user's session persists + resumes across
   devices. **The interactive `./spin-up.sh` wizard asks all of this for you** (count, then per-user
   name/password/access) and calls `run.sh`.

### Access model (public surface = the web port only)

| Door | Exposure | Reach |
|---|---|---|
| **web** | **PUBLIC** (the only public port) | `https://<public-ip>:${WEB_PORT}/` (TLS; `WEB_PORT` default 8443) |
| **ssh** | **tailnet-only** | `ssh core@<tailnet-ip>` (Tailscale SSH, keyless) or ssh-key over the tailnet |
| **mosh** | **tailnet-only** | over the tailnet ssh |
| **RDP** | **tailnet-only** | `<tailnet-ip>:3389` (mstsc / Windows App; `RDP_PW`) |
| **VNC** | **tailnet-only** | `<tailnet-ip>:5900` (only if `RFB_PW` set) |

ssh/mosh/RDP/VNC are never published **and** are dropped on non-`lo`/non-`tailscale0` interfaces by
the in-container `nft` guard — tailnet-only by *construction*, so a future `-p` slip can't expose them.

### Runtime secrets (Principle 5 — never in a layer)

| Var | Required | What it is |
|---|---|---|
| `RDP_PW` | **yes** | `core`'s system/RDP password. The entrypoint `chpasswd`'s it and Guacamole single-signs-on into the local RDP session with it |
| `GUAC_PW` | **yes** | the public Guacamole web-login password (user `core` at `https://<host>:8443/guacamole/`). Use a STRONG one — `guacamole-auth-ban` adds brute-force lockout AND **TOTP 2FA** is enforced (enroll a QR at first login). 2FA is additive defense-in-depth, NOT a license for a weak password (TOTP is phishable + its seed is in the same DB) |
| `RFB_PW` | no | **OPTIONAL** — arms the same-session native-VNC mirror on :5900 (tailnet-only; VncAuth — only first 8 chars effective). Not a gateway choice |
| `TS_AUTHKEY` | no | unattended tailnet join (else the join is interactive — open the printed login URL once) |
| `USER{1..5}_NAME` / `_PW` / `_ACCESS` | no | **OPTIONAL** — up to **5** additional desktop users (each: username + strong password + fleet-access `none`/`dev`/`host`/`both`). `core` stays admin; each user gets their OWN web login → their OWN desktop session + only the fleet tiles their grant allows + their OWN persisted `/home` volume (`fedora-desktop-userN`). A `dev`/`host` grant = bastion reach **as `core`** on that box. `./spin-up.sh` prompts for these. See CLAUDE.md MULTI-USER |

The entrypoint **fails fast** if `RDP_PW` or `GUAC_PW` is unset.

### Access model (load-bearing — do NOT widen the publish set)

| Path | Port | Exposure | Auth |
|---|---|---|---|
| 🌐 Guacamole web (TLS) | 8443/tcp | **PUBLIC** — the only public desktop door | web login `core` / `GUAC_PW` → SSO into local RDP |
| 🔑 SSH | host 4444 → :22 | **PUBLIC** | key-only (keys from `github.com/oso-gato.keys`); fail2ban-guarded |
| 📡 Mosh | 61001-62000/udp | **PUBLIC** | rides over the key-auth ssh |
| 🪪 Tailscale SSH | tailnet :22 | tailnet | keyless (Tailscale identity) — primary maintenance path |
| 🖥️ RDP | 3389/tcp | **TAILNET-ONLY (never `-p`)** | `core` / `RDP_PW` (native clients: mstsc, Windows App) |
| 🖲️ VNC | 5900/tcp | **TAILNET-ONLY (never `-p`)** | `RFB_PW` (only if set) — mirrors the RDP session |

Password-auth (RDP/VNC/Guacamole) therefore never crosses the public internet except inside
the TLS-terminated Guacamole door. **`run.sh` and the Quadlet publish ONLY `8443`, `4444:22`,
and `61001-62000/udp`** — `3389` and `5900` are reachable only over the tailnet.

### run.sh (interactive / non-systemd hosts)

```sh
RDP_PW='…' GUAC_PW='…' [RFB_PW='…'] [TS_AUTHKEY=tskey-…] [IMAGE=…] ./run.sh
```

Health = `curl -sk https://127.0.0.1:8443/guacamole/` returns 200 (proves Tomcat + guacd +
the webapp all serve). Volumes: `fedora-desktop-home:/home/core`,
`fedora-desktop-state:/var/lib/tailscale`, `fedora-desktop-cert:/var/lib/guac-cert`. Runtime
flags: `--shm-size=1g`, `--cap-add NET_ADMIN SYS_ADMIN`, `--device /dev/net/tun /dev/fuse`,
`--security-opt label=disable`, `--restart=always`.

### Quadlet (preferred — systemd-managed)

```sh
mkdir -p ~/.config/containers/systemd
cp fedora-desktop.container ~/.config/containers/systemd/
# provide RDP_PW + GUAC_PW (+ optional RFB_PW/TS_AUTHKEY) as podman secrets and
# uncomment the matching Secret= lines, OR an operator-managed EnvironmentFile.
systemctl --user daemon-reload
systemctl --user enable --now fedora-desktop.service
```

`Pull=missing` (the host workload-refresh harness is the sole puller — it pulls + digest-
compares before restart, enabling its auto-rollback). `Notify=healthy`, `AutoUpdate=registry`,
`SecurityLabelDisable=true`, the three volumes, and the same publish set as `run.sh`.

### First boot

Takes ~2-5 minutes. The entrypoint seeds `core`'s password from `RDP_PW`, syncs ssh keys from
`github.com/oso-gato.keys`, mints the Guacamole TLS keystore, brings up the loopback MariaDB
engine + provisions DB-backed web auth (each web login + its desktop/fleet tiles), starts
rsyslog + sshd + fail2ban + tailscaled + xrdp + mariadbd + guacd + Tomcat, then eagerly
assembles the claudebox in the background (dnf-installs claude-code + tools inside the box). The
first `claude` invocation tails the assemble log if it's still in progress. If `TS_AUTHKEY` is
unset the tailnet join is interactive — `podman logs -f fedora-desktop` for the one-time login URL.

**2FA enrollment (first web login).** The first time you sign in at `https://<host>:8443/guacamole/`
with `core` / `GUAC_PW`, Guacamole shows a **TOTP QR code**: scan it into Google Authenticator
(or any TOTP app) and save it. From then on every login asks for `GUAC_PW` **plus** the 6-digit
code. One seed works on as many devices as you scan it into (portable — that's why TOTP over a
per-device client cert). Each additional user enrolls their own seed on their first login.

## Operate

### Connect and work

```sh
# Browser (public): https://<host>:8443/guacamole/   → login core / GUAC_PW → full XFCE desktop
# RDP (tailnet):     <tailnet-ip>:3389                → login core / RDP_PW (native client)
# Terminal:          ssh core@<tailnet-ip>            (keyless) or  ssh -p 4444 core@<public-ip> (key)
```

In the desktop (or any ssh/mosh shell, all land in tmux `main`), open a terminal and run
`claude` to reach the in-box agent. The XFCE session persists across disconnects
(`KillDisconnected=false`) — reconnect over RDP/web and your apps are still open.

### The workflow — PR-first, maintainer-approved-merge

Claude **never pushes another repo's `main`** and **never self-deploys without your click**:

1. **Other repos** (`fedora-bootstrap`, `fedora-dev`, sibling images, the vault for content):
   develop on a branch → `gh pr create` → Arthur or the host claudebox merges.
2. **This repo's self-deploy** (`fedora-desktop` `main`) and **any control-plane/guardrail
   change** (`policy/**`, `managed-settings.json`, `.github/workflows/**`, a `*.container`
   Quadlet, `run.sh` security flags, the key-sync helper): the agent prepares the change,
   presents a discrete clickable decision, and only on explicit approval performs the push.

This is enforced mechanically, not by good behavior:
- a managed `PreToolUse` hook (`policy/hooks/gate-push.sh`) **denies** `git push` / `gh pr
  merge` / `gh pr create --merge|--auto` / `gh api …/merges|/merge` / wrapper-script variants
  unless a one-shot approval marker is present;
- `managed-settings.json` sets `disableBypassPermissionsMode`, `disableAutoMode`,
  `allowManagedPermissionRulesOnly`, `allowManagedHooksOnly`, an MCP deny on any merge tool,
  and a narrow allow for the vault git-sync push only;
- the **CI control-plane diff-guard** fails any PR touching a guardrail file unless a reviewer
  applies the `control-plane-approved` label (standalone, never bundled).

### Self-develop / self-deploy (the one push the box makes)

```
1 self-develop   edit fedora-desktop source
2 self-validate  run the NEW image LIVE in the OWN nested CONTAINER_HOST engine; exercise
                 RDP/VNC/web + sync. --restart=no --rm, scratch volume, NEVER bind-mount $HOME
                 or the vault, explicit rm at session end
3 promote        clickable approval → push fedora-desktop main
4 self-ship      merged → CI builds + cosign-signs → GHCR → the HOST's pull-based refresh
                 (busy-probe deferral + digest-rollback on health failure) recreates the box
```

### Vault & wiki, cloud sync

- **Vault** (`bear-alchemist/2nd-brain`, **private**): governed by the vault's *own*
  `CLAUDE.md` / `wiki/CLAUDE.md` / `OBSIDIAN.md` — Claude defers to them for all content. Live
  device sync via **Obsidian Sync**; the GitHub mirror is kept current by a box-managed
  periodic git-sync (`bin/vault-gitsync.sh`: commit + `pull --rebase` + push, history-
  preserving, automatic). Never point a generic OS-level file-sync at the vault.
- **Non-vault cloud** (Google Drive + OneDrive): rclone only, no daemon (`bin/cloud-sync.sh`:
  `mount` on-demand + delete-guarded `bisync`). OAuth tokens on the home volume, authorized via
  in-desktop Firefox.
- **Untrusted-content ingest** (`bin/ingest-sandbox.sh`): runs the risky parse step in a
  throwaway sandbox with **no token, no vault, no/allowlisted egress** — invoked on-demand by
  the wiki pipeline, NOT the entrypoint. This is the real containment (see SECRET ISOLATION in
  [policy/CLAUDE.md](policy/CLAUDE.md)).

### Claudebox lifecycle

claude-code lives in the in-container claudebox and is **rebuilt daily** (~04:00) from
Anthropic's `latest` channel; the rebuild **defers** while a `claude` session is live and
fires on exit. Your Claude login + transcripts survive every rebuild (they live in `~/.claude`
on the home volume). Trigger on demand with `claudebox-rebuild` (in-box or host-shell). The
**base desktop image** is rebuilt monthly by CI.

### Troubleshooting & break-glass

`entrypoint.sh` (PID 1) supervises all services via a `pgrep`/`kill -0` watchdog and exits
non-zero on any death (the outer `--restart=always` heals).

- **What it's doing / why unhealthy** — `podman logs -f fedora-desktop`,
  `podman healthcheck run fedora-desktop`.
- **Break-glass shell** — sshd is key-only and `core`'s password is RDP-only, so host-side:
  `podman exec -u 0 -it fedora-desktop bash` (root) or `-u 1000` (the `core` agent).
- **Tailnet not joining** — the box prints the one-time login URL on each interactive login
  until connected. "healthy" means the daemons serve, not that the node is on the tailnet.
- **Whole-container recovery/refresh/rollback is HOST-side** (the bootstrap host owns
  pull/recreate/rollback via the workload-refresh harness) — don't hand-roll `podman
  stop/rm/run` against the running box.
- **TOTP break-glass (lost authenticator)** — clear a user's enrollment so their NEXT login
  re-shows the QR. Host-side: `podman exec -u 0 fedora-desktop mariadb --socket=/run/mysqld/mysqld.sock guacamole_db -e "DELETE FROM guacamole_user_attribute WHERE attribute_name LIKE 'guac-totp-key-%' AND user_id=(SELECT user_id FROM guacamole_user JOIN guacamole_entity USING(entity_id) WHERE name='core');"`
  Keep a recovery admin enrolled on a separate device so you are never locked out of the only door.
- **The DB is stateful — BACK IT UP.** All web logins **and TOTP seeds** live in the
  `/var/lib/mysql` volume (`fedora-desktop-db`). **Losing that volume = losing every enrollment**
  (everyone re-enrolls at next login). Snapshot with `podman exec -u 0 fedora-desktop sh -c 'mariadb-dump --socket=/run/mysqld/mysqld.sock guacamole_db' > guacamole_db.sql`.
  A dead/corrupt DB surfaces as **unhealthy** (it's in the watchdog) rather than a silent total lockout.

## Notes

- **SELinux posture** — the container runs **SELinux-unconfined** (`--security-opt
  label=disable` / `SecurityLabelDisable=true`). Intentional and required: nested rootless
  podman + fuse-overlayfs + the passed `/dev/fuse`/`/dev/net/tun` cannot run under
  `container_t`. Blast radius is bounded by rootless + the user namespace (uid 1000, subuid
  10000-64999), not SELinux; the **host** stays enforcing. Do **not** "fix" the label-disable.
- **Capabilities** — `NET_ADMIN` (tailscaled programs nft + mosh) and `SYS_ADMIN` (the nested
  `distrobox enter` calls `sethostname()`, gated behind `CAP_SYS_ADMIN` by the default,
  non-namespace-aware seccomp profile). Removing either breaks the nested dev box.
- **Fedora base bump** (44 → 45): `ARG FEDORA_VERSION` in the Containerfile is the single
  source of truth; bump the box's `image=quay.io/fedora/fedora-toolbox:N` in `distrobox.ini`
  in lockstep, re-verifying every vendor repo per Principle 4.

---

## Appendix — where to look next

| Looking for | Where |
|---|---|
| Binding rules for editing this repo (Build Principles + full Packages + file purposes) | [CLAUDE.md](CLAUDE.md) |
| Runtime law for the in-claudebox agent (role, push scope, promotion gate, secret isolation, vault/wiki governance) | [policy/CLAUDE.md](policy/CLAUDE.md) |
| The vault's own content governance | `bear-alchemist/2nd-brain` — its `CLAUDE.md` / `wiki/CLAUDE.md` / `OBSIDIAN.md` |
| Host-side refresh/rollback harness internals | [oso-gato/fedora-bootstrap](https://github.com/oso-gato/fedora-bootstrap) |
