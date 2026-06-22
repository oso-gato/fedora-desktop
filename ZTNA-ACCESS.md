# Cross-device fleet access — Twingate ZTNA evaluation + the clientless web bastion

**TL;DR — Twingate does NOT solve the iOS problem. Don't migrate.** On iPhone/iPad,
Twingate's client is itself an `NEPacketTunnelProvider` VPN that occupies the *same*
single iOS VPN slot Tailscale uses — verified against Apple's own statement. The real
fix is **clientless**: the public Guacamole web door (already live) reaches the whole
fleet from any device *with no VPN at all*. This repo's `FLEET_SSH` option extends that
door into an explicit fleet bastion. **Tailscale stays** (server-side mesh).

---

## The problem (measured against this, not generic ZTNA praise)

On iPad/iPhone, iOS permits only **one** VPN tunnel active at a time. When Arthur runs a
GFW-bypass VPN or **UniFi Teleport** (WireGuard) to reach outside China / his home, Tailscale
is forced off and he loses tailnet access to the fleet (the VPS host, fedora-dev, fedora-desktop).
The question: can **Twingate** (a "non-VPN" ZTNA) give cross-device access *without* occupying
that slot?

## Verdict: NO — Twingate is a lateral move on mobile (6-agent ultra-verify, adversarially confirmed, all L1)

| Dimension | Finding | Source (tier) |
|---|---|---|
| **iOS VPN slot (decisive)** | iOS allows only ONE `NEPacketTunnelProvider` (Enterprise VPN) connected at a time — *"two Enterprise VPNs cannot co-exist."* Twingate's iOS client **is** one (it "establishes a full VPN tunnel to 127.0.0.1"). iOS has no system-extension escape (macOS-only). So Twingate occupies the **same slot** as Tailscale / Teleport / a GFW VPN → **does not free it.** | Apple DTS, forums/thread/675507 (L1); Twingate macОS/client docs (L1) |
| **Architecture** | Hub-and-spoke **client→connector→resource**, not a Tailscale-style flat mesh. "Any device → all devices" needs a connector per host; host-to-host (dev↔desktop) needs extra headless clients + service accounts. "non-VPN" = split-tunnel ACL — but still a VPN interface. | twingate.com/docs/how-twingate-works, /architecture (L1) |
| **Security posture (Q2)** | CAN reproduce *and strengthen* the private side (per-resource default-deny + device posture; TCP/UDP/ICMP so SSH/RDP/VNC/**Mosh** all work, Mosh may relay). Guacamole stays public by simply not being a Resource. **But:** it does NOT close public ports — the nft `fd_tailnet_guard` DROP must REMAIN (Twingate replaces the *path*, not the firewall); and **keyless Tailscale-SSH identity is lost** (port-gating + key auth replaces credential substitution). | twingate.com/docs/security-policies, /resources (L1) |
| **Principle-2 packaging** | **Downgrade.** The dnf path is non-compliant: Twingate's own installer sets `gpgcheck=0`, the RPM repo publishes no GPG key, and `twingate-connector-x86_64.rpm` is **unsigned** (`rpm -Kv` → SHA256 digests only). *Independently verified here.* The only admissible path is the **weak** class-(c): the `twingate/connector` image pinned by sha256 (no cosign sig / no OCI attestation). Tailscale (class-(b) via pkgs.tailscale.com) is strictly stronger. | packages.twingate.com/rpm (L1); local `rpm -Kv` (L3) |

**Answers to the three questions:**
1. **Replace Tailscale (host+dev+desktop, no VPN)?** No — it can broker device→fleet access, but on iOS it *is* a VPN occupying the slot, and it loses the mesh. Fails the stated "without a VPN" goal on mobile.
2. **Reproduce the hardening?** Mostly yes on *posture* (and stronger per-resource), but it does not close the public ports (firewall must stay) and loses keyless Tailscale-SSH. Partial, with caveats.
3. **Full replacement, any device → all devices?** No — hub-and-spoke, not a mesh; and the iOS slot is not freed.

**Root insight:** *No* client-VPN ZTNA — Twingate, Tailscale, Cloudflare WARP, NetBird — escapes the
iOS single-slot rule, because they all use `NEPacketTunnelProvider`. **Only a clientless path does.**

---

## The real fix (built here): the public web door as a VPN-slot-free fleet bastion

The fleet already has the answer it didn't realise: **the public Guacamole web door on
fedora-desktop (`:8443`) is clientless.** From any device — including an iPhone running a
GFW-bypass VPN or Teleport — Safari → `https://<ip>:8443/guacamole/` → a full Linux desktop +
terminal, **with no VPN profile consumed**. The tailnet stays **server-side** (between fleet hosts);
the user's device never needs it. That already gives full fleet reach via the desktop's terminal.

`FLEET_SSH` (this change) makes it explicit and direct — browser-SSH **tiles** for the other hosts
on the *same* door:

```
            iPhone/iPad on ANY VPN (or none)
                        │  HTTPS, no VPN slot used
                        ▼
        ┌──────────────────────────────────┐
        │  fedora-desktop  PUBLIC :8443      │   strong GUAC_PW + auth-ban + TLS
        │  Guacamole  ──►  [Desktop] RDP→:10 │
        │             ──►  [dev]     SSH ─┐  │
        │             ──►  [vps]     SSH ─┤  │
        └─────────────────────────────────┼──┘
                  guacd over the SERVER-SIDE tailnet
                                          ▼
                          fedora-dev / VPS host (tailnet IPs)
```

**Usage** (off by default — no `FLEET_SSH` ⇒ behaviour unchanged):
```sh
RDP_PW='…' GUAC_PW='…' \
  FLEET_SSH='dev fedora-dev 22 core;vps fedora-bootstrap 22 core' \
  ./run.sh
```
Each entry is `label host [port] [user]` (`;`-separated). Guacamole shows a tile per host.

**Auth for the SSH tiles** — two Principle-5-clean options, no secret baked into any layer:
- **Preferred — keyless Tailscale-SSH:** guacd connects to the host's tailnet IP; tailscaled
  brokers auth by the desktop's tailnet identity (the target must allow it in the tailnet SSH ACL).
  No key on the desktop. Host-key verification is a non-issue: guacd does **no** host-key
  verification by default (Guacamole L1 manual — omitting `host-key`/`ssh_known_hosts` ⇒ no
  verification), so the dynamic tailnet IPs connect with no prompt and no pinned `known_hosts`.
  *(One host-validation item remains: whether guacd's libssh2 completes Tailscale-SSH's "none"-auth
  without Guacamole prompting for a password — if it prompts, use the key fallback below.)*
- **Fallback — runtime key:** `FLEET_SSH_KEY=/path/to/key ./run.sh` bind-mounts a private key to
  `/etc/fedora-desktop/fleet_ssh_key` (read-only, never in an image layer); applied to every tile.

**Packaging:** `libguac-client-ssh` is a **Fedora class-(a)** package — no new source-purity cost.
**Firewall:** unchanged — RDP/VNC/native-SSH stay tailnet-only behind the nft guard; only `:8443`
is public, now fronting the whole fleet over the server-side tailnet.

### Security note (for review before merge)
This turns the desktop's public door into a **bastion to the VPS host + dev**. That is a deliberate
expansion of the public door's blast radius — gated by the same strong `GUAC_PW` + `guacamole-auth-ban`
lockout + TLS, and reached only over the server-side tailnet. It is **opt-in** (`FLEET_SSH` unset ⇒
nothing changes). Ratify the bastion model + the SSH-tile auth path before enabling in production.

---

## Complementary native-access path (no build — your config)

For native RDP/VNC/SSH on iOS *while Teleport is the active VPN*: **split-tunnel the tailnet inside
the tunnel that already holds the slot.** Route the tailnet CGNAT range `100.64.0.0/10` (+ the fleet's
MagicDNS) through UniFi Teleport / the WireGuard config, e.g. via a **Tailscale subnet router** at home
advertising the fleet. Then the one active VPN also carries fleet routes — zero new vendor, keeps
Tailscale's mesh + class-(b) packaging. (Works where you control the tunnel's `AllowedIPs` — i.e.
Teleport/home, not an arbitrary commercial GFW VPN; for those, the clientless web bastion above is the
universal answer.)

## What stays
- **Tailscale** — the server-side fleet mesh (class-(b), pkgs.tailscale.com). Not replaced.
- The **nft `fd_tailnet_guard`** — RDP/VNC/native-SSH/Mosh remain tailnet-only.
- **No Twingate** is integrated — rejected for the stated purpose (does not free the iOS slot;
  Principle-2 downgrade).
