#!/usr/bin/env bash
# ============================================================================
# guac-fleet-provision-spike.sh — HOST-VALIDATION spike for the Guacamole DB
# provisioning + the SSH-FLEET tile/grant matrix (the spikeable half of the
# SSH-fleet validation; the runbook's "guac-db SQL dry-check").
# ============================================================================
# Runs the REAL bin/guac-db-provision.sh against a throwaway MariaDB loaded with the
# REAL Guacamole schema (guacamole-auth-jdbc 001-create-schema.sql — its
# UNIQUE(connection_name,parent_id) constraint is load-bearing for the dedup/reconcile
# logic, so the schema can NOT be faked), then ASSERTS:
#   S1  per-user fleet tiles match the access matrix:
#         core(all) -> ALL tiles · none -> NONE · dev -> ssh-dev · host -> ssh-vps/host
#         · both -> ssh-dev + ssh-vps/host
#   S2  a both->dev DOWNGRADE actually REVOKES the stale tile (the DELETE-then-INSERT
#       grant reconciliation, guac-db-provision must-do #3) — the highest-value check.
#   S3  (informational) the grant labels are SUBSTRING-matched: a 'devops'/'devbox' tile
#       is granted to a 'dev' user. A known sharp edge — use canonical dev/vps labels.
#
# This proves the TILES + GRANTS are built correctly. It does NOT and CAN NOT prove the
# real door: a Guacamole tile opening an actual SSH shell on the dev box / VPS OVER
# TAILSCALE is REAL-DEPLOY-ONLY (no tailnet / no Tomcat / no fleet hosts in a throwaway).
#
# SAFETY: throwaway image + container; MariaDB loopback-only inside the container; no
# $HOME/vault mount; torn down on exit. Run from the REPO ROOT (it COPYs bin/guac-db-
# provision.sh from the build context).
# ============================================================================
set -uo pipefail

FED="${FED:-44}"
GUAC_VERSION="${GUAC_VERSION:-1.6.0}"               # schema source (matches Containerfile ARG)
IMG="${IMG:-localhost/guac-fleet-spike:f${FED}}"
CT="guac-fleet-spike"
KEEP="${KEEP:-0}"
log(){  printf '\033[1;36m[guac-fleet]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[guac-fleet] WARN:\033[0m %s\n' "$*" >&2; }
err(){  printf '\033[1;31m[guac-fleet] ERR:\033[0m %s\n' "$*" >&2; }
cleanup(){ [ "$KEEP" = 1 ] || podman rm -f "$CT" >/dev/null 2>&1; [ "$KEEP" = 1 ] && warn "KEEP=1 — '$CT' left up (podman rm -f $CT)"; }
trap cleanup EXIT
command -v podman >/dev/null || { err "podman not found — run on the host."; exit 2; }
[ -r bin/guac-db-provision.sh ] || { err "run from the repo root (bin/guac-db-provision.sh not found in build context)."; exit 2; }

# ---- image: MariaDB + the real Guacamole schema + the repo's provision helper ----
build_image(){
  podman image exists "$IMG" && { log "image $IMG exists"; return 0; }
  log "building $IMG (mariadb + guacamole-auth-jdbc ${GUAC_VERSION} schema; ~1-2 min)…"
  local cf pol rc; cf="$(mktemp)"; pol="$(mktemp)"
  printf '%s' '{"default":[{"type":"insecureAcceptAnything"}]}' > "$pol"
  cat > "$cf" <<EOF
FROM registry.fedoraproject.org/fedora:${FED}
RUN dnf -y --setopt=install_weak_deps=False install \
        mariadb-server mariadb \
        curl tar gzip shadow-utils util-linux procps-ng openssl \
    && dnf clean all
# The real Guacamole MySQL schema (001 only — NEVER the 002 guacadmin backdoor), fetched
# over TLS from Apache's own archive (this is a throwaway TEST rig, not a shipped artifact;
# the build records the sha256). install.sh ships the GPG-verified copy in production.
RUN curl -fsSL "https://archive.apache.org/dist/guacamole/${GUAC_VERSION}/binary/guacamole-auth-jdbc-${GUAC_VERSION}.tar.gz" -o /tmp/jdbc.tgz \
 && sha256sum /tmp/jdbc.tgz \
 && tar -xzf /tmp/jdbc.tgz -C /tmp \
 && install -d -m0755 /usr/local/share/guacamole-schema \
 && install -m0644 "/tmp/guacamole-auth-jdbc-${GUAC_VERSION}/mysql/schema/001-create-schema.sql" \
        /usr/local/share/guacamole-schema/001-create-schema.sql \
 && rm -rf /tmp/jdbc.tgz "/tmp/guacamole-auth-jdbc-${GUAC_VERSION}"
# A 'tomcat' user so guac_db_provision's guacamole.properties chown succeeds (no Tomcat here).
RUN useradd -r -s /sbin/nologin tomcat 2>/dev/null || true ; install -d -m0755 /etc/guacamole
COPY bin/guac-db-provision.sh /usr/local/share/fedora-dev/bin/guac-db-provision.sh
ENTRYPOINT ["sleep","infinity"]
EOF
  podman build --signature-policy="$pol" -t "$IMG" -f "$cf" . 2>&1 | tee /tmp/guac-fleet-build.log; rc=${PIPESTATUS[0]}
  rm -f "$cf" "$pol"
  { [ "$rc" = 0 ] && podman image exists "$IMG"; } || { err "build FAILED (rc=$rc) — see /tmp/guac-fleet-build.log (network? host policy.json?)"; return 1; }
  log "image built."
}

build_image || { err "ABORT: image did not build."; exit 3; }
podman rm -f "$CT" >/dev/null 2>&1
podman run -d --name "$CT" --hostname "$CT" --security-opt label=disable "$IMG" >/dev/null \
    || { err "container failed to start"; exit 1; }

# ---- the test runner: start MariaDB, run guac-db-provision, ASSERT the grant matrix ----
# (fed to the container over stdin; its exit code is the spike verdict.)
podman exec -i "$CT" bash -s <<'RUNNER'
set -o pipefail   # NOT -u: bin/guac-db-provision.sh is sourced; don't couple to its -u-safety
# --- MariaDB bring-up (mirrors entrypoint.sh:215-234) ---
install -d -m0755 -o mysql -g mysql /run/mariadb
chown mysql:mysql /var/lib/mysql 2>/dev/null || true; chmod 0750 /var/lib/mysql 2>/dev/null || true
MARIADBD="$(command -v mariadbd || command -v mysqld)"
MADMIN="$(command -v mariadb-admin || command -v mysqladmin)"
MINSTALL="$(command -v mariadb-install-db || command -v mysql_install_db)"
MCLIENT="$(command -v mariadb || command -v mysql)"
DBSOCK=/var/lib/mysql/mysql.sock
MYSQL_ROOT() { "$MCLIENT" --socket="$DBSOCK" "$@"; }
[ -d /var/lib/mysql/mysql ] || "$MINSTALL" --user=mysql --datadir=/var/lib/mysql \
    --auth-root-authentication-method=socket >/var/log/mariadb-install.log 2>&1
runuser -u mysql -- "$MARIADBD" --datadir=/var/lib/mysql --socket="$DBSOCK" \
    --bind-address=127.0.0.1 --port=3306 --skip-name-resolve --general-log=0 --skip-log-bin \
    >/var/log/mariadbd.log 2>&1 &
_ok=0; for _i in $(seq 1 60); do "$MADMIN" --socket="$DBSOCK" ping >/dev/null 2>&1 && { _ok=1; break; }; sleep 1; done
[ "$_ok" = 1 ] || { echo "FATAL: MariaDB did not become ready"; tail -20 /var/log/mariadbd.log; exit 2; }
echo "[db] MariaDB up (loopback)"

# --- preconditions for guac-db-provision.sh ---
export GUAC_SCHEMA_001=/usr/local/share/guacamole-schema/001-create-schema.sql
RDP_SECURITY=any; RDP_PIN_BPP=1; RDP_DISABLE_AUDIO=1
GUAC_PW='web-core-pw-0123456789'; RDP_PW='rdp-core-pw-0123456789'
. /usr/local/share/fedora-dev/bin/guac-db-provision.sh

# list (comma-joined, sorted) the ssh-* fleet tiles a given user has READ on
tiles_for(){ MYSQL_ROOT -N -B guacamole_db -e \
  "SELECT c.connection_name FROM guacamole_connection_permission cp \
   JOIN guacamole_connection c ON cp.connection_id=c.connection_id \
   JOIN guacamole_entity e ON cp.entity_id=e.entity_id \
   WHERE e.name='$1' AND e.type='USER' AND c.protocol='ssh' ORDER BY c.connection_name;" 2>/dev/null \
  | paste -sd, - ; }

P=0; F=0
check(){ local u="$1" exp="$2" got; got="$(tiles_for "$u")"
  if [ "$got" = "$exp" ]; then printf '   PASS  %-7s -> [%s]\n' "$u" "$got"; P=$((P+1))
  else printf '   FAIL  %-7s -> got [%s] want [%s]\n' "$u" "$got" "$exp"; F=$((F+1)); fi; }

echo "=== Scenario 1: initial grant matrix (FLEET_SSH = dev + vps) ==="
export FLEET_SSH="dev fedora-dev 22 core;vps erebus 22 core"
export USER1_NAME=alice USER1_PW='alice-pw-0123456789' USER1_ACCESS=none
export USER2_NAME=bob   USER2_PW='bob-pw-0123456789'   USER2_ACCESS=dev
export USER3_NAME=carol USER3_PW='carol-pw-0123456789' USER3_ACCESS=host
export USER4_NAME=dave  USER4_PW='dave-pw-0123456789'  USER4_ACCESS=both
( guac_db_provision ) >/tmp/prov1.log 2>&1 || { echo "FATAL: provision S1 failed"; tail -30 /tmp/prov1.log; exit 1; }
check core  "ssh-dev,ssh-vps"   # admin: all tiles
check alice ""                   # none: zero fleet tiles
check bob   "ssh-dev"            # dev: dev tile only
check carol "ssh-vps"            # host: vps tile only
check dave  "ssh-dev,ssh-vps"    # both: dev + vps

echo "=== Scenario 2: DOWNGRADE dave both->dev (ssh-vps MUST be revoked) ==="
export USER4_ACCESS=dev
( guac_db_provision ) >/tmp/prov2.log 2>&1 || { echo "FATAL: re-provision S2 failed"; tail -30 /tmp/prov2.log; exit 1; }
check dave  "ssh-dev"            # the stale ssh-vps grant must be GONE (reconciliation)
check alice ""                   # unchanged
check core  "ssh-dev,ssh-vps"    # unchanged

echo "=== Scenario 3 (informational): SUBSTRING grant matching ==="
export FLEET_SSH="dev fedora-dev 22 core;devops 10.0.0.9 22 core;vps erebus 22 core"
export USER2_ACCESS=dev; unset USER3_NAME USER4_NAME   # just bob(dev) against dev+devops+vps
( guac_db_provision ) >/tmp/prov3.log 2>&1 || { echo "FATAL: provision S3 failed"; tail -30 /tmp/prov3.log; exit 1; }
_bob="$(tiles_for bob)"
if [ "$_bob" = "ssh-dev,ssh-devops" ]; then
  echo "   NOTE  bob(dev) -> [$_bob]  — 'devops' matched the *dev* substring (a 'dev' grant"
  echo "         leaks any label containing 'dev'). Known sharp edge: use canonical dev/vps labels."
else
  echo "   bob(dev) -> [$_bob]  (substring behavior differs from expectation — inspect)"
fi

echo "======================================================================"
echo "[guac-fleet] grant-matrix gates: PASS=$P FAIL=$F (S1 5 checks + S2 3 checks)"
if [ "$F" = 0 ]; then
  echo "[guac-fleet] VERDICT: fleet tile/grant provisioning is CORRECT — the access matrix"
  echo "             (none/dev/host/both) and the both->dev downgrade-revoke both hold."
  echo "             (The tile actually opening a shell on dev/VPS OVER TAILSCALE is"
  echo "             real-deploy-only — see GO-LIVE-VALIDATION.md section B.)"
  exit 0
else
  echo "[guac-fleet] VERDICT: NOT green — $F grant-matrix check(s) failed (see above + /tmp/prov*.log)."
  exit 1
fi
RUNNER
rc=$?
[ "$rc" = 0 ] && log "fleet-provisioning spike GREEN." || err "fleet-provisioning spike FAILED (rc=$rc)."
exit "$rc"
