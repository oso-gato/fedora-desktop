#!/usr/bin/env bash
# guac-db-provision.sh — SINGLE SOURCE OF TRUTH for fedora-desktop's Guacamole
# DB-backed auth + TOTP provisioning. SOURCED (not exec'd) by ALL THREE lineage
# entrypoints — xrdp (supervised-bash) and grd (systemd) — AFTER MariaDB is
# reachable. Keeping it in one file is deliberate: the four TOTP/DB must-dos must
# hold byte-identically across lineages and must never drift.
#   #1  load ONLY 001 (NEVER the guacadmin/guacadmin 002 backdoor); delete any
#       guacadmin entity and FAIL CLOSED if one survives.
#   #2  the file-auth provider bypasses TOTP — remove user-mapping.xml (the caller
#       also does; re-asserted here).
#   #3  connections are parented under a NON-NULL group so UNIQUE(name,parent_id)
#       dedupes on re-provision; fleet grants are DELETE-then-INSERT so a downgrade
#       (both->dev) actually revokes the stale tile.
#   #4  the user UPSERT touches ONLY password fields (+ re-enable) — NEVER
#       guacamole_user_attribute — so the guac-totp-key-* enrollment seed survives.
#
# All password HASHING happens IN SQL (UNHEX(SHA2(CONCAT(pw,HEX(salt)),256)) ==
# Guacamole's salted-SHA-256, verified byte-for-byte); the shell NEVER hashes. Every
# dynamic value is hex-encoded -> SQL-injection-safe and byte-exact (passwords,
# multi-line ssh keys).
#
# Caller PRECONDITIONS (set/defined before calling guac_db_provision):
#   MYSQL_ROOT()       fn: OS-root -> DB-root client (e.g. `mariadb --socket=$DBSOCK`)
#   GUAC_PW, RDP_PW    core's web-login password + core's RDP-connection password
#   USER{1..5}_NAME/_PW/_ACCESS  optional extra users (xrdp multi-user; unset on
#                                grd => core-only, handled gracefully)
#   FLEET_SSH          optional ';'-list "label host [port] [user]" (may be empty)
#   RDP_DISABLE_AUDIO  1 = disable web-door audio (default), 0 = enable
#   RDP_SECURITY       desktop RDP security mode: 'any' (xrdp) | 'tls' (grd)
#   RDP_PIN_BPP        1 = pin color-depth 24 (xrdp cross-device resume) | 0 = no
# Schema is stashed at $GUAC_SCHEMA_001 by install*.sh.
GUAC_SCHEMA_001="${GUAC_SCHEMA_001:-/usr/local/share/guacamole-schema/001-create-schema.sql}"

# ---- SQL value encoders (injection-safe; round-trip arbitrary bytes) -----------
sqlhex() { printf '%s' "${1:-}" | od -An -v -tx1 | tr -d ' \n'; }
sqlstr() { printf "CONVERT(UNHEX('%s') USING utf8)" "$(sqlhex "$1")"; }
emit_param_sql() {  # <connection-id-expr> <param_name(literal)> <value>
    printf "INSERT INTO guacamole_connection_parameter (connection_id, parameter_name, parameter_value)\n  VALUES (%s, '%s', %s)\n  ON DUPLICATE KEY UPDATE parameter_value=VALUES(parameter_value);\n" "$1" "$2" "$(sqlstr "$3")"
}
# One non-null-parented org group: every connection lives UNDER it so
# UNIQUE(connection_name,parent_id) dedupes on re-provision (a NULL parent is treated
# as DISTINCT -> a duplicate tile each boot). The group's own parent is NULL, so it
# needs a SELECT-guard, not INSERT IGNORE.  (must-do #3)
emit_group_sql() {
cat <<'SQL'
INSERT INTO guacamole_connection_group (parent_id, connection_group_name, type)
  SELECT NULL, 'fleet', 'ORGANIZATIONAL' FROM DUAL
  WHERE NOT EXISTS (SELECT 1 FROM guacamole_connection_group
                    WHERE connection_group_name='fleet' AND parent_id IS NULL);
SET @grp = (SELECT connection_group_id FROM guacamole_connection_group
            WHERE connection_group_name='fleet' AND parent_id IS NULL);
SQL
}
# Shared fleet SSH connections — created ONCE, granted per-user below.
emit_fleet_connections_sql() {
    [ -n "${FLEET_SSH:-}" ] || return 0
    _key=""; [ -r /etc/fedora-desktop/fleet_ssh_key ] && _key="$(cat /etc/fedora-desktop/fleet_ssh_key)"
    printf '%s\n' "$FLEET_SSH" | tr ';' '\n' | while IFS=' ' read -r f_label f_host f_port f_user _rest; do
        [ -n "$f_label" ] && [ -n "$f_host" ] || continue
        f_port="${f_port:-22}"; case "$f_port" in (*[!0-9]*|'') f_port=22 ;; esac
        printf "INSERT INTO guacamole_connection (connection_name, parent_id, protocol)\n  VALUES (%s, @grp, 'ssh') ON DUPLICATE KEY UPDATE protocol=VALUES(protocol);\n" "$(sqlstr "ssh-$f_label")"
        printf "SET @cid = (SELECT connection_id FROM guacamole_connection WHERE connection_name=%s AND parent_id=@grp);\n" "$(sqlstr "ssh-$f_label")"
        emit_param_sql '@cid' hostname "$f_host"
        emit_param_sql '@cid' port "$f_port"
        emit_param_sql '@cid' username "${f_user:-core}"
        [ -n "$_key" ] && emit_param_sql '@cid' private-key "$_key"
    done || true   # the pipe's exit = the while's last cmd (a false test when no fleet
    return 0       # key is mounted); `|| true` stops set -e firing before this return.
}
# One identity: entity + user (UPSERT touches ONLY password fields + re-enable; NEVER
# guacamole_user_attribute => TOTP seed kept, must-do #4) + own RDP desktop + READ
# grants + fleet-grant RECONCILIATION (DELETE-then-INSERT, must-do #3).
emit_user_sql() {  # <username> <web_pw> <rdp_user> <rdp_pw> <access> <desktop_conn_name>
    _u="$1"; _wpw="$2"; _ru="$3"; _rpw="$4"; _acc="$5"; _conn="$6"
cat <<SQL
INSERT IGNORE INTO guacamole_entity (name, type) VALUES ($(sqlstr "$_u"), 'USER');
SET @eid = (SELECT entity_id FROM guacamole_entity WHERE name=$(sqlstr "$_u") AND type='USER');
SET @pw  = UNHEX('$(sqlhex "$_wpw")');
SET @salt = UNHEX(SHA2(CONCAT(UUID(), RAND(), @pw), 256));
INSERT INTO guacamole_user (entity_id, password_hash, password_salt, password_date, disabled)
  VALUES (@eid, UNHEX(SHA2(CONCAT(@pw, HEX(@salt)), 256)), @salt, NOW(), 0)
  ON DUPLICATE KEY UPDATE password_hash=VALUES(password_hash),
                          password_salt=VALUES(password_salt),
                          password_date=VALUES(password_date), disabled=0;
INSERT INTO guacamole_connection (connection_name, parent_id, protocol)
  VALUES ($(sqlstr "$_conn"), @grp, 'rdp') ON DUPLICATE KEY UPDATE protocol=VALUES(protocol);
SET @cid = (SELECT connection_id FROM guacamole_connection WHERE connection_name=$(sqlstr "$_conn") AND parent_id=@grp);
SQL
    emit_param_sql '@cid' hostname 127.0.0.1
    emit_param_sql '@cid' port 3389
    emit_param_sql '@cid' username "$_ru"
    emit_param_sql '@cid' password "$_rpw"
    emit_param_sql '@cid' ignore-cert true
    emit_param_sql '@cid' security "${RDP_SECURITY:-any}"
    emit_param_sql '@cid' resize-method display-update
    [ "${RDP_PIN_BPP:-1}" = 1 ] && emit_param_sql '@cid' color-depth 24   # 24bpp == xrdp <User,BitPerPixel> session key -> cross-device RESUME
    [ "${RDP_DISABLE_AUDIO:-1}" = 1 ] && emit_param_sql '@cid' disable-audio true
cat <<'SQL'
INSERT IGNORE INTO guacamole_connection_permission (entity_id, connection_id, permission) VALUES (@eid, @cid, 'READ');
INSERT IGNORE INTO guacamole_connection_group_permission (entity_id, connection_group_id, permission) VALUES (@eid, @grp, 'READ');
DELETE cp FROM guacamole_connection_permission cp JOIN guacamole_connection c ON cp.connection_id=c.connection_id
  WHERE cp.entity_id=@eid AND c.parent_id=@grp AND c.protocol='ssh';
SQL
    if [ "$_acc" != none ] && [ -n "${FLEET_SSH:-}" ]; then
        printf '%s\n' "$FLEET_SSH" | tr ';' '\n' | while IFS=' ' read -r f_label f_host f_port f_user _rest; do
            [ -n "$f_label" ] && [ -n "$f_host" ] || continue
            case "$_acc" in
                all) : ;;
                both) case "$f_label" in *dev*|*vps*|*host*) : ;; *) continue ;; esac ;;
                dev)  case "$f_label" in *dev*) : ;; *) continue ;; esac ;;
                host) case "$f_label" in *vps*|*host*) : ;; *) continue ;; esac ;;
                *) continue ;;
            esac
            printf "INSERT IGNORE INTO guacamole_connection_permission (entity_id, connection_id, permission)\n  SELECT @eid, connection_id, 'READ' FROM guacamole_connection WHERE connection_name=%s AND parent_id=@grp;\n" "$(sqlstr "ssh-$f_label")"
        done || true   # pipe exit = while's last cmd (may be a non-matching `continue`)
    fi
    return 0           # `|| true` + return 0 so set -e never aborts the caller here
}
# Retire users no longer in spin-up: DISABLE (never DELETE) so their TOTP enrollment +
# data survive (a DELETE would CASCADE-wipe the guac-totp-key-* attribute -> must-do #4).
emit_disable_absent_sql() {  # args: every current username (core + provisioned)
    _inlist=""
    for _n in "$@"; do _inlist="${_inlist:+$_inlist, }$(sqlstr "$_n")"; done
cat <<SQL
UPDATE guacamole_user u JOIN guacamole_entity e ON u.entity_id=e.entity_id
  SET u.disabled=1 WHERE e.type='USER' AND e.name NOT IN (${_inlist});
SQL
}

# ============================================================================
# guac_db_provision — the lineage-independent provisioning transaction.
# ============================================================================
guac_db_provision() {
    # must-do #2 (belt-and-suspenders): a surviving user-mapping.xml is a live
    # no-2FA bypass (file-auth ignores TOTP). The caller removes it; assert here too.
    rm -f /etc/guacamole/user-mapping.xml

    # Fail closed on an empty core credential: do NOT let the crypto layer silently
    # depend on spin-up's >=20-char floor. (Empty -> UNHEX('') hashes over just the
    # salt, a weak/known verifier.) Per-USERn empties are already skipped in the loop.
    [ -n "${GUAC_PW:-}" ] && [ -n "${RDP_PW:-}" ] \
        || { echo "FATAL: empty GUAC_PW/RDP_PW — refusing to provision the web door" >&2; exit 1; }

    # DB credential: loopback-only, generated-and-persisted (never user-facing). It
    # gates ONLY loopback DB access; the OS + the loopback bind are the real boundary.
    local DB_PW_FILE=/var/lib/mysql/.guac_db_pw DB_PW
    if [ ! -s "$DB_PW_FILE" ]; then
        ( umask 077; openssl rand -base64 33 | tr -d '/+=\n' > "$DB_PW_FILE" )
        chown mysql:mysql "$DB_PW_FILE" 2>/dev/null || true; chmod 600 "$DB_PW_FILE"
    fi
    DB_PW="$(cat "$DB_PW_FILE")"   # alphanumeric only (tr stripped /+=) -> safe to interpolate

    # DB + loopback user + schema. MUST-DO #1: load ONLY 001 (schema); NEVER 002.
    MYSQL_ROOT <<SQL
CREATE DATABASE IF NOT EXISTS guacamole_db CHARACTER SET utf8 COLLATE utf8_general_ci;
CREATE USER IF NOT EXISTS 'guacamole'@'localhost' IDENTIFIED BY '${DB_PW}';
ALTER USER 'guacamole'@'localhost' IDENTIFIED BY '${DB_PW}';
GRANT SELECT,INSERT,UPDATE,DELETE ON guacamole_db.* TO 'guacamole'@'localhost';
FLUSH PRIVILEGES;
SQL
    local _have
    _have="$(MYSQL_ROOT -N -B -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='guacamole_db' AND table_name='guacamole_user';" 2>/dev/null || echo 0)"
    if [ "${_have:-0}" = 0 ]; then
        echo "[db] loading Guacamole schema 001 (admin-user 002 intentionally NOT loaded)"
        MYSQL_ROOT guacamole_db < "$GUAC_SCHEMA_001"
    fi
    # MUST-DO #1 (belt-and-suspenders): delete any guacadmin entity, then FAIL CLOSED
    # if one survives — never serve :8443 with the default backdoor present.
    MYSQL_ROOT guacamole_db -e "DELETE FROM guacamole_entity WHERE name='guacadmin' AND type='USER';"
    if [ "$(MYSQL_ROOT -N -B guacamole_db -e "SELECT COUNT(*) FROM guacamole_entity WHERE name='guacadmin';" 2>/dev/null || echo 1)" != 0 ]; then
        echo "FATAL: guacadmin backdoor present after delete — refusing to start the web door" >&2; exit 1
    fi

    # Build the current username set OUTSIDE the provisioning subshell.
    local CURRENT_USERS="core" _w _wn _wp _wa
    for _w in 1 2 3 4 5; do
        eval "_wn=\${USER${_w}_NAME:-}; _wp=\${USER${_w}_PW:-}"
        [ -n "$_wn" ] && [ -n "$_wp" ] && CURRENT_USERS="$CURRENT_USERS $_wn"
    done
    # The WHOLE provisioning runs in ONE DB session so @grp/@eid/@cid persist.
    # core: web login = GUAC_PW (admin: ALL fleet tiles); RDP connection = core / RDP_PW.
    {
        emit_group_sql
        emit_fleet_connections_sql
        emit_user_sql core "${GUAC_PW}" core "${RDP_PW}" all "fedora-desktop"
        for _w in 1 2 3 4 5; do
            eval "_wn=\${USER${_w}_NAME:-}; _wp=\${USER${_w}_PW:-}; _wa=\${USER${_w}_ACCESS:-none}"
            [ -n "$_wn" ] && [ -n "$_wp" ] || continue
            emit_user_sql "$_wn" "$_wp" "$_wn" "$_wp" "$_wa" "desktop-$_wn"
        done
        emit_disable_absent_sql $CURRENT_USERS
    } | MYSQL_ROOT guacamole_db || { echo "FATAL: Guacamole DB provisioning failed" >&2; exit 1; }
    echo "[db] provisioned web logins for: ${CURRENT_USERS}"

    # guacamole.properties: guacd + auth-ban + JDBC/TOTP wiring. The DB password is a
    # RUNTIME secret (Principle 5), so the full properties are written HERE, not baked.
    cat > /etc/guacamole/guacamole.properties <<PROPS
guacd-hostname: 127.0.0.1
guacd-port: 4822
ban-max-invalid-attempts: 3
ban-address-duration: 900
mysql-hostname: 127.0.0.1
mysql-port: 3306
mysql-database: guacamole_db
mysql-username: guacamole
mysql-password: ${DB_PW}
mysql-driver: mariadb
PROPS
    chown tomcat:tomcat /etc/guacamole/guacamole.properties
    chmod 640 /etc/guacamole/guacamole.properties
    unset DB_PW
    return 0
}
