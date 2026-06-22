# fedora-desktop — fedora-dev's headless harness (nested rootless podman + a
# daily-rebuilt claudebox + key-only sshd/fail2ban/rsyslog + tailscale, NO
# systemd inside) WITH an XFCE remote-desktop layered on (lifted from the
# fedora-xrdp recipe). Purpose: operate Arthur's Obsidian vault + LLM wiki, plus
# maintainer dev.
#
# Base image rebuilt MONTHLY by CI (15th, --no-cache); the in-container claudebox
# rebuilds DAILY from Anthropic's `latest` channel (claude-code is NOT baked into
# this base — it lives in the claudebox; see distrobox.ini).
#
# All packages from official sources only (BUILD PRINCIPLE 2): Fedora repos +
# Tailscale's dnf repo (harness); Microsoft (VS Code) + 1Password dnf repos,
# Apache release artifacts (guacamole.war + jakartaee-migration), the rclone
# developer rpm, and the Obsidian developer AppImage (sha256-logged) for the
# desktop. No passwords/keys/secrets in any layer (PRINCIPLE 5): RDP_PW / GUAC_PW
# (required) + RFB_PW / TS_AUTHKEY (optional) enter only at runtime.
ARG FEDORA_VERSION=44
FROM registry.fedoraproject.org/fedora:${FEDORA_VERSION}

# Pinned Apache artifact version (PRINCIPLE 6 — bump here only, after a rule-4
# fact-check). Verified current 2026-06-21: Guacamole 1.6.0. (rclone +
# jakartaee-migration are now Fedora class-(a) packages — no pin needed.)
ARG GUAC_VERSION=1.6.0

# Apache Guacamole release-signing key fingerprint (Michael Jumper CODE SIGNING
# KEY, mjumper@apache.org). The guacamole.war web client (the lone class-(c)
# artifact, and only on the guacamole web-gateway) is GPG-verified against this
# PINNED key before use — PRINCIPLE 2(c) mandates the publisher's signature where
# one exists (supersedes a bare sha256). Re-confirm on a GUAC_VERSION bump: a new
# release may be signed by a different Apache committer key.
ARG GUAC_GPG_FP=F467E54ACC52F1D2778826865B2977AEE5E4518F

# Desktop-environment selector. xrdp is XFCE-ONLY now: `xfce` is the sole accepted
# value (install.sh's DESKTOP_ENV case rejects anything else). LXQt/KDE/MATE were
# dropped (see CLAUDE.md "Desktop note"). The ARG is retained so the build/case stay
# extensible, but the only valid build is the default.
ARG DESKTOP_ENV=xfce

# Web gateway: Apache Guacamole ONLY (the SOLE public :8443 browser door, fronting
# the same Xorg :10 session). noVNC was removed fleet-wide — the web door is a
# PUBLIC (non-tailnet) door and noVNC's 8-char VNC VncAuth is unacceptable there;
# Guacamole authenticates with a strong password + brute-force lockout (auth-ban).
ENV LANG=en_US.UTF-8

COPY install.sh /tmp/install.sh
RUN GUAC_VERSION="${GUAC_VERSION}" GUAC_GPG_FP="${GUAC_GPG_FP}" \
    DESKTOP_ENV="${DESKTOP_ENV}" \
    bash /tmp/install.sh && rm /tmp/install.sh

COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint.sh

# Box assembly seed — used by entrypoint on FIRST BOOT to seed the live git
# clone at /home/core/.local/share/fedora-dev/ if GitHub is unreachable. Once
# the live clone exists, this baked copy is ignored. The box machinery still
# reads this fixed /usr/local/share/fedora-dev/ path (the directory name is kept
# as `fedora-dev` even though this repo is `fedora-desktop`).
COPY distrobox.ini \
     claudebox-init.sh \
     box-rebuild.sh \
     claudebox-daily.sh \
     claudebox-assemble.sh \
     README.md \
     CLAUDE.md \
     /usr/local/share/fedora-dev/
COPY policy/ /usr/local/share/fedora-dev/policy/

# Knowledge-work + box helper scripts. bin/claude + bin/claudebox-rebuild are the
# operator wrappers baked onto PATH (managed-settings.json denies runtime writes
# to /usr/local/bin). bin/cloud-sync.sh + bin/vault-gitsync.sh + bin/ingest-
# sandbox.sh are the desktop helpers the entrypoint invokes (cloud-sync,
# vault-gitsync) or the wiki pipeline invokes on-demand (ingest-sandbox); they
# ride in the seed so the first-boot live clone carries them.
# 0750 core:core (not 0755): only the admin `core` may exec the claudebox wrappers —
# non-privileged wiki-worker desktop users (uid 1001/1002) cannot launch claude /
# rebuild the box. (Belt-and-braces: the host podman socket is already 0700 core, so
# these would fail for a worker anyway; this keeps them off the wrappers entirely.)
COPY --chown=core:core --chmod=750 bin/claude bin/claudebox-rebuild /usr/local/bin/
COPY bin/ /usr/local/share/fedora-dev/bin/

# Promotion-gate PreToolUse hook (gate-push.sh) + any other policy hooks. Stamped
# into the claudebox alongside managed-settings.json by claudebox-assemble.sh.
COPY policy/hooks/ /usr/local/share/fedora-dev/policy/hooks/

# Persistent volumes:
#   /home/core         — home volume (vault working copy, tokens, box state, OAuth)
#   /var/lib/tailscale — tailnet identity + ssh host keys
#   /var/lib/guac-cert — the minted Guacamole TLS keystore (persists across recreates)
#   /var/lib/mysql     — the MariaDB datadir: ALL web logins + TOTP enrollment seeds.
#                        Losing it = losing every enrollment (back it up; see README).
VOLUME ["/home/core", "/var/lib/tailscale", "/var/lib/guac-cert", "/var/lib/mysql"]

# EXPOSE is metadata only; the authoritative published ports live in run.sh /
# fedora-desktop.container (PublishPort). The ONLY public-internet doors are the
# Guacamole web (:8443), public key-only ssh (host :4444 -> :22), and public mosh
# (UDP 61001-62000). RDP :3389 and VNC :5900 are TAILNET-ONLY and are deliberately
# NOT published — they are listed here only as image metadata.
EXPOSE 22 8443 3389 5900 61001-62000/udp

# No HEALTHCHECK: podman builds OCI images which silently drop it. Health is
# defined at run time — see run.sh / fedora-desktop.container (--health-cmd curls
# the Guacamole web page).
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
