#!/usr/bin/env bash
# fedora-desktop — GRD lineage install (systemd-PID-1).
# ============================================================================
# Minimal GNOME-50 Wayland desktop + GNOME Remote Desktop (RDP; VNC a v1 follow-up) + Apache
# Guacamole web door + the fedora-dev harness re-expressed as systemd units +
# the four apps. MINIMAL LEAF packages only (install_weak_deps=False, PRINCIPLE
# 3): the gnome-shell webkit/control-center closure is the IRREDUCIBLE hard-dep
# cost of a real GNOME desktop (disclosed in CLAUDE.md), not bloat-by-choice.
# HEADLESS prerequisite (CLAUDE.md): no monitor/GPU/seat — mutter --headless.
set -euxo pipefail
DNF="dnf -y --setopt=install_weak_deps=False"

# ---- WEB GATEWAY (the public browser door) — Apache Guacamole ONLY -----------
# The SOLE public desktop door is the TLS web gateway on :8443, fronting GRD's
# loopback RDP :3389 -> HTML5. Guacamole is the ONLY web gateway: it authenticates
# the public door with a STRONG, arbitrary-length password (GUAC_PW). **noVNC was
# REMOVED fleet-wide** — the web gateway is a PUBLIC (non-tailnet) door, and
# noVNC's VNC VncAuth (only 8 chars effective) is unacceptable there. guacd/libguac
# + Fedora Tomcat + tomcat-jakartaee-migration are class-(a); only the guacamole.war
# web client is class-(c) (GPG-verified below); gnupg2 = the gpg CLI for that check.
: "${GUAC_VERSION:?GUAC_VERSION ARG must be passed from Containerfile.grd}"
: "${GUAC_GPG_FP:?GUAC_GPG_FP ARG must be passed from Containerfile.grd}"
WEB_PKGS="guacd libguac-client-rdp libguac-client-ssh tomcat tomcat-jakartaee-migration gnupg2"
echo ">>> fedora-desktop-grd web gateway: Apache Guacamole (only) | pkgs='$WEB_PKGS'"
# DB-backed auth (TOTP 2FA REQUIRES a database). MariaDB + JDBC driver are Fedora
# class-(a) leaf packages; the two Guacamole extensions are class-(c) (GPG-verified
# below). On this systemd lineage MariaDB runs as mariadb.service (not supervised-bash).
DB_PKGS="mariadb-server mariadb mariadb-java-client"
echo ">>> fedora-desktop-grd DB-backed auth: MariaDB + Guacamole jdbc/totp | pkgs='$DB_PKGS'"

# ---- vendor dnf repos (class b, gpgcheck=1) — shared with the xrdp lineage --
curl -fsSL https://pkgs.tailscale.com/stable/fedora/tailscale.repo -o /etc/yum.repos.d/tailscale.repo
cat > /etc/yum.repos.d/vscode.repo <<'EOF'
[code]
name=Visual Studio Code
baseurl=https://packages.microsoft.com/yumrepos/vscode
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
EOF
cat > /etc/yum.repos.d/1password.repo <<'EOF'
[1password]
name=1Password Stable Channel
baseurl=https://downloads.1password.com/linux/rpm/stable/$basearch
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://downloads.1password.com/linux/keys/1password.asc
EOF

# ============================================================================
# ONE minimal leaf transaction.
# ============================================================================
$DNF install \
    systemd systemd-pam \
    podman shadow-utils fuse-overlayfs passt nftables \
    openssh-server mosh tmux distrobox inotify-tools \
    sudo procps-ng glibc-langpack-en nano \
    tailscale \
    gnome-shell gnome-session mutter gsettings-desktop-schemas \
    ptyxis nautilus \
    gdm accountsservice python3-gobject \
    gnome-remote-desktop pipewire pipewire-libs wireplumber \
    xorg-x11-server-Xwayland mesa-dri-drivers mesa-libgbm openssl acl \
    ${WEB_PKGS} \
    ${DB_PKGS} \
    firefox rclone fastfetch \
    code 1password 1password-cli
# claude-code is DELIBERATELY NOT here (lives in the claudebox). onedrive is NOT
# here (rclone-only). gnome-shell's webkitgtk6.0 + webkit2gtk4.1 + gnome-control-
# center ride in as hard requires — disclosed, irreducible.
#
# DEFAULT TERMINAL = ptyxis (REPLACES gnome-terminal — ptyxis supersedes it, so
# keeping both is redundant per Principle 3). ptyxis is the DEFAULT terminal on
# BOTH lineages — "where the operator runs `claude`". On grd no extra config makes
# it the default: GNOME-50's default terminal is resolved by GIO, NOT by the
# `org.gnome.desktop.default-applications.terminal` gsetting (that schema still
# exists but is marked "DEPRECATED ... ignored. The default terminal is handled in
# GIO" — verified in F44's gsettings-desktop-schemas). GIO's find_terminal_executable
# walks a built-in candidate list and runs the FIRST one present on $PATH; Fedora's
# glib2 orders it `xdg-terminal-exec, ptyxis, kgx, gnome-terminal, …` (verified in
# libgio-2.0). xdg-terminal-exec is NOT shipped, so once ptyxis is installed (and
# gnome-terminal removed) ptyxis is the first available candidate => the GIO system
# default for ALL users — no per-user provisioning. (ptyxis is already GTK4/libadwaita
# native here: GNOME-shell pulls that toolkit in regardless, so unlike the XFCE/GTK3
# lineage it adds no net-new toolkit closure.) fastfetch = the terminal greeting (below).

# ---- core (uid 1000) + subuid/subgid for nested rootless podman -------------
useradd -u 1000 -m -s /bin/bash core
printf 'core:10000:55000\n' > /etc/subuid
printf 'core:10000:55000\n' > /etc/subgid
usermod -aG wheel core
setcap cap_setuid+ep /usr/bin/newuidmap
setcap cap_setgid+ep /usr/bin/newgidmap

# ---- harness as systemd units ----------------------------------------------
systemctl enable sshd.service tailscaled.service
# core's LINGERING user manager hosts the nested rootless podman socket + the
# daily-refreshed claudebox. loginctl needs a running logind (absent at build) →
# write the linger marker directly (idempotent). (Per-user DESKTOP sessions are
# spawned by gdm/gnome-headless-session@ — see below — not by this marker.)
mkdir -p /var/lib/systemd/linger && touch /var/lib/systemd/linger/core

# ---- runtime cap restore on newuidmap/newgidmap (ROOT oneshot) --------------
# The build-time setcap (above) doesn't always survive a layer commit / volume — the
# security.capability xattr can be stripped, and without these caps core's nested
# rootless podman fails ("newuidmap: write to uid_map failed"). The xrdp lineage
# re-asserts them inline at boot (entrypoint.sh); the systemd idiom is a root oneshot
# ordered Before=systemd-user-sessions.service so the caps are back BEFORE core's
# lingered user manager assembles the claudebox. Idempotent: sets only if missing.
cat > /etc/systemd/system/fedora-desktop-grd-caps.service <<'EOF'
[Unit]
Description=fedora-desktop GRD: restore newuidmap/newgidmap file caps (root)
Before=systemd-user-sessions.service user@1000.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'for bin in /usr/bin/newuidmap /usr/bin/newgidmap; do [ -x "$bin" ] || continue; if ! getcap "$bin" | grep -q "cap_set"; then case "$bin" in */newuidmap) setcap cap_setuid+ep "$bin" ;; */newgidmap) setcap cap_setgid+ep "$bin" ;; esac && echo "[caps] restored on $bin" || echo "[caps] FAILED to restore $bin (no CAP_SETFCAP?)" >&2; fi; done'
[Install]
WantedBy=multi-user.target
EOF
systemctl enable fedora-desktop-grd-caps.service

# ---- nft tailnet-guard as an EARLY, always-on oneshot (NOT the DB-gated firstboot) -----
# The web gateway (:8443) is the ONLY public door; ssh (:22), mosh, every GRD RDP port
# (:3389-3394) + the reserved VNC :5900 are TAILNET-ONLY, dropped on all ifaces but lo +
# tailscale0. xrdp applies this guard in PID-1, so it is present whenever ANY listener is.
# On grd the guard previously lived INSIDE the firstboot oneshot (Requires=mariadb.service):
# a DB/provisioning failure left sshd + tailscaled up with NO guard. Lift it to its own
# oneshot ordered Before the listeners, with NO Requires=mariadb, so the tailnet-only
# boundary holds regardless of provisioning. Non-fatal (parity: no NET_ADMIN/nft → log+skip).
install -d -m 0700 /etc/fedora-desktop
cat > /etc/fedora-desktop/tailnet-guard.nft <<'NFT'
table inet fd_tailnet_guard {
  chain input {
    type filter hook input priority -10; policy accept;
    iifname "lo" accept
    iifname "tailscale0" accept
    tcp dport { 22, 3389-3394, 5900 } drop
    udp dport 61001-62000 drop
  }
}
NFT
cat > /etc/systemd/system/fedora-desktop-grd-netguard.service <<'EOF'
[Unit]
Description=fedora-desktop GRD: tailnet-only nft guard (ssh/mosh/RDP/VNC off non-tailnet ifaces)
Before=sshd.service tailscaled.service fedora-desktop-grd-firstboot.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c '/usr/sbin/nft -f /etc/fedora-desktop/tailnet-guard.nft || echo "[net-guard] tailnet-guard skipped (no NET_ADMIN / nft?)" >&2'
[Install]
WantedBy=multi-user.target
EOF
systemctl enable fedora-desktop-grd-netguard.service

# ---- sshd hardening + persistent host keys (xrdp harness parity) ----
# Harden the stock Fedora sshd (key-only posture) + keep a persistent host key on
# the state volume (else every recreation regenerates it → MITM-warning churn).
# ssh is :22, TAILNET-ONLY (the netguard oneshot above drops it off non-tailnet
# interfaces; run.sh.grd publishes only the web port). No fail2ban/rsyslog on this
# lineage — see the packages transaction: the brute-force apparatus guarded a public
# ssh door fedora-dev has and this box does not; the public door's defense is
# guacamole-auth-ban.
cat > /etc/ssh/sshd_config.d/99-fedora-desktop.conf <<'EOF'
PasswordAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
MaxAuthTries 3
PermitRootLogin no
AllowUsers core
HostKey /var/lib/tailscale/hostkeys/ssh_host_ed25519_key
EOF
rm -f /etc/ssh/ssh_host_*_key*   # never ship host keys in a published image
# Persistent host key on the bound state volume, minted BEFORE sshd starts. The xrdp
# entrypoint does this inline; the systemd idiom is an ExecStartPre drop-in so it runs
# regardless of the firstboot oneshot's ordering (sshd.service is enabled independently).
install -d -m 0755 /etc/systemd/system/sshd.service.d
cat > /etc/systemd/system/sshd.service.d/10-persistent-hostkey.conf <<'EOF'
[Service]
ExecStartPre=/usr/bin/install -d -m 0700 /var/lib/tailscale/hostkeys
ExecStartPre=/bin/bash -c '[ -f /var/lib/tailscale/hostkeys/ssh_host_ed25519_key ] || ssh-keygen -t ed25519 -N "" -f /var/lib/tailscale/hostkeys/ssh_host_ed25519_key'
# Sync core's authorized_keys from github.com/oso-gato.keys BEFORE sshd starts, so the
# first-EVER boot has NO keyless window (sshd is key-only). Runs as core (writes core's
# ~/.ssh at 0600); keeps the cached file on a fetch failure. Mirrors entrypoint.sh.
ExecStartPre=-/usr/sbin/runuser -u core -- /bin/bash -c 'set -u; mkdir -p ~/.ssh; chmod 0700 ~/.ssh; tmp=$(mktemp); if curl -fsSL --max-time 10 https://github.com/oso-gato.keys -o "$tmp" && [ -s "$tmp" ]; then mv "$tmp" ~/.ssh/authorized_keys; chmod 0600 ~/.ssh/authorized_keys; echo "[ssh-keys] synced from github.com/oso-gato.keys ($(wc -l < ~/.ssh/authorized_keys) keys)"; else rm -f "$tmp"; if [ -s ~/.ssh/authorized_keys ]; then echo "[ssh-keys] GitHub unreachable; keeping cached ~/.ssh/authorized_keys"; else echo "[ssh-keys] WARNING: GitHub unreachable AND no cached keys — public ssh closed; use Tailscale SSH to recover"; fi; fi'
EOF

# ---- surface the Tailscale interactive login on remote logins until the node
# is on the tailnet. A fresh state volume has no persisted identity, so the
# one-time browser join has to happen somewhere — and on grd ssh is tailnet-ONLY
# (no public door at all), so a freshly-deployed box has no shell until it joins
# the tailnet. Print the live login URL on each interactive login until connected.
# Runs BEFORE the tmux attach below (tmux redraws the screen and would hide it);
# zz-tailscale-login sorts before zz-tmux-attach by filename. Mirrors the xrdp install.sh.
cat > /etc/profile.d/zz-tailscale-login.sh <<'EOF'
# Show the Tailscale login URL on interactive logins while not yet connected.
# Silent once BackendState=Running (identity persists on the fedora-desktop-state
# volume, so this only nags until the one-time join is done).
case $- in *i*) ;; *) return ;; esac
[ -t 0 ] || return
command -v tailscale >/dev/null 2>&1 || return
_ts_state=$(tailscale status --json 2>/dev/null | sed -n 's/.*"BackendState": *"\([^"]*\)".*/\1/p')
if [ -n "$_ts_state" ] && [ "$_ts_state" != "Running" ]; then
    _ts_url=$(tailscale status --json 2>/dev/null | sed -n 's/.*"AuthURL": *"\([^"]*\)".*/\1/p')
    printf '\n\033[1;33m  Tailscale is not connected (state: %s).\033[0m\n' "$_ts_state"
    if [ -n "$_ts_url" ]; then
        printf '     Open this in a browser to join the tailnet (one-time):\n       \033[4m%s\033[0m\n' "$_ts_url"
    else
        printf '     No login URL yet - run:  tailscale up --ssh --hostname=fedora-desktop-grd\n'
    fi
    printf '     Tailnet SSH works once you approve it; this notice then disappears.\n\n'
fi
unset _ts_state _ts_url 2>/dev/null || true
EOF

# ---- every interactive remote login lands in the persistent tmux workspace ----
# Harness parity with the xrdp lineage (this drop-in was previously absent on grd,
# so ssh/mosh logins got a plain shell with no tmux continuity). Each login gets
# its OWN session inside the shared "main" group: the windows (the work) are
# shared across every client, but each client's geometry and redraw state stay
# INDEPENDENT — killing the multi-client geometry race where a newly-attaching
# client of a different size forces the shared window to its geometry and paints
# every other client onto a foreign grid (the garble on Prompt 3 / WebSSH). The
# guards (interactive shell + SSH_TTY/tty) mean the GDM-spawned headless GNOME
# session is untouched — only ssh/mosh logins (and in-desktop terminals) attach.
# Per-connection "c<pid>" session self-destroys on disconnect; work persists in
# the detached "main" base. Identical to fedora-dev / the xrdp install.sh.
cat > /etc/profile.d/zz-tmux-attach.sh <<'EOF'
# ssh + mosh logins each get their own session in the shared "main" group.
case $- in *i*) ;; *) return ;; esac
if [ -z "${TMUX:-}" ] && command -v tmux >/dev/null && { [ -n "${SSH_TTY:-}" ] || [ -t 0 ]; }; then
    tmux has-session -t main 2>/dev/null || tmux new-session -d -s main 2>/dev/null || true
    exec tmux new-session -t main -s "c$$" \; set-option destroy-unattached on
fi
EOF

# ---- fastfetch greeting on terminal start (system-wide; core + USER1..5) ------
# Show a fastfetch system-info banner EXACTLY ONCE per login, in the tmux pane the
# operator actually sees. Every interactive login is `exec`'d into tmux by the
# zz-tmux-attach.sh drop-in above: the OUTER pre-attach login shell sources this
# file via /etc/profile, and the shell tmux then spawns INSIDE the pane re-sources
# it via /etc/bashrc (Fedora's /etc/bashrc loops /etc/profile.d/*.sh for non-login
# interactive shells too — verified). Gating on $TMUX therefore fires fastfetch
# ONLY in the in-tmux shell (visible pane) and NEVER in the outer shell that
# `exec tmux` immediately replaces — exactly once, after the tmux UI is up.
# System-wide /etc/profile.d needs NO per-user provisioning (covers USER1..5).
cat > /etc/profile.d/zz-fastfetch.sh <<'EOF'
# fastfetch greeting — once per login, inside the visible tmux pane only.
case $- in *i*) ;; *) return 0 ;; esac
[ -t 1 ] || return 0
[ -n "${TMUX:-}" ] || return 0
command -v fastfetch >/dev/null 2>&1 && fastfetch
EOF

# tmux server config: multi-device geometry policy + clean co-view (see the xrdp
# install.sh for the full rationale). window-size=latest -> the session follows
# the device that most recently sent INPUT (seamless macOS<->iPad handoff over
# mosh; idle larger device blank-letterboxes via fill-character ' ', smaller one
# crops; on active-device disconnect it falls back to whoever remains). prefix+g
# cycles latest -> smallest -> largest. A tmux window has ONE size shared by all
# co-viewing clients, so differently-sized devices on the SAME tab cannot each be
# full-size (a tmux invariant, not a bug).
cat > /etc/tmux.conf <<'EOF'
set -g default-terminal "tmux-256color"
set -g window-size latest
setw -g aggressive-resize on
setw -g fill-character ' '
set-hook -g client-attached 'refresh-client'
set-hook -g client-resized  'refresh-client'
set -g @coview latest

# prefix+g: cycle the multi-device geometry policy (see comment above install).
bind-key g {
  if-shell -F '#{==:#{@coview},latest}' {
    set -g window-size smallest
    set -g @coview smallest
    display-message 'co-view: SMALLEST - every device sees the whole session; big screens blank-letterbox'
  } {
    if-shell -F '#{==:#{@coview},smallest}' {
      set -g window-size largest
      set -g @coview largest
      display-message 'co-view: LARGEST - biggest connected screen wins; smaller devices show a cropped view'
    } {
      set -g window-size latest
      set -g @coview latest
      display-message 'co-view: LATEST - the device you last typed on wins; whole session rescales to it'
    }
  }
  refresh-client -S
}
EOF

# ============================================================================
# claudebox: nested rootless podman + eager assemble (core's DEV capability)
# ============================================================================
# Functional parity with the xrdp lineage's supervised-bash claudebox machinery
# (entrypoint.sh: the rootless podman API socket + first-boot live-clone-or-seed +
# eager `claudebox-assemble.sh`), re-expressed in the systemd-PID-1 idiom: a core
# `systemd --user` socket + oneshot under linger. WITHOUT this, `claude`/claudebox is
# DEAD on grd (no CONTAINER_HOST, no engine socket, the box is never assembled) — a
# regression of core's headline dev capability. Containerfile.grd COPYs the box FILES;
# this block is what ENABLES them.

# 1) The rootless podman API socket = the CONTAINER_HOST target the box's `podman` drives
#    (it provides /run/user/1000/podman/podman.sock, the path claudebox-init.sh exports).
#    Fedora ships the user unit; --global enables it for core's lingered manager. Workers
#    get only their own idle socket — no CONTAINER_HOST (gated to uid 1000 in claudebox-init)
#    and no /etc/subuid row — so it stays core-only by construction (the xrdp 0700-dir boundary).
systemctl --global enable podman.socket

# 2) First-boot bootstrap, run AS core via a `systemd --user` oneshot: seed/clone the LIVE
#    spec to ~/.local/share/fedora-dev, then eagerly assemble the claudebox ONCE
#    (claudebox-assemble.sh writes the .assembled marker + stamps the CONTAINER_HOST bridge
#    + the managed policy/gate-push hook via `podman exec claudebox`). Mirrors entrypoint.sh's
#    live-clone-or-seed + eager-assemble; NON-FATAL — a dev-box seed failure must never take
#    down the desktop / web door (the desktop is primary on fedora-desktop).
install -d -m 0755 /usr/local/libexec   # OFF $PATH (the no-loose-binary CI backstop scans $PATH)
cat > /usr/local/libexec/grd-claudebox-bootstrap.sh <<'BOOTSTRAP_EOF'
#!/usr/bin/env bash
# grd: first-boot live-spec seed/clone + eager claudebox assemble, AS core.
# systemd --user re-expression of the xrdp entrypoint's live-clone-or-seed + eager assemble.
set -u
live=/home/core/.local/share/fedora-dev
seed=/usr/local/share/fedora-dev
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
mkdir -p "$(dirname "$live")" "$HOME/.local/state/claudebox"

if [ -d "$live/.git" ]; then
    echo "[live-spec] git clone already present at $live"
elif [ -f "$live/.seeded-no-git" ]; then
    echo "[live-spec] seeded-no-git state present; convert per CONVERT-TO-GIT.md"
else
    cloned=0
    for attempt in 1 2 3 4 5; do
        git clone --depth 1 https://github.com/oso-gato/fedora-desktop "$live" 2>/dev/null && { cloned=1; break; }
        echo "[live-spec] clone attempt $attempt failed; retrying in $((attempt*5))s"; sleep $((attempt*5))
    done
    if [ "$cloned" = 1 ]; then
        ( cd "$live" && git config --local user.email "claudebox@fedora-desktop.local" \
                     && git config --local user.name  "claudebox" )
        echo "[live-spec] cloned from GitHub + git identity initialized"
    else
        echo "[live-spec] GitHub unreachable after 5 attempts — seeding files only (no git)"
        mkdir -p "$live"; cp -rT "$seed" "$live"; date -Iseconds > "$live/.seeded-no-git"
        cat > "$live/CONVERT-TO-GIT.md" <<'NOTE'
# This live spec was seeded from the baked image because GitHub was unreachable at first
# boot. box-rebuild / daily-tick / watcher work (they read files); the propose-and-commit
# cycle is BLOCKED until you convert. Once the box has internet to GitHub:
#     cd ~/.local/share/fedora-dev
#     rm -f .seeded-no-git CONVERT-TO-GIT.md
#     git init && git remote add origin https://github.com/oso-gato/fedora-desktop
#     git fetch --depth 1 origin main && git reset --hard origin/main
#     git config --local user.email "claudebox@fedora-desktop.local"
#     git config --local user.name  "claudebox"
NOTE
    fi
fi

# Eager assemble ONCE (claudebox-assemble.sh writes the .assembled marker on success).
if [ ! -e "$HOME/.local/state/claudebox/.assembled" ]; then
    echo "[first-boot] assembling claudebox…"
    bash "$live/claudebox-assemble.sh" > "$HOME/.local/state/claudebox/first-assemble.log" 2>&1 < /dev/null \
        && echo "[first-boot] claudebox ready" \
        || echo "[first-boot] assemble FAILED — see ~/.local/state/claudebox/first-assemble.log"
fi
BOOTSTRAP_EOF
chmod 0755 /usr/local/libexec/grd-claudebox-bootstrap.sh

# core-only (ConditionUser): workers (uid 1001+) have no subuid/CONTAINER_HOST, so skip in
# their `systemd --user` managers. Ordered After=podman.socket so the engine target exists.
cat > /etc/systemd/user/claudebox-bootstrap.service <<'UNIT_EOF'
[Unit]
Description=fedora-desktop-grd: seed live spec + eager-assemble the claudebox (core)
ConditionUser=core
After=podman.socket
Wants=podman.socket
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/libexec/grd-claudebox-bootstrap.sh
[Install]
WantedBy=default.target
UNIT_EOF
systemctl --global enable claudebox-bootstrap.service

# 3) NON-vault cloud-sync + vault git-sync — core `systemd --user` services with
#    Restart=always (the systemd equivalent of the xrdp entrypoint's 30s respawn loops,
#    entrypoint.sh:600-601). Both scripts self-loop, no-op when unconfigured, tolerate
#    absence. Prefer the LIVE clone's copy (so live edits take effect), fall back to the
#    baked seed. vault-gitsync is the one push the promotion gate allowlists (data continuity).
#    NO After=claudebox-bootstrap ordering: data-sync must NOT wait on the multi-minute
#    claudebox assemble (xrdp runs these helpers in parallel) — the ExecStart already
#    prefers the live clone with a baked-seed fallback, so neither needs the box assembled.
for _svc in cloud-sync vault-gitsync; do
cat > "/etc/systemd/user/${_svc}.service" <<UNIT_EOF
[Unit]
Description=fedora-desktop-grd: ${_svc} (core)
ConditionUser=core
[Service]
ExecStart=/bin/bash -c 'p=/home/core/.local/share/fedora-dev/bin/${_svc}.sh; [ -f "\$p" ] || p=/usr/local/share/fedora-dev/bin/${_svc}.sh; exec bash "\$p"'
Restart=always
RestartSec=30
[Install]
WantedBy=default.target
UNIT_EOF
systemctl --global enable "${_svc}.service"
done

# 4) claudebox refresh machinery — the systemd equivalent of the xrdp entrypoint's daily
#    tick (entrypoint.sh:539-553) + inotify rebuild-watcher (:523-533). Completes the box's
#    self-update harness: the eager bootstrap (above) gives a working `claude`; these keep it
#    current + honor the in-box `claudebox-rebuild` flag. All core `systemd --user`, ConditionUser.
#  (a) rebuild-watcher: a .path unit on ~/.local/state/claudebox/rebuild.request → a oneshot that
#      REMOVES the flag (so the .path re-arms, mirroring the inotify `create`+`rm`) then runs
#      box-rebuild.sh. The in-box `claudebox-rebuild` wrapper writes that flag.
cat > /etc/systemd/user/claudebox-rebuild-watch.path <<'UNIT_EOF'
[Unit]
Description=fedora-desktop-grd: watch for the in-box claudebox-rebuild flag (core)
ConditionUser=core
[Path]
PathExists=%h/.local/state/claudebox/rebuild.request
[Install]
WantedBy=default.target
UNIT_EOF
cat > /etc/systemd/user/claudebox-rebuild-watch.service <<'UNIT_EOF'
[Unit]
Description=fedora-desktop-grd: run a claudebox rebuild on the flag (core)
ConditionUser=core
[Service]
Type=oneshot
# Remove the flag FIRST (so the .path re-arms), then rebuild from the LIVE clone (baked fallback).
ExecStart=/bin/bash -c 'rm -f "$HOME/.local/state/claudebox/rebuild.request"; p=/home/core/.local/share/fedora-dev/box-rebuild.sh; [ -f "$p" ] || p=/usr/local/share/fedora-dev/box-rebuild.sh; exec bash "$p"'
UNIT_EOF
systemctl --global enable claudebox-rebuild-watch.path
#  (b) daily refresh: a .timer at ~04:00 → claudebox-daily.sh (which probes the session lock and
#      either rebuilds now or drops rebuild.pending for the `claude` wrapper to fire on exit).
cat > /etc/systemd/user/claudebox-daily.service <<'UNIT_EOF'
[Unit]
Description=fedora-desktop-grd: daily claudebox refresh decision (core)
ConditionUser=core
[Service]
Type=oneshot
ExecStart=/bin/bash -c 'p=/home/core/.local/share/fedora-dev/claudebox-daily.sh; [ -f "$p" ] || p=/usr/local/share/fedora-dev/claudebox-daily.sh; exec bash "$p"'
UNIT_EOF
cat > /etc/systemd/user/claudebox-daily.timer <<'UNIT_EOF'
[Unit]
Description=fedora-desktop-grd: daily claudebox refresh ~04:00 (core)
ConditionUser=core
[Timer]
OnCalendar=*-*-* 04:00:00
Persistent=true
[Install]
WantedBy=timers.target
UNIT_EOF
systemctl --global enable claudebox-daily.timer

# ---- GRD variant-1 headless desktop: gdm as session FACTORY (HOST-VALIDATED) ----
# Each desktop user gets a headless AUTOLOGIN session spawned on demand by gdm via
# gnome-headless-session@<user> (GDM CreateUserDisplay → NO greeter → a real
# class=user logind session, so portals + keyring work); the user's
# gnome-remote-desktop-headless.service serves NLA RDP on a per-user loopback port,
# fronted by Apache Guacamole on :8443. gdm runs ONLY as the factory (no greeter on a
# headless box; CreateUserDisplay needs no /dev/dri — mutter surfaceless llvmpipe).
# Proven single- AND multi-user in validation/grd-headless-spike.sh. Fail-closed: the
# units this depends on must exist (python3-gobject + accountsservice are needed by
# gdm-headless-login-session, installed above).
for _u in /usr/lib/systemd/system/gdm.service \
          /usr/lib/systemd/system/gnome-headless-session@.service \
          /usr/lib/systemd/user/gnome-remote-desktop-headless.service; do
    [ -f "$_u" ] || { echo "FATAL: required GRD unit missing: $_u" >&2; exit 1; }
done
systemctl set-default graphical.target
systemctl enable gdm.service
systemctl --global enable gnome-remote-desktop-headless.service

# ---- Obsidian: developer AppImage (class c), latest-at-build, sha256 logged --
OBSIDIAN_VERSION=$(curl -fsSL https://api.github.com/repos/obsidianmd/obsidian-releases/releases/latest \
    | grep -oP '"tag_name":\s*"v\K[0-9.]+')
curl -fsSL -o /tmp/Obsidian.AppImage \
    "https://github.com/obsidianmd/obsidian-releases/releases/download/v${OBSIDIAN_VERSION}/Obsidian-${OBSIDIAN_VERSION}.AppImage"
sha256sum /tmp/Obsidian.AppImage   # logged into the build output
chmod +x /tmp/Obsidian.AppImage
( cd /tmp && ./Obsidian.AppImage --appimage-extract >/dev/null )
mv /tmp/squashfs-root /opt/obsidian; chmod -R a+rX /opt/obsidian; rm /tmp/Obsidian.AppImage
cat > /usr/share/applications/obsidian.desktop <<EOF
[Desktop Entry]
Name=Obsidian
Exec=/opt/obsidian/obsidian --no-sandbox %u
Icon=/opt/obsidian/obsidian.png
Type=Application
Categories=Office;
MimeType=x-scheme-handler/obsidian;
X-AppImage-Version=${OBSIDIAN_VERSION}
EOF
[ -f /usr/share/applications/1password.desktop ] && \
    sed -i 's|^Exec=\(\S*\)|Exec=\1 --no-sandbox|' /usr/share/applications/1password.desktop || true

# ============================================================================
# WEB DOOR: Apache Guacamole (the only web gateway)
# ============================================================================
# ---- Guacamole webapp: Apache .war (the lone class-c), GPG-verified ----------
curl -fsSL -o /tmp/guacamole.war \
    "https://downloads.apache.org/guacamole/${GUAC_VERSION}/binary/guacamole-${GUAC_VERSION}.war"
curl -fsSL -o /tmp/guacamole.war.asc \
    "https://downloads.apache.org/guacamole/${GUAC_VERSION}/binary/guacamole-${GUAC_VERSION}.war.asc"
curl -fsSL -o /tmp/guac-KEYS "https://downloads.apache.org/guacamole/KEYS"
export GNUPGHOME="$(mktemp -d)"; gpg --quiet --import /tmp/guac-KEYS
gpg --status-fd 1 --verify /tmp/guacamole.war.asc /tmp/guacamole.war 2>/dev/null \
    | grep -q "VALIDSIG ${GUAC_GPG_FP}" \
    || { echo "FATAL: guacamole.war GPG verify failed / not signed by pinned key ${GUAC_GPG_FP}" >&2; exit 1; }
echo "guacamole.war: GOOD signature from pinned Apache key ${GUAC_GPG_FP}"
rm -rf "$GNUPGHOME"; unset GNUPGHOME
javax2jakarta /tmp/guacamole.war /var/lib/tomcat/webapps/guacamole.war
rm -f /tmp/guacamole.war /tmp/guacamole.war.asc /tmp/guac-KEYS
install -d -m 0750 -o tomcat -g tomcat /etc/guacamole /var/lib/guac-cert
# guacamole.properties is written at first boot by bin/guac-db-provision.sh (the
# authoritative DB-auth/TOTP config incl. the runtime DB password) — not baked here.
# Guacamole fronts GRD's LOOPBACK RDP (127.0.0.1:3389, security=tls). The web
# user-mapping (creds + the GRD TLS params) is written at first boot by
# entrypoint-grd (it needs the runtime RDP_PW/GUAC_PW). TLS :8443 connector:
sed -i 's|</Service>|    <Connector port="8443" protocol="org.apache.coyote.http11.Http11NioProtocol" SSLEnabled="true" maxThreads="50" scheme="https" secure="true">\n        <SSLHostConfig><Certificate certificateKeystoreFile="/var/lib/guac-cert/keystore.p12" certificateKeystorePassword="container-local" type="RSA"/></SSLHostConfig>\n    </Connector>\n  </Service>|' /etc/tomcat/server.xml

# ---- guacamole-auth-ban: brute-force lockout on the PUBLIC :8443 door --------
# A SECOND class-(c) Apache Guacamole artifact (same pinned key), GPG-verified
# fail-closed: bans a source IP after repeated failed logins. Backend-INDEPENDENT
# (in-memory) — bans a source IP after repeated failed logins. GUACAMOLE_HOME is set
# to /etc/guacamole on grd's stock tomcat.service via the tomcat.service.d drop-in
# below (NOT JAVA_OPTS — that's the xrdp entrypoint's path), so the extension JARs in
# /etc/guacamole/extensions/ + guacamole.properties actually load. This is what makes
# a single strong GUAC_PW a
# defensible PUBLIC door (a password alone, with no lockout, is brute-forceable).
curl -fsSL -o /tmp/guac-ban.tgz \
    "https://downloads.apache.org/guacamole/${GUAC_VERSION}/binary/guacamole-auth-ban-${GUAC_VERSION}.tar.gz"
curl -fsSL -o /tmp/guac-ban.tgz.asc \
    "https://downloads.apache.org/guacamole/${GUAC_VERSION}/binary/guacamole-auth-ban-${GUAC_VERSION}.tar.gz.asc"
curl -fsSL -o /tmp/guac-KEYS "https://downloads.apache.org/guacamole/KEYS"
export GNUPGHOME="$(mktemp -d)"; gpg --quiet --import /tmp/guac-KEYS
gpg --status-fd 1 --verify /tmp/guac-ban.tgz.asc /tmp/guac-ban.tgz 2>/dev/null \
    | grep -q "VALIDSIG ${GUAC_GPG_FP}" \
    || { echo "FATAL: guacamole-auth-ban GPG verify failed / not signed by pinned key ${GUAC_GPG_FP}" >&2; exit 1; }
echo "guacamole-auth-ban: GOOD signature from pinned Apache key ${GUAC_GPG_FP}"
rm -rf "$GNUPGHOME"; unset GNUPGHOME
install -d -m 0750 -o tomcat -g tomcat /etc/guacamole/extensions
tar -xzf /tmp/guac-ban.tgz -C /tmp
install -m 0640 -o tomcat -g tomcat \
    "/tmp/guacamole-auth-ban-${GUAC_VERSION}/guacamole-auth-ban-${GUAC_VERSION}.jar" \
    "/etc/guacamole/extensions/guacamole-auth-ban-${GUAC_VERSION}.jar"
rm -rf /tmp/guac-ban.tgz /tmp/guac-ban.tgz.asc /tmp/guac-KEYS "/tmp/guacamole-auth-ban-${GUAC_VERSION}"
# auth-ban defaults (5 failed attempts / 5 min -> 5-min ban) are sane; tunable via
# ban-max-invalid-attempts / ban-address-duration etc. in guacamole.properties.

# ---- DB-backed auth: guacamole-auth-jdbc (MySQL) + guacamole-auth-totp -------
# Same class-(c) GPG-verify-fail-closed pattern + helper as the xrdp install.sh. TOTP
# 2FA REQUIRES a database; entrypoint-grd.sh provisions it via the SHARED helper
# bin/guac-db-provision.sh (single source of truth for the four must-dos).
guac_verify_tarball() {  # <basename.tar.gz> <out.tgz> — fetch + GPG-verify (fail-closed) + extract
    _bn="$1"; _out="$2"
    curl -fsSL -o "$_out"        "https://downloads.apache.org/guacamole/${GUAC_VERSION}/binary/${_bn}"
    curl -fsSL -o "${_out}.asc"  "https://downloads.apache.org/guacamole/${GUAC_VERSION}/binary/${_bn}.asc"
    curl -fsSL -o /tmp/guac-KEYS "https://downloads.apache.org/guacamole/KEYS"
    GNUPGHOME="$(mktemp -d)"; export GNUPGHOME; gpg --quiet --import /tmp/guac-KEYS
    gpg --status-fd 1 --verify "${_out}.asc" "$_out" 2>/dev/null \
        | grep -q "VALIDSIG ${GUAC_GPG_FP}" \
        || { echo "FATAL: ${_bn} GPG verify failed / not signed by pinned key ${GUAC_GPG_FP}" >&2; exit 1; }
    echo "${_bn}: GOOD signature from pinned Apache key ${GUAC_GPG_FP}"
    rm -rf "$GNUPGHOME"; unset GNUPGHOME
    tar -xzf "$_out" -C /tmp
    rm -f "$_out" "${_out}.asc" /tmp/guac-KEYS
}
install -d -m 0750 -o tomcat -g tomcat /etc/guacamole/extensions /etc/guacamole/lib
guac_verify_tarball "guacamole-auth-jdbc-${GUAC_VERSION}.tar.gz" /tmp/guac-jdbc.tgz
install -m 0640 -o tomcat -g tomcat \
    "/tmp/guacamole-auth-jdbc-${GUAC_VERSION}/mysql/guacamole-auth-jdbc-mysql-${GUAC_VERSION}.jar" \
    "/etc/guacamole/extensions/guacamole-auth-jdbc-mysql-${GUAC_VERSION}.jar"
install -d -m 0755 /usr/local/share/guacamole-schema
install -m 0644 "/tmp/guacamole-auth-jdbc-${GUAC_VERSION}/mysql/schema/001-create-schema.sql" \
    /usr/local/share/guacamole-schema/001-create-schema.sql   # NEVER 002 (guacadmin backdoor)
rm -rf "/tmp/guacamole-auth-jdbc-${GUAC_VERSION}"
guac_verify_tarball "guacamole-auth-totp-${GUAC_VERSION}.tar.gz" /tmp/guac-totp.tgz
install -m 0640 -o tomcat -g tomcat \
    "/tmp/guacamole-auth-totp-${GUAC_VERSION}/guacamole-auth-totp-${GUAC_VERSION}.jar" \
    "/etc/guacamole/extensions/guacamole-auth-totp-${GUAC_VERSION}.jar"
rm -rf "/tmp/guacamole-auth-totp-${GUAC_VERSION}"
install -m 0640 -o tomcat -g tomcat /usr/lib/java/mariadb-java-client.jar /etc/guacamole/lib/mariadb-java-client.jar
# MariaDB daemon config. Named zz- so it sorts AFTER Fedora's mariadb-server.cnf and
# these settings WIN: loopback ONLY (Principle 7 — 3306 is NEVER published); name
# resolution + query-log + binlog OFF (no password in any log — Principle 5). Socket
# stays the Fedora default /var/lib/mysql/mysql.sock (datadir-local; no /run dir needed).
cat > /etc/my.cnf.d/zz-fedora-desktop.cnf <<'CNF'
[mysqld]
bind-address=127.0.0.1
skip-name-resolve
general-log=0
skip-log-bin
CNF

# MariaDB + the web door. Ordering (drop-ins, not unit edits): the firstboot oneshot
# provisions the DB so it runs After mariadb; Tomcat serves only After provisioning.
# guacd MUST bind the IPv4 loopback to match guacamole.properties' guacd-hostname:
# 127.0.0.1 (set by the SHARED bin/guac-db-provision.sh — do NOT change that; the xrdp
# lineage depends on it). Fedora's stock guacd.service runs `/usr/sbin/guacd -f $OPTS`;
# with $OPTS empty, guacd 1.6.0 defaults to 'localhost' -> ::1 on a dual-stack box, so
# Guacamole's IPv4 dial to 127.0.0.1:4822 is refused. Re-express the xrdp lineage's
# explicit `guacd -b 127.0.0.1` (entrypoint.sh) as a stock-unit drop-in.
install -d -m 0755 /etc/systemd/system/guacd.service.d
cat > /etc/systemd/system/guacd.service.d/10-bind-loopback.conf <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/sbin/guacd -f -b 127.0.0.1
# Self-heal the public-door proxy: stock guacd.service ships no Restart= — a guacd crash kills
# every web login until manual restart. Parity with the xrdp watchdog (and the tomcat F2 drop-in).
Restart=always
RestartSec=5s
EOF
systemctl enable mariadb.service guacd.service tomcat.service
install -d -m 0755 /etc/systemd/system/tomcat.service.d
cat > /etc/systemd/system/tomcat.service.d/10-after-db.conf <<'EOF'
[Unit]
After=mariadb.service fedora-desktop-grd-firstboot.service
# Requires the firstboot oneshot too: a FAILED provisioning (e.g. the guacadmin
# fail-closed exit 1) must BLOCK Tomcat from serving :8443. After= alone would not.
Requires=mariadb.service fedora-desktop-grd-firstboot.service
[Service]
# Point Guacamole at /etc/guacamole. The xrdp lineage sets this via JAVA_OPTS on its
# manual Tomcat launch (entrypoint.sh); grd uses the stock systemd tomcat.service, which
# otherwise defaults GUACAMOLE_HOME to the tomcat user's ~/.guacamole -> Guacamole loads
# NO extensions (jdbc/totp/auth-ban) + NO guacamole.properties -> no auth backend ->
# "An error has occurred" on the web page. Without this the grd web door cannot authenticate.
Environment=GUACAMOLE_HOME=/etc/guacamole
# Stock tomcat.service ships NO Restart= — a JVM crash leaves the SOLE public :8443
# door dead PERMANENTLY (podman --restart=always only acts on container exit, while
# systemd PID1 stays up). The xrdp lineage heals catalina via its watchdog; here
# Restart=always respawns the public door on ANY death (parity with xrdp's "any
# death respawns" for the public door).
Restart=always
RestartSec=5s
EOF

# ---- first-boot config oneshot (users, TLS, per-user GRD, DB-auth) ----------
# entrypoint-grd.sh runs ONCE under systemd; it reads the runtime secrets from the
# bind-mounted /etc/fedora-desktop/secrets.env (run.sh.grd writes it — grd is
# run.sh.grd-only, there is NO grd Quadlet). It provisions core +
# optional USER{1..5}, then per user enables gnome-headless-session@<user> + the
# user's gnome-remote-desktop-headless on a distinct loopback port — see entrypoint-grd.
# Ordered After=gdm.service so the session FACTORY is up before it spawns sessions.
cat > /etc/systemd/system/fedora-desktop-grd-firstboot.service <<'EOF'
[Unit]
Description=fedora-desktop GRD first-boot config (users, TLS, per-user GRD headless, DB-auth)
After=systemd-user-sessions.service network-online.target mariadb.service gdm.service
Wants=network-online.target gdm.service
Requires=mariadb.service
[Service]
Type=oneshot
RemainAfterExit=yes
# Generous start timeout: provisioning serializes up to 5 users (per-user session-bus wait
# ~40s each) + mariadb first-init + the bounded tailscale retry (~30s) + mariadb-upgrade; the
# 90s systemd default would SIGTERM it mid-provision and tomcat (Requires=) would never serve :8443.
TimeoutStartSec=600
# Secrets reach this oneshot ONLY via the bind-mounted secrets.env (run.sh.grd writes it;
# grd is run.sh.grd-only — there is NO grd Quadlet). The dead /run/.containerenv import was
# removed — it invited the `podman -e` path that leaks secrets to `podman inspect`.
EnvironmentFile=-/etc/fedora-desktop/secrets.env
ExecStart=/usr/local/bin/entrypoint-grd.sh
[Install]
WantedBy=multi-user.target
EOF
systemctl enable fedora-desktop-grd-firstboot.service

# ---- bake the lineage markers (headless GNOME-Wayland) ----------------------
# 0700 root: this dir is the bind-mount point for the runtime secrets.env (RDP_PW
# etc.) — keep it non-traversable so only root (PID 1 / the oneshot) can read it.
install -d -m 0700 /etc/fedora-desktop
printf 'grd\n'           > /etc/fedora-desktop/lineage
printf 'gnome-wayland\n' > /etc/fedora-desktop/xsession

# (machine-id is handled by systemd-machine-id-setup at boot — no dbus-uuidgen here.)
$DNF clean all
rm -rf /var/cache/dnf
# /var/cache/libdnf5 is bind-mounted as the PERSISTENT dnf package cache during throwaway /
# host live-gate builds (Principle 10 / FLEET churn discipline); rmdir of that mountpoint fails
# EBUSY and kills the build. Remove the dir only when it is NOT a mountpoint (the monthly
# --no-cache CI build, where it is a real in-layer dir we want gone to keep the layer small).
mountpoint -q /var/cache/libdnf5 || rm -rf /var/cache/libdnf5
echo ">>> fedora-desktop-grd installed: GNOME-50 Wayland + GRD(RDP; VNC follow-up) + Guacamole web + apps (systemd-PID-1, headless)"
