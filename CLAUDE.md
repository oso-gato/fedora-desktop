# fedora-desktop — agent rules for editing this repo

## BEFORE ANY CHANGE

Read [README.md](README.md) for human-facing context (what fedora-desktop is, the access
model, deploy, operate, the design appendix). THIS file carries the binding agent-facing
tables (BUILD PRINCIPLES, BASE PACKAGES, BOX PACKAGES, REPO FILE PURPOSES) and the in-repo
procedures.

`policy/CLAUDE.md` + `policy/managed-settings.json` + `policy/hooks/gate-push.sh` are the
**law stamped into the in-container claudebox at runtime** — editing them in THIS repo is the
ONLY way they change, and they are CONTROL-PLANE class (see THE PROMOTION GATE below).

fedora-desktop **is the fedora-dev harness extended**, not a fork: PART A of `install.sh` /
`entrypoint.sh` is fedora-dev verbatim (nested rootless podman + key-only sshd + fail2ban +
rsyslog + tailscale + the daily-claudebox machinery); PART B layers the fedora-xrdp desktop
(XFCE/X11 + xrdp + guacd/Tomcat/Guacamole + the app set). When extending, keep the two halves
legible and keep the harness behavior intact.

## TWO LAYERS, TWO CADENCES, TWO SOURCES OF TRUTH

- **fedora-desktop base image** — `Containerfile` + `install.sh` + `entrypoint.sh` + `bin/`
  + the baked seed at `/usr/local/share/fedora-dev/`. Rebuilt **monthly** on the 15th by CI
  (`--no-cache`). Changes flow: edit → PR → (control-plane? clickable approval) → merge → CI
  build → cosign-sign → GHCR `:latest` → host-side pull-refresh recreates the running box.

- **claudebox (in-container Distrobox)** — `distrobox.ini` + `claudebox-init.sh` +
  `box-rebuild.sh` + `claudebox-daily.sh` + `claudebox-assemble.sh` + `policy/`. The runtime
  source of truth is the **LIVE git clone** at `/home/core/.local/share/fedora-dev/` inside the
  running container (NOT the baked seed). The directory name is kept as `fedora-dev` even
  though this repo is `fedora-desktop` (the box machinery reads that fixed path); only the
  GitHub remote differs (`github.com/oso-gato/fedora-desktop`). Rebuilt **daily** in-container
  + on-demand. Changes flow: edit (in the live clone) → PR → merge → next rebuild applies.

The live spec on the home volume persists across BOTH box rebuilds AND container recreations —
that's the design that lets mid-cycle edits survive monthly base recreates.

## PUSH SCOPE + THE PROMOTION GATE (the load-bearing boundary — binding)

The box bounds its blast radius by *credential* + *built controls*, not by prose. Detail is in
[policy/CLAUDE.md](policy/CLAUDE.md); the rules that bind a repo edit:

- The box may **push `main` of its OWN repo only** (`fedora-desktop`) — the self-deploy path.
  For **every other oso-gato repo**: develop on branches + **open PRs**; Arthur or the host
  claudebox merges. Never push another repo's `main`.
- **Self-repo `main` push** and **any control-plane/guardrail change** require a clickable
  approval (the PROMOTION GATE). CONTROL-PLANE class = `policy/**`, `managed-settings.json`,
  `*.container` Quadlets, `.github/workflows/**`, `run.sh` security flags, the key-sync helper,
  `policy/hooks/gate-push.sh`, the box-rebuild control machinery, `*sudoers*`. Such changes are
  **STANDALONE, single-purpose, NEVER bundled** with a feature change, and named so the diff
  summary makes every guardrail touched obvious.
- **Mechanical enforcement (BUILT, not behavioral):** the managed `PreToolUse` hook
  (`policy/hooks/gate-push.sh`) denies push/merge unless a one-shot approval marker is present;
  `managed-settings.json` disables bypass + auto mode, pins managed-only rules/hooks, MCP-denies
  merge tools, and narrowly allows only the vault git-sync push; CI's **control-plane diff-guard**
  fails any PR touching a guardrail file without the `control-plane-approved` label.

When you edit a control-plane file in a PR, expect the CI guard to fail until a maintainer
applies the waiver label — that is correct, not a bug. Do NOT bundle it with feature work to
"avoid" the guard.

## HEADLESS (binding prerequisite — EVERY variant, EVERY lineage)

Every fedora-desktop image — the **xrdp** lineage (XFCE/LXQt) AND the
**grd** lineage (GNOME-Wayland / GRD), and any future lineage — MUST run
**fully headless**: no physical monitor, no GPU, and no local login seat is ever attached or
required for it to work. The desktop session is always a *virtual* display rendered by software
GL (`mesa-dri-drivers` llvmpipe): the xrdp lineage uses `xorgxrdp`'s headless Xorg server; the
grd lineage uses `mutter --headless` / GRD's headless session. Any change that makes a variant
depend on a real display, a GPU, or a physical seat is a **defect**, not a feature — this is a
hard prerequisite of the remote-desktop-in-a-container design, never a tunable. (Verify per
Principle 9 that the image comes up + serves every access path with no display/seat present.)

## BUILD PRINCIPLES (binding for every code change)

| # | Principle | Rule |
|---|---|---|
| 1 | BASE | Build only from the official `registry.fedoraproject.org/fedora:${FEDORA_VERSION}` image. Version is a Containerfile `ARG` — never inlined. |
| 2 | SOURCES | Every package/artifact from an official source, exactly one of: (a) Fedora's own repos via dnf; (b) the vendor's/developer's own RPM or dnf repo (`.repo` with `gpgcheck=1`); (c) an **official-upstream binary release artifact with NO class-(a)/(b) source** — bounded by the **Class-(c) rules** below (last-resort/zero-base; publisher GPG-signature-or-checksum-verified, fail-closed; one of three self-contained consumption shapes; never loose on `$PATH`; disclosed per-artifact). Never: COPR or other third-party repos, pip/npm/cargo/gem/brew installs, curl-pipe-sh, tarball-on-PATH, flatpak, snap. **Applies to BOTH the base image AND claudebox's `additional_packages`.** Anything outside (a)/(b)/(c)-as-scoped needs an explicit Arthur waiver row. **Class-(c) artifacts in use: `guacamole.war` + `guacamole-auth-ban` + `guacamole-auth-jdbc` + `guacamole-auth-totp` (all four Apache, the same pinned key `GUAC_GPG_FP`, GPG-verified), Obsidian.** |
| 3 | MINIMAL | dnf only with `--setopt=install_weak_deps=False`. Every package gets a justifying row in the relevant Packages table (BASE or BOX); a package without a row is a violation. **Install the most specific (leaf) package, never a convenience metapackage.** `install_weak_deps=False` blocks weak Recommends but NOT a metapackage's hard Requires — a metapackage silently pulls unused components (e.g. `fail2ban` hard-pulls `fail2ban-firewalld`→`firewalld` + `fail2ban-sendmail`→`esmtp`; we install `fail2ban-server`). If unsure whether a name is a metapackage, verify (`dnf repoquery --requires <pkg>`) and flag before adding. **"MINIMUM" IS RELATIVE TO THE CHOSEN CAPABILITY, not the absolute package count.** Once a capability is decided (a working GNOME-shell desktop; an RDP-grade web gate), install the minimal LEAF footprint that makes THAT capability work, and accept + DISCLOSE the irreducible hard-dependency closure it entails (e.g. `gnome-shell`→webkit + `gnome-control-center`). Between options that deliver the SAME capability, prefer the smaller-footprint / built-in / class-(a) one. A lighter option that REDUCES the capability is NOT "more minimal" — it is a lesser function, and choosing it is a recorded capability trade-off, NOT a minimalism win. (Worked decision: Apache Guacamole is the SOLE web gate. noVNC [VNC-grade] was REMOVED fleet-wide — the web door is a PUBLIC, non-tailnet door and noVNC's 8-char VncAuth is unacceptable there (see Principle 7); Guacamole [RDP-grade — H.264/audio/clipboard/file-transfer in the browser, strong password + auth-ban lockout + TLS] is the chosen capability, so its Tomcat + JVM + `.war` footprint IS the minimum for full strongly-authed RDP-in-the-browser. The same "minimum relative to capability" rule explains the disclosed `gnome-shell`→webkit hard-dependency closure (grd): once the DE capability is chosen, that closure is its irreducible minimum, not bloat.) |
| 4 | VERIFY FIRST | Before adopting or bumping any source/version, fact-check it against the live source (web). Gate risky installs (version-mismatched vendor RPMs, new repos, a new Obsidian/Guacamole/jeemig release) in a scratch container before editing build files. |
| 5 | NO SECRETS / NO IDENTITY | No passwords, keys, or personal usernames in any layer, file, or commit. Container user is the generic `core` (uid 1000). Credentials enter only as runtime env vars — `RDP_PW` (always) + `GUAC_PW` (always; the public Guacamole web door), with `RFB_PW` (OPTIONAL; arms the tailnet-only :5900 native-VNC mirror) + `TS_AUTHKEY` optional — and the entrypoint fails fast when a required one is missing. |
| 6 | PINS | The Apache Guacamole `.war` version is a Containerfile `ARG` (`GUAC_VERSION`) + its release-signing-key fingerprint (`GUAC_GPG_FP`) — bump together, after rule 4. The `guacamole-auth-ban`, `guacamole-auth-jdbc` and `guacamole-auth-totp` extensions RIDE the same `GUAC_VERSION`/`GUAC_GPG_FP` (one Apache release, one key — bump all together). (rclone + jakartaee-migration + MariaDB/`mariadb-java-client` are Fedora class-(a) packages — no version pin.) Obsidian is intentionally latest-at-build (resolved from the developer's releases API) with its sha256 logged into the build output. |
| 7 | DEPLOY CONTRACT | Every image ships a `run.sh` that is the only sanctioned way to run it: runtime `--health-cmd` (OCI drops the Containerfile HEALTHCHECK), devices, volumes, restart policy, and the PORT-PUBLISH SET. The Quadlet `fedora-desktop.container` is the systemd-managed equivalent. **The web gateway is the ONLY public publish — `${WEB_PORT}→8443` TLS (Apache Guacamole, the sole web gate), `WEB_PORT` default 8443, changeable at spin-up. ssh (`:22`), mosh (UDP `61001-62000`), RDP (`:3389`) and VNC (`:5900`) are ALL TAILNET-ONLY — never `-p`, and additionally dropped on non-`lo`/non-`tailscale0` interfaces by the in-container `nft fd_tailnet_guard` (tailnet-only by *construction*). ssh is reached via Tailscale SSH (keyless) or ssh-key over the tailnet.** Secrets are per-door, supplied at spin-up (the host claudebox ASKS the operator — see README DEPLOY CONTRACT): `RDP_PW` (strong; system/RDP + web SSO) + `GUAC_PW` (strong; the public web door — Guacamole authenticates the public, non-tailnet door, hardened by the `guacamole-auth-ban` brute-force lockout extension + TLS), with `RFB_PW` OPTIONAL (arms the tailnet-only :5900 native-VNC mirror). Widening the publish set is a control-plane change. |
| 8 | CI + LAYERED CADENCE | `.github/workflows/build.yml` builds → cosign-signs → pushes the base image to GHCR on push to `main`, the 15th monthly (`--no-cache`), and dispatch; PRs build-validate only (no registry write). A **control-plane diff-guard** job fails any PR touching a guardrail file without the `control-plane-approved` label. Built-in token only. The IN-CONTAINER claudebox refreshes daily on its own timer; it never touches CI. |
| 9 | VALIDATE | After any change: build, deploy via `run.sh`, confirm `(healthy)` plus a functional probe of each access path (web :8443 → 200 + login, RDP over tailnet, optional VNC, ssh :4444/tailnet, mosh; cloud-sync + vault-gitsync if configured). Self-validation runs in the OWN nested `CONTAINER_HOST` engine, scratch volume, NEVER bind-mounting `$HOME`/the vault, torn down at session end. Final proof is CI green + a host deploy. |
| 10 | PROMOTION GATE / PUSH SCOPE | The box pushes only `fedora-desktop` `main`, only after a clickable approval; control-plane/guardrail changes are standalone, never bundled, and approval-gated; every other repo is PR-only. Enforced by `policy/hooks/gate-push.sh` + `managed-settings.json` + the CI diff-guard. The in-box agent grows `distrobox.ini`/`policy/`/scripts only by editing the LIVE clone at `/home/core/.local/share/fedora-dev/` and opening a PR. |

### Class-(c) sources — the bounded last-resort exception (fleet-wide; identical in fedora-dev + fedora-bootstrap)

**(c)** ONLY when **no class-(a) Fedora package and no class-(b) vendor `.repo`** exists for the
needed artifact — a **last-resort, zero-base check, re-confirmed at every version bump**; the
moment it appears in Fedora or a vendor `.repo` it MUST move to (a)/(b) (this is what keeps
rclone + tomcat-jakartaee-migration, both now in Fedora, OUT of (c)): an **official-upstream
binary release artifact**, fetched over TLS from the project's **own canonical release channel**
— whose exact host + org/repo (or release-API URL) is **pinned in the disclosure row and
changeable only as a control-plane change** — never a mirror, aggregator, COPR, PPA, OBS home
project, language-package-manager registry (Maven Central/npm/PyPI/crates.io/RubyGems), or
third-party rebuild. Each artifact MUST be **(1) version-pinned** via a Containerfile `ARG` (or
`distrobox.ini` pin), the SOLE exception being an artifact Principle 6 designates
latest-at-build; and **(2) integrity-verified before any use** — against the publisher's **GPG
signature** (`gpg --verify`, key fingerprint pinned in-repo) **whenever one is published**; a
bare `sha*sum -c` against the publisher's own sha256/sha512 is acceptable **only** when the
project publishes no signature; the build **fails closed** on any mismatch / missing /
unfetchable check. *(For a Principle-6 latest-at-build artifact where no hash can be pre-pinned:
TLS-authenticated fetch from the publisher's own release API + **resolve-and-log** the resolved
version + computed sha256 — an auditable record, explicitly NOT a fail-closed gate; reserved to
Principle-6-named artifacts only.)* The artifact may be consumed in **exactly one of three
self-contained shapes**: (i) a developer/vendor-released **AppImage** run from `/opt` (never a
bare ELF/script/tarball); (ii) a webapp/archive **deployed into a class-(a) runtime** (an Apache
`.war` into Fedora's Tomcat); or (iii) a **build-time-only tool** that is itself (c)-verified,
transforms a named (c) artifact, fetches no further network, installs nothing onto `$PATH`, runs
deterministically, and is deleted. **A loose executable / script / tarball on `$PATH` is NEVER
permitted under (c)** (the existing tarball-on-PATH ban stands). Each (c) artifact gets a
**disclosure row** in the relevant Packages table (pinned canonical URL + version + the
signature/checksum kind), and the table's **enumeration line lists every (c) artifact in use**
(no more "none"). **Mechanical backstop (Principle 8 CI):** the control-plane diff-guard asserts
every binary on `$PATH` resolves to an rpm (`rpm -qf`) — the "no loose binary" rule is not just
prose.

**Class-(c) artifacts in use (fedora-desktop):** `guacamole.war` (Apache `.war`, deployed into
Fedora's Tomcat, GPG `.asc`-verified against the pinned Apache key `GUAC_GPG_FP`); `guacamole-auth-ban`
(a SECOND Apache Guacamole artifact — its `.jar` extension dropped into `/etc/guacamole/extensions/`
of the same Fedora Tomcat runtime, GPG `.asc`-verified against the SAME pinned Apache key
`GUAC_GPG_FP` via the identical fetch+verify+extract pattern; the brute-force lockout that makes the
single strong `GUAC_PW` a defensible PUBLIC door); `guacamole-auth-jdbc` (THIRD Apache artifact — the
MySQL JDBC auth extension `.jar` into `/etc/guacamole/extensions/`, same key/pattern; the public door's
auth backend moves to MariaDB because TOTP needs a DB; we install ONLY the `mysql/` jar + stash ONLY
`001-create-schema.sql`, never the `002` guacadmin backdoor); `guacamole-auth-totp` (FOURTH Apache
artifact — the TOTP/Google-Authenticator 2FA extension `.jar`, same key/pattern); Obsidian (developer
AppImage → `/opt`, latest-at-build, sha256 resolve-and-logged — upstream publishes no signature).
*(fedora-dev + fedora-bootstrap carry this identical (c) definition but ship no such artifact:
"Class-(c) artifacts in use: none.")*

## BASE PACKAGES

The fedora-desktop image itself (`install.sh`). Refreshed monthly via CI. Two halves: the
fedora-dev HARNESS (PART A) and the fedora-xrdp DESKTOP (PART B). `claude-code` is NOT here
(it lives in the claudebox). `onedrive` is NOT here (rclone-only cloud).

### PART A — harness (Fedora repos + Tailscale)

| Package | Pin | Source | Why required |
|---|---|---|---|
| podman | Fedora current | a | the container ENGINE — claudebox runs on it; the in-box `podman build` lands here via `CONTAINER_HOST` |
| shadow-utils | Fedora current | a | `newuidmap`/`newgidmap` setuid helpers — mandatory for nested rootless podman |
| fuse-overlayfs | Fedora current | a | nested rootless storage driver (kernel forbids native overlay-on-overlay) |
| passt | Fedora current | a | pasta — podman 5 default rootless network backend |
| nftables | Fedora current | a | firewall backend (tailscaled via Netlink API, netavark default on F41+, fail2ban `nftables[type=multiport]`). No iptables — verified unnecessary |
| openssh-server | Fedora current | a | the login door (key-only; keys synced from `github.com/oso-gato.keys` each start). Public :4444→:22 + keyless Tailscale SSH; mosh bootstraps over either |
| mosh | Fedora current | a | roaming-resilient remote shell. Public UDP 61001-62000 (non-default, avoids the bootstrap host's own mosh) |
| tmux | Fedora current | a | session multiplexer; every interactive login auto-attaches `main` |
| distrobox | Fedora current | a | declaratively bootstraps the claudebox via `distrobox assemble create --file distrobox.ini` |
| inotify-tools | Fedora current | a | `inotifywait` watches the in-box `rebuild.request` flag (no systemd `.path` units here) |
| fail2ban-server | Fedora current | a | brute-force mitigation on public :4444; bans via `nftables`; tailnet CGNAT `ignoreip`'d. The **leaf** package, NOT the `fail2ban` metapackage (hard-pulls firewalld + esmtp — see Principle 3) |
| rsyslog | Fedora current | a | captures sshd AUTHPRIV to `/var/log/secure` for fail2ban (no journald) |
| sudo | Fedora current | a | break-glass escalation (`core` in `wheel`); near-zero footprint (host `podman exec -u 0` is the real recovery door) |
| procps-ng | Fedora current | a | `pgrep` for the entrypoint watchdog AND the `--health-cmd` |
| glibc-langpack-en | Fedora current | a | UTF-8 rendering for tmux/terminal |
| nano | Fedora current | a | one break-glass editor (Fedora's minimal base doesn't ship `vi` reliably) |
| tailscale | Tailscale dnf repo | b | tailnet node + keyless Tailscale SSH (primary path); RDP/VNC/password-auth reach the box ONLY over this tailnet IP |

### PART B — desktop (Fedora repos + vendor repos + developer artifacts)

| Package | Pin | Source | Why required |
|---|---|---|---|
| xrdp | Fedora current | a | RDP server (:3389, tailnet-only) + the Xorg :10 session owner (the Guacamole web gateway fronts this session). Hard-deps `tigervnc-x11-server` → provides `x0vncserver`, the same-session VNC head — the OPTIONAL tailnet-only :5900 native-VNC mirror (armed by `RFB_PW`) |
| xorgxrdp | Fedora current | a | Xorg backend modules xrdp drives (the X session everything attaches to) |
| openh264 | Fedora current | a | H.264 encoder for xrdp's GFX pipeline (the `gfx.toml` H.264-first tuning) |
| guacd | Fedora current | a | Apache Guacamole proxy daemon (loopback `-b 127.0.0.1`); browser-protocol → local RDP |
| libguac-client-rdp | Fedora current | a | guacd's RDP client plugin — the web door reaches the local RDP session through it |
| tomcat | Fedora current | a | servlet container serving the `guacamole.war` webapp (+ the `guacamole-auth-ban` extension) on TLS :8443 |
| tomcat-jakartaee-migration | Fedora current | a | Fedora's jakartaee-migration (`javax2jakarta`) — converts the upstream `guacamole.war` javax→jakarta for Tomcat 10.1 at build (class-a, replaces the old curl'd shaded jar) |
| gnupg2 | Fedora current | a | the `gpg` CLI used at build to verify the `guacamole.war` + `guacamole-auth-ban` + `guacamole-auth-jdbc` + `guacamole-auth-totp` signatures against the pinned Apache key |
| mariadb-server | Fedora current | a | the database the public web door authenticates against (Guacamole JDBC auth) — TOTP 2FA REQUIRES a DB (file-auth cannot store the per-user enrollment seed). Bound to **127.0.0.1 ONLY** (Principle 7: 3306 is NEVER published). The **leaf** daemon pkg (hard-Requires only mariadb/mariadb-common/mariadb-errmsg/coreutils/iproute/which + the systemd shared-lib — same RPM-level systemd dep as sshd/fail2ban, NOT systemd-as-PID-1; runs under the supervised-bash watchdog on xrdp, as `mariadb.service` on grd). `mysql-selinux` is a conditional dep on selinux-policy-targeted, absent here |
| mariadb | Fedora current | a | the MariaDB client CLI (`mariadb`/`mariadb-admin`) — schema load (`001`), readiness ping, and the entrypoint's idempotent DB provisioning |
| mariadb-java-client | Fedora current | a | the JDBC driver Guacamole loads from `$GUACAMOLE_HOME/lib` (`/etc/guacamole/lib`) to reach MariaDB; rpm-owned jar at `/usr/lib/java/mariadb-java-client.jar` (class-a, replaces any Maven-Central download) |
| xfce4-session | Fedora current | a | XFCE session manager (`startxfce4` entry point) |
| xfwm4 | Fedora current | a | XFCE window manager |
| xfce4-panel | Fedora current | a | XFCE panel/taskbar |
| xfdesktop | Fedora current | a | XFCE desktop background + icons |
| xfce4-terminal | Fedora current | a | in-desktop terminal — where the operator runs `claude` |
| Thunar | Fedora current | a | XFCE file manager (vault / cloud-mount browsing) |
| xfce4-settings | Fedora current | a | `xfsettingsd` — XFCE settings daemon (theme/font/DPI/keyboard/cursor applied to GTK apps); `xfce4-session` does NOT hard-require it under `install_weak_deps=False`, so it's listed explicitly (else Firefox/VS Code/Obsidian/1Password render unstyled) |
| dbus-x11 | Fedora current | a | `dbus-launch`/session bus (Electron + gnome-keyring need it) |
| xorg-x11-xauth | Fedora current | a | X authority cookie management for the xrdp X session |
| xdpyinfo | Fedora current | a | X display probe for session-startup scripting / health |
| xterm | Fedora current | a | fallback X client guaranteeing a usable terminal if XFCE's own fails |
| mesa-dri-drivers | Fedora current | a | software/GL rendering for the headless X server (no GPU) |
| mesa-libgbm | Fedora current | a | GBM buffer management Electron/Chromium graphics expect |
| dejavu-sans-fonts | Fedora current | a | base UI font (else tofu) |
| google-noto-sans-fonts | Fedora current | a | wide Unicode coverage for vault/wiki content |
| adwaita-icon-theme | Fedora current | a | GTK icon theme so menus/toolbars aren't blank |
| nss | Fedora current | a | Electron/Chromium TLS/crypto runtime dep (Obsidian, VS Code, 1Password) |
| atk | Fedora current | a | accessibility toolkit — GTK/Electron hard runtime dep |
| at-spi2-atk | Fedora current | a | ATK↔AT-SPI bridge — GTK3/Electron runtime dep |
| cups-libs | Fedora current | a | printing client libs GTK/Electron link against |
| gtk3 | Fedora current | a | GTK3 runtime for Firefox + Electron apps |
| alsa-lib | Fedora current | a | audio runtime (Electron + RDP/Guacamole audio) |
| libnotify | Fedora current | a | desktop notifications (Obsidian/VS Code/1Password) |
| libsecret | Fedora current | a | Secret Service client — apps store tokens via it (backed by gnome-keyring) |
| xdg-utils | Fedora current | a | `xdg-open` — `obsidian://` scheme + opening links from apps |
| gnome-keyring | Fedora current | a | Secret Service provider backing libsecret for app credential storage |
| openssl | Fedora current | a | `keytool`/PKCS12 context for minting the Guacamole TLS keystore at runtime |
| firefox | Fedora current | a | in-desktop browser — rclone OAuth, claude.ai, web login flows |
| code | Microsoft yum repo | b | VS Code — the maintainer-dev editor (`gpgcheck=1`, `repo_gpgcheck=1` — repo-metadata signature parity with the 1Password/Tailscale repos) |
| 1password | 1Password dnf repo | b | 1Password GUI — credential vault (`gpgcheck=1`, `repo_gpgcheck=1`) |
| 1password-cli | 1Password dnf repo | b | 1Password CLI (`op`) — scripted secret retrieval |
| rclone | Fedora current | a | the ONLY cloud-sync engine (NON-vault GDrive + OneDrive; mount + delete-guarded bisync). No abraunegg `onedrive` daemon. From Fedora's OWN repo (class-a, signed) — the unsigned developer rpm was dropped per the zero-base check |
| Obsidian | developer AppImage, latest-at-build (sha256 logged → `/opt`) | c | the vault editor — primary knowledge-work interface (no rpm exists) |
| guacamole.war | Apache `.war` (`GUAC_VERSION`), javax→jakarta-converted | c | the Guacamole web client on :8443 — no class-(a)/(b) source (Fedora retired `guacamole-client` as un-buildable Java, endorsing the prebuilt .war; Apache ships only .war + source + Docker). **GPG-verified** against the pinned Apache key (`GUAC_GPG_FP`) before use; converted with Fedora's class-(a) jakartaee-migration. A class-(c) artifact (see "Class-(c) sources") |
| guacamole-auth-ban | Apache `.tar.gz` (`GUAC_VERSION`) → `.jar` extension | c | brute-force lockout on the PUBLIC :8443 door — bans a source IP after repeated failed Guacamole logins (in-memory, backend-independent, no database). No class-(a)/(b) source. **GPG-verified** against the SAME pinned Apache key (`GUAC_GPG_FP`) via the identical fetch+verify+extract pattern as the .war; the `.jar` is dropped into `/etc/guacamole/extensions/` of Fedora's class-(a) Tomcat runtime. A class-(c) artifact (see "Class-(c) sources") |
| guacamole-auth-jdbc | Apache `.tar.gz` (`GUAC_VERSION`) → `.jar` extension | c | the MySQL JDBC auth backend — moves the public door from file-auth to MariaDB so TOTP 2FA can store per-user enrollment seeds. No class-(a)/(b) source. **GPG-verified** against the SAME pinned Apache key (`GUAC_GPG_FP`), identical fetch+verify+extract pattern. We install ONLY the `mysql/guacamole-auth-jdbc-mysql-*.jar` into `/etc/guacamole/extensions/` and stash ONLY `mysql/schema/001-create-schema.sql`; the `002-create-admin-user.sql` guacadmin backdoor is NEVER shipped or loaded. A class-(c) artifact |
| guacamole-auth-totp | Apache `.tar.gz` (`GUAC_VERSION`) → `.jar` extension | c | TOTP / Google-Authenticator 2FA on the public :8443 door — QR shown at first login, seed stored in the DB. No class-(a)/(b) source. **GPG-verified** against the SAME pinned Apache key (`GUAC_GPG_FP`), identical pattern; `.jar` into `/etc/guacamole/extensions/`. A class-(c) artifact |

**Desktop-variant note (the `DESKTOP_ENV` xrdp family).** The XFCE rows above
(`xfce4-session`…`xfce4-settings`) are the default/base DE leaf set. The `lxqt`
variant REPLACES exactly that block with its own minimal leaf set, enumerated in
`install.sh`'s `DESKTOP_ENV` case (the single source of truth for per-variant packages —
"tabled by reference" there per Principle 3). Note: **polkit privilege-escalation dialogs
are non-functional by design** in both variants (the no-systemd harness supervises no system
D-Bus / `polkitd`) — fine for a vault/wiki + dev workstation that does no interactive system
administration. (**Only XFCE [default] + LXQt [lighter] remain.** KDE was dropped — its KWin
compositor assumes a GPU and is janky under llvmpipe, it is the most screen-churn over the
low-bandwidth web door, and it is polkit-degraded, all for Plasma richness the self-contained
app set doesn't use. MATE was dropped too — it added nothing over XFCE for this purpose.)

## THE TWO LINEAGES — one repo, two init/desktop contracts

fedora-desktop ships **two lineages** in this one repo. They share the harness (PART A), the
app set, the policy, Principle 2(c), AND the **same SOLE web gate — Apache Guacamole on :8443** —
only the DESKTOP + the INIT contract + the NATIVE remote servers differ. Each lineage exposes a
loopback **RDP :3389** (native server) AND a loopback **VNC :5900** (native server, the optional
tailnet-only mirror); Guacamole fronts the RDP as the SOLE public :8443 door (RDP-grade browser:
audio/clipboard/file-transfer; strong `GUAC_PW` + TOTP 2FA + the `guacamole-auth-ban` lockout + TLS;
`guacamole.war`/`-auth-ban`/`-jdbc`/`-totp` are the class-(c) artifacts). noVNC was removed fleet-wide
(the public, non-tailnet door needs strong auth — noVNC's 8-char VncAuth is unacceptable).

**krdp (KDE Plasma-Wayland / KRdp) was REMOVED.** The public door is Guacamole-**over-RDP** on every
lineage, and **KRdp has no headless mode** — "KRdp does not support headless sessions and there are
no immediate plans to do so" (KDE/krdp README, L1); the `--virtual-monitor` capability exists only
for krfb (the VNC server), NOT for the RDP server the web door consumes. So on KDE-Wayland the one
server feeding the public door is the one that cannot get a headless virtual display — it is the
WRONG TOOL for a headless RDP door, not merely unproven. (An earlier draft of this file proposed a
`krdpserver --virtual-monitor` fix; that flag/capability does not exist — the claim was wrong.)

| Lineage (file) | Init | Desktop | RDP server | VNC server | size | Validation |
|---|---|---|---|---|---|---|
| **xrdp** (`Containerfile`) | supervised bash PID-1 (no systemd) | XFCE/LXQt on **X11** (`DESKTOP_ENV`) | xrdp | `x0vncserver` (TigerVNC) | ~3.65 GB (XFCE) | full (build→run→probe) — **the proven, production lineage** |
| **grd** (`Containerfile.grd`) | **systemd-PID-1** | GNOME-50 **Wayland** / GRD | GRD native (FreeRDP) | GRD native (libvncserver) | 3.98 GB | assembly-validated; runtime **EXPERIMENTAL — headless GNOME-Wayland UNPROVEN** |

**Disclosed hard-dep closure (Principle 3 — "minimum relative to capability"; irreducible, NOT bloat):**
- **grd:** `gnome-shell` hard-pulls `webkitgtk6.0` + `webkit2gtk4.1` (~182 MiB: captive-portal
  helper + evolution-data-server) + `gnome-control-center`.
- grd's native VNC server is **libvncserver-backed (Tight+JPEG, ZRLE)** — the optional tailnet :5900
  native-VNC mirror is bandwidth-comparable to the xrdp/TigerVNC path (libvncserver's Tight is
  somewhat less finely tuned than TigerVNC's — a disclosed, order-of-magnitude-equal difference).
  The public :8443 door is Guacamole-over-RDP on both lineages.

**systemd-PID-1 = STOP-AND-SURFACE (grd only).** The grd lineage requires the HOST to grant cgroup-v2
delegation + a writable `/sys/fs/cgroup` — a wider host-trust ask than the xrdp lineage. It deploys
ONLY via `run.sh.grd` (`--systemd=always --cgroupns=host`), NEVER the xrdp `run.sh`. It CANNOT boot
in the nested build engine, so local validation is **assembly-only** (`podman create` +
`podman export | tar -t` + marker/content inspection); the session + the native servers
(GNOME-Wayland under `mutter --headless`, GRD under core's `systemd --user`) are **host-validated**
on a delegating host.

**grd is EXPERIMENTAL — not ship-ready; xrdp is the only proven path.** (An earlier draft wrongly
called grd "canonical" — corrected against L1.) GNOME Remote Desktop has TWO headless modes:
(a) `grdctl --headless` + `gnome-remote-desktop-headless.service` = the *Desktop Sharing* path, which
connects to an **already-running** "independently set up headless graphical user session" (it does
NOT spawn one); (b) `grdctl --system` + GDM = *Remote Login*, the SYSTEM service whose GDM
`CreateRemoteDisplay` spawns a headless `mutter` on connect. **grd currently uses mode (a) but ships
NO gdm, starts no `mutter`/`gnome-session`, and never enables `gnome-remote-desktop-headless.service`**
— so on connect there is no compositor behind the loopback RDP/VNC: a black/refused desktop, while
the guacamole healthcheck still reports 200 off Tomcat's page. **Corrected vs an earlier draft:
GRD 47+ / GNOME-50 added PERSISTENT Remote Login** — a `--system` session survives disconnect and
resumes "from where you left off", with multiple users reachable via GDM, so mode (b) is a legitimate
modern multi-user persistent-resume path, NOT the fresh-session-per-connect it was on GNOME ≤46
(L2 — verify against GNOME's own gnome-remote-desktop release notes before relying on it). To make grd
real, pick ONE: convert to the turnkey `--system`+GDM Remote Login mode (add gdm, `grdctl --system`,
enable `gnome-remote-desktop.service`), OR keep `--headless` and ALSO wire a `gnome-session`/`mutter
--headless` unit + enable `gnome-remote-desktop-headless.service`. Until host-validated on a
delegating host, grd is EXPERIMENTAL — deploy **xrdp (X11) for production**; grd is a follow-up gated
on host validation.

## MULTI-USER (core admin + up to 5 additional users, per-user fleet access)

`core` (uid 1000, wheel) is ALWAYS the admin: full desktop + claudebox/claude-code +
rootless podman = full dev. The entrypoint optionally provisions **up to FIVE additional
desktop users** from spin-up secrets (`USER{1..5}_NAME`/`_PW`/`_ACCESS` — Principle 5,
runtime only, never a layer; the interactive `spin-up.sh` wizard or the host claudebox ASKS
at spin-up per the README DEPLOY CONTRACT). **0 extra users = single-`core` behavior,
byte-identical.** Created idempotently (`useradd -m` uid 1000+n, `chpasswd` re-applied each
boot, `/home` data never clobbered; username validated `^[a-z_][a-z0-9_-]{0,30}$`, not
reserved). Each additional user is non-privileged by construction (NOT in `wheel`, no
sudoers, no `/etc/subuid` row → no rootless podman / no claudebox); a user with no fleet
grant is a pure "wiki worker" (desktop + vault, zero dev reach).

**WEB LAYER — per-user DB identity + TOTP, per-grant fleet tiles.** Provisioning is now
DB-backed (MariaDB + `guacamole-auth-jdbc`) with TOTP 2FA (`guacamole-auth-totp`), emitted by
the shared `bin/guac-db-provision.sh` as idempotent SQL. Each identity is a `guacamole_entity`
+ `guacamole_user` (password-only UPSERT — never touches the TOTP seed) with READ on its own
loopback-RDP desktop connection (SSO). `core`/`GUAC_PW` → Desktop **+ ALL Dev/VPS FLEET_SSH
bastion tiles**. Each extra user → their own Desktop **+ only the bastion tiles their
`USERn_ACCESS` grant allows** (`none` → Desktop only; `dev` → the dev tile; `host` → the vps
tile; `both` → both) — now enforced by per-connection READ grants (DELETE-then-INSERT each boot,
so a `both`→`dev` downgrade actually REVOKES the stale tile), with the fleet SSH connections
deduped into shared objects under one org group. A `none` user genuinely cannot see or reach
the fleet. On EVERY login (TOTP applies to all DB identities) the user enrolls/uses a TOTP code;
a removed user is DISABLED (not deleted), preserving their enrollment. **Security note on
grants:** a `dev`/`host` tile reaches that box over the desktop's tailnet via keyless
Tailscale-SSH = a **`core` (admin) shell** there — so granting `dev`/`host` is an admin-level
grant, NOT a sandboxed login (per-user identities on dev/host would need accounts provisioned
there — a cross-repo follow-up). Each user's web password == their OS password (one credential;
SSO) **plus their TOTP second factor**. (grd is single-user: core only.)

**CROSS-DEVICE PERSISTENT RESUME — the bpp=24 INVARIANT (binding).** Each user gets ONE
xrdp session that survives disconnect (`KillDisconnected=false`) and RESUMES from any device.
xrdp `Policy=Default` keys a session on `<User,BitPerPixel>` only — IP and resolution are
NOT keys (verified vs sesman.ini man) — so a reconnect from a different device/geometry at
the SAME bpp resumes the same running session (`resize-method=display-update` reflows the
viewport). **THE INVARIANT: pin 24 bpp on EVERY path** — `color-depth=24` on every Guacamole
RDP connection (core + each worker), `xrdp-sesrun -b 24` pre-warm, Xorg's inherent 24 bpp,
AND `max_bpp=24` in xrdp.ini (fences a native mstsc/FreeRDP client from negotiating 16/32
and FORKING a second session). **Do NOT switch sesman `Policy` to UBD/UBI/UBDI** (they re-add
DisplaySize/IP as keys → a phone forks a new session). A bpp mismatch is the one silent
failure that breaks resume.

**NON-DEV LOCKDOWN (workers).** NOT in `wheel`, no sudoers; **no `/etc/subuid` row** ⇒ cannot
run rootless podman / reach the claudebox at all; `CONTAINER_HOST` export gated to uid 1000
(`claudebox-init.sh`); the `claude`/`claudebox-rebuild` wrappers are `0750 core:core`; every
home is `0700` (incl. `core`'s — so no user can read another's vault/tokens). `claude-code` +
podman are **core-only by construction**. Each worker gets their OWN persisted `/home/<user>`
volume (`fedora-desktop-userN`, bound in run.sh/the Quadlet) or their data would be lost on
recreation.

**SECURITY CEILING (disclose, do not paper over).** This is **OS-user (DAC) separation inside
ONE shared container** — one kernel, SELinux-disabled, `SYS_ADMIN`/`NET_ADMIN`. "No dev" is a
**policy boundary enforced by file perms + the 0700 podman-socket dir + no-subuid**, NOT a hard
sandbox: a kernel priv-esc collapses it. For mutually-distrusting users you would run separate
containers; this is for cooperating users (Arthur + a wiki collaborator) on one box. The vault
is per-user (each 0700 home); `core` remains the sole git-sync orchestrator (policy/CLAUDE.md).

**HOST-VALIDATION (Principle 9 — none provable in the nested engine; flag at deploy):**
(a) 0 extra users still SSOs `core` straight to a tile list unchanged; (b) 1–2 users each get an
independent live `:1x` session that PAINTS (watch for the XFCE second-session black-screen);
(c) **the requirement:** `user1` from device A, disconnect, reconnect as `user1` from device B
(different IP + screen) RESUMES the same session, apps still open; (d) non-dev proof as a worker:
`sudo -v` denied, no `CONTAINER_HOST`/podman socket, `claude` not executable, cannot read `/home/core`.

## WEB-GATEWAY LOW-BANDWIDTH TUNING (verified vs L1 sources)

The ONLY bandwidth that matters is the **browser ↔ server :8443** hop; the loopback RDP inside
the container is localhost (free). **Guacamole does NOT stream H.264 / inter-frame video to the
browser** — it is an intra-frame still-image model (Guacamole sends PNG/JPEG/WebP `img`
instructions). On a *real-disconnect* unstable link it is naturally resilient (server-held session,
no full-framebuffer-per-reconnect). A real video clip is multi-Mbps regardless — not a tunable.

- **`ENABLE_AUDIO` (default `false`):** audio is a continuous push stream — OFF by default for the
  reading/editing desktop; set `ENABLE_AUDIO=true` to restore it. The entrypoints emit
  `disable-audio=true` by default (Guacamole's real lever — audio is ON unless set; the old
  `enable-audio` param was a **no-op**, verified vs the Guacamole manual).
- **guacamole levers:** `color-depth` (24→16→8 = fewer bytes); keep RDP aesthetic flags OFF
  (Guacamole default); keep `force-lossless=false`; ensure WebP available; `resize-method=
  display-update` (already set). Do **NOT** count on the xrdp `gfx.toml` "H.264-first" tuning to
  cut PUBLIC-hop bytes — it only speeds the FREE localhost RDP hop; guacd re-encodes to images for
  the browser regardless. For a mostly-static desktop that tuning optimizes the wrong hop.

## BOX PACKAGES

Inside claudebox (`distrobox.ini`'s `additional_packages`). Refreshed daily from Anthropic's
`latest` channel + Fedora repos.

| Package | Pin | Source | Why required |
|---|---|---|---|
| claude-code | Anthropic dnf repo (`latest` channel) | b | the agent — claudebox's purpose; refreshed daily so new model releases are accessible day one. **Deliberately NOT baked into the base image** |
| git | Fedora current | a | VCS engine the agent drives (the box is where the agent's shell lives) |
| gh | GitHub dnf repo | b | GitHub/GHCR auth, PRs (the PR-first lifecycle). Auth state at `~/.config/gh/` on the home volume — shared across box rebuilds |
| openssh-clients | Fedora current | a | outbound ssh for git-over-ssh from inside the box |
| podman (client) | Fedora current | a | the agent's `podman build/run/exec/healthcheck`; engine is at fedora-desktop's level, CLI in the box drives it via `CONTAINER_HOST` |
| bubblewrap | Fedora current | a | Linux user-namespace sandbox; Claude Code's Bash tool uses it for isolated execution |
| socat | Fedora current | a | paired with bubblewrap for IPC socket relay into/out of the sandbox |
| host-spawn | Fedora current | a | distrobox container-side host-exec component; presence prevents distrobox-create from `curl`'ing it from GitHub (Principle 2 source control). Headless = shims deliberately not wired |
| rclone | Fedora current | a | the in-box agent's cloud/SMB/SSH/object-store reach for build files (separate from the base-image pinned rclone the entrypoint helpers drive) |

## REPO FILE PURPOSES

| File | Purpose |
|---|---|
| README.md | human-facing project doc (TL;DR, Build Principles, Packages, Deploy, Operate, design appendix) |
| CLAUDE.md | this file — agent rules for editing this repo |
| Containerfile | base image build spec (`FROM fedora:ARG`; pinned `GUAC_VERSION`/`JEEMIG_VERSION`/`RCLONE_VERSION`; runs install.sh; COPYs entrypoint + box seed + bin/ + policy/hooks/; `EXPOSE` metadata; `VOLUME`s) |
| install.sh | base image install — PART A (fedora-dev harness verbatim) + PART B (fedora-xrdp desktop: XFCE, xrdp/guacd/Tomcat, the app set, rclone rpm, Obsidian AppImage, guacamole.war conversion + the GPG-verified guacamole-auth-ban/-jdbc/-totp extensions + MariaDB + the JDBC driver + the stashed `001` schema). Fails fast if the desktop ARGs aren't threaded through |
| entrypoint.sh | PID 1 (root): seeds `core`'s password from RDP_PW; syncs ssh keys; mints the Guacamole TLS keystore; brings up the loopback MariaDB engine + provisions DB-auth/TOTP via the shared `guac-db-provision.sh`; supervises rsyslog + sshd + fail2ban + tailscaled + the rootless podman socket + inotify rebuild-watcher + daily-tick + first-boot live-clone-or-seed + eager claudebox assemble + xrdp-sesman/xrdp + **mariadbd** + guacd + Tomcat + the optional RFB_PW VNC mirror + the cloud-sync/vault-gitsync helpers; single `pgrep`/`kill -0` watchdog; SIGTERM trap for clean shutdown |
| run.sh | manual deploy contract (`podman run -d` with --health-cmd, devices, volumes, restart, the public-only publish set + runtime secrets); fallback for non-systemd hosts. **CONTROL-PLANE (security flags + publish set)** |
| fedora-desktop.container | systemd Quadlet (Pull=missing, Notify=healthy, AutoUpdate=registry, HealthCmd, the three Volumes, SecurityLabelDisable=true, the public-only PublishPort set, commented Secret= lines). **CONTROL-PLANE** |
| Containerfile.grd | **grd lineage** base image (GNOME-Wayland / GRD; `FROM fedora:ARG`; ARGs `GUAC_VERSION`/`GUAC_GPG_FP`; runs install-grd.sh; COPYs entrypoint-grd + the shared box seed; `ENTRYPOINT /sbin/init`; `STOPSIGNAL SIGRTMIN+3`). systemd-PID-1 |
| install-grd.sh | grd-lineage install: the fedora-dev harness as systemd units + GNOME-50 Wayland (minimal leaf) + GRD (RDP+VNC) + the Guacamole web door (guacd/Tomcat/.war + the GPG-verified guacamole-auth-ban extension). Enables sshd/rsyslog/fail2ban/tailscaled + the web units + the firstboot oneshot; sets core linger; bakes lineage=grd |
| entrypoint-grd.sh | grd first-boot oneshot (NOT PID 1): core password, ssh-key sync, GRD TLS PEM, Guacamole web door via DB-auth+TOTP (waits on `mariadb.service`, sources the shared `guac-db-provision.sh`; `security=tls`, no bpp pin; core-only), `grdctl` rdp+vnc config (RDP=RDP_PW; VNC=RFB_PW arms the optional tailnet mirror). Session bringup is HOST-VALIDATED |
| run.sh.grd | grd deploy contract (`--systemd=always --cgroupns=host -v /sys/fs/cgroup`); secrets RDP_PW+GUAC_PW (RFB_PW optional) + the `/guacamole/` health path; secrets via bind-mounted `/etc/fedora-desktop/secrets.env`. **CONTROL-PLANE** + STOP-AND-SURFACE (needs a cgroup-v2-delegating host) |
| distrobox.ini | claudebox manifest: image pin, `pre_init_hook` drops Anthropic `latest`-channel `.repo`, `additional_packages` |
| claudebox-init.sh | post-assemble host bridges (CONTAINER_HOST export + in-box `claudebox-rebuild` flag-writer) over the quote-safe `podman exec` channel |
| claudebox-assemble.sh | first-boot + every-rebuild: `distrobox rm -f` → `distrobox assemble create` → first-enter retry → bridges + **policy stamp (managed-settings.json + policy/hooks/gate-push.sh into /etc/claude-code/)**. **CONTROL-PLANE (it stamps the guardrails)** |
| box-rebuild.sh | full claudebox rebuild (self-serializing via flock); daily tick / in-box flag / host-shell all converge here. **CONTROL-PLANE** |
| claudebox-daily.sh | daily-refresh decision: probe session lock → rebuild if idle, else write `rebuild.pending` (the `claude` wrapper fires it on session exit) |
| bin/claude | host-shell wrapper; holds the SHARED session lock for the session so daily refresh + the host's monthly refresh defer while live; on exit fires the deferred rebuild atomically |
| bin/claudebox-rebuild | host-shell trigger; starts box-rebuild.sh detached + tails the log |
| bin/cloud-sync.sh | rclone `mount` + delete-guarded `bisync` for NON-vault Google Drive + OneDrive (runs as core; `--resync` sentinel-gated; entrypoint launches it in a respawn loop, tolerates absence). NEVER point at the vault |
| bin/vault-gitsync.sh | periodic vault git-sync (commit + `pull --rebase` + push; history-preserving, never force-push; runs as core; entrypoint launches it). Automatic, NOT click-gated (the one push-exception, narrowly allowlisted in managed-settings) |
| bin/ingest-sandbox.sh | runs untrusted-content parsing with NO token, NO full vault, no/allowlisted egress — the SECRET-ISOLATION containment. Invoked on-demand by the wiki pipeline, **NOT** by the entrypoint |
| bin/guac-db-provision.sh | **SINGLE SOURCE OF TRUTH** for Guacamole DB-backed auth + TOTP provisioning, SOURCED by ALL THREE lineage entrypoints after MariaDB is up. Holds the four TOTP/DB must-dos once (load only 001 + delete/fail-closed guacadmin; remove file-auth user-mapping.xml; non-null-parented connections + DELETE-then-INSERT grant reconciliation; password-only UPSERT that preserves the TOTP seed). All hashing is in SQL (`UNHEX(SHA2(...))`); every value hex-encoded (injection-safe). Lineage params: `RDP_SECURITY` (any/tls), `RDP_PIN_BPP` (1/0). Writes the runtime guacamole.properties (DB password — Principle 5, never baked) |
| policy/CLAUDE.md | runtime law for the in-claudebox agent (role, push scope, the promotion gate, secret isolation, vault/wiki governance, non-vault cloud). **CONTROL-PLANE** |
| policy/managed-settings.json | managed-tier guardrails: deny rules, `disableBypassPermissionsMode`/`disableAutoMode`/`allowManagedPermissionRulesOnly`/`allowManagedHooksOnly`, MCP merge-tool deny, the PreToolUse hook wiring. **CONTROL-PLANE** |
| policy/hooks/gate-push.sh | the PROMOTION-GATE PreToolUse hook: fail-closed deny of `git push` / `gh pr merge` / `gh pr create --merge\|--auto` / `gh api …/merges\|/merge` / wrapper-script variants unless a one-shot approval marker is present. Stamped into the claudebox alongside managed-settings.json. **CONTROL-PLANE** |
| .github/workflows/build.yml | CI: build → cosign-sign → push `ghcr.io/oso-gato/fedora-desktop` on push/15th-monthly(`--no-cache`)/dispatch (PRs build-validate only) + the **control-plane diff-guard** job. **CONTROL-PLANE** |

## NESTED BUILDS — CONTAINER_HOST BRIDGE (reference)

As `core` inside claudebox, `podman build/run/exec/healthcheck` works because
`CONTAINER_HOST=unix:///run/user/1000/podman/podman.sock` is exported in
`/etc/profile.d/10-host-podman.sh` (written by `claudebox-init.sh`). That socket is
fedora-desktop's rootless podman API socket, served by `podman system service` supervised in
the entrypoint; distrobox bind-mounts `/run/user/1000/` into the box at the same path. So
`podman build .` runs in **fedora-desktop's engine** (one nesting level, fuse-overlayfs storage
on the home volume), not a third-level engine. Storage/layer-cache/images/stopped containers
persist across box rebuilds AND container recreations.

Subuid/subgid: `core:10000:55000` (sized to fit the outer rootless 65536-ID map). No systemd
inside: cgroupfs manager + file events logger preconfigured; `XDG_RUNTIME_DIR` provided by the
entrypoint; the rebuild-trigger machinery is supervised by the entrypoint's watchdog.

## CADENCE REFERENCE

| Layer | Cadence | Trigger | Source |
|---|---|---|---|
| Base image (RPM updates + fresh Obsidian AppImage) | Monthly (15th @ 04:00 UTC) | CI cron `--no-cache` | Fedora + tailscale + Microsoft + 1Password repos; Apache/rclone pins; Obsidian latest |
| Base image (spec changes) | On push to `main` | CI `on: push` (self-deploy promotion, post-approval) | merged PRs |
| Base image (PR validation) | On every PR | CI `on: pull_request` (build-only + control-plane guard) | the PR diff |
| Claudebox (CLI + tools) | Daily (~04:00) | in-container `claudebox-daily.sh`; defers if a session is active | Anthropic `latest` channel + Fedora repos |
| Claudebox (ad-hoc) | On demand | in-box `claudebox-rebuild` OR host-shell `claudebox-rebuild` | same as daily |
| fedora-desktop container itself | Host-driven | host workload-refresh harness (busy-probe defers if claude is busy; digest-rollback on health failure) | new image from GHCR |

Base bump (Fedora 44 → 45): `ARG FEDORA_VERSION` in the Containerfile is the single source of
truth; bump the box's `image=quay.io/fedora/fedora-toolbox:N` in `distrobox.ini` in lockstep,
re-verifying every vendor repo per Build Principle 4. Fedora releases EOL ~13 months — plan for
twice a year.
