#!/bin/bash
# OpenResty Manager on Railway.
#  1. all state on the volume at /data (database, JWT key, certificates, generated proxy configs)
#  2. oms starts on 127.0.0.1:34567 (HTTPS, self-signed) and is not reachable from outside until step 3 is done
#  3. the default admin login is replaced with $ADMIN_PASSWORD
#  4. an HTTP front proxy starts on Railway's PORT
set -uo pipefail

log() { echo "[railway-entrypoint] $*"; }
die() { log "ERROR: $*"; exit 1; }

PORT="${PORT:-8080}"
VOL="${DATA_DIR:-/data}"
API="https://127.0.0.1:34567/api/v1"
ADMIN_USER="${ADMIN_USERNAME:-admin}"

[ -n "${ADMIN_PASSWORD:-}" ] || die "ADMIN_PASSWORD is not set"
case "$ADMIN_PASSWORD" in *\"*|*\\*|*[[:space:]]*) die "ADMIN_PASSWORD must not contain quotes, backslashes or whitespace" ;; esac
case "$PORT" in 80|443|34567) die "PORT $PORT collides with OpenResty Manager's own listeners" ;; esac

# --- 1. persistence -------------------------------------------------------------------------------
mkdir -p "$VOL" || die "cannot create $VOL"
probe="$VOL/.write-test.$$"
( echo ok > "$probe" ) 2>/dev/null || die "$VOL is not writable (owner=$(stat -c %u:%g "$VOL"))"
rm -f "$probe"
log "volume $VOL writable, owner=$(stat -c %u:%g "$VOL")"

persist() { # persist <image path> <name on volume>
    local src="$1" dst="$VOL/$2"
    if [ -L "$src" ]; then return 0; fi
    if [ ! -e "$dst" ]; then
        if [ -d "$src" ]; then cp -a "$src" "$dst"; else mkdir -p "$dst"; fi
    fi
    rm -rf "$src"
    ln -s "$dst" "$src"
}
persist /opt/om/data data
persist /opt/om/nginx/conf nginx-conf
rm -f /opt/om/data/*.pid 2>/dev/null || true

# --- 2. start oms ---------------------------------------------------------------------------------
cd /opt/om
/opt/om/oms &
OMS_PID=$!
cleanup() { kill "$OMS_PID" "${FRONT_PID:-}" 2>/dev/null; wait 2>/dev/null; }
trap 'cleanup; exit 0' TERM INT

for i in $(seq 1 120); do
    curl -sk -m 2 -o /dev/null "https://127.0.0.1:34567/" && break
    kill -0 "$OMS_PID" 2>/dev/null || die "oms exited during startup"
    sleep 1
done
curl -sk -m 2 -o /dev/null "https://127.0.0.1:34567/" || die "oms did not answer on 34567 within 120s"
log "oms up"

# --- 3. admin password ----------------------------------------------------------------------------
login() { # login <password> -> prints token, empty on failure
    curl -sk -m 10 -X POST "$API/login" -H 'content-type: application/json' \
        -d "{\"username\":\"$ADMIN_USER\",\"password\":\"$1\"}" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p'
}
TOKEN="$(login "$ADMIN_PASSWORD")"
if [ -n "$TOKEN" ]; then
    log "admin password already set"
else
    TOKEN="$(login '#Passw0rd')"
    if [ -z "$TOKEN" ]; then
        log "WARNING: neither ADMIN_PASSWORD nor the upstream default logs in; password was changed in the UI, leaving it"
    else
        users="$(curl -sk -m 10 "$API/admin/users" -H "Authorization: Bearer $TOKEN")"
        uid="$(echo "$users" | sed -n "s/.*\"id\":\([0-9]*\)[^}]*\"username\":\"$ADMIN_USER\".*/\1/p" | head -1)"
        [ -n "$uid" ] || uid="$(echo "$users" | sed -n 's/.*"id":\([0-9]*\).*/\1/p' | head -1)"
        [ -n "$uid" ] || die "could not find the admin user id in: $users"
        code="$(curl -sk -m 10 -o /tmp/om-pw.out -w '%{http_code}' -X PUT "$API/admin/users" \
            -H "Authorization: Bearer $TOKEN" -H 'content-type: application/json' \
            -d "{\"id\":$uid,\"username\":\"$ADMIN_USER\",\"password\":\"$ADMIN_PASSWORD\",\"confirm_password\":\"$ADMIN_PASSWORD\",\"role\":0,\"email\":\"\",\"enable_otp\":false,\"otp\":\"\",\"otp_url\":\"\"}")"
        [ "$code" = 200 ] || die "password update returned HTTP $code: $(cat /tmp/om-pw.out)"
        [ -n "$(login "$ADMIN_PASSWORD")" ] || die "password updated but login with ADMIN_PASSWORD still fails: $(cat /tmp/om-pw.out)"
        log "admin password replaced"
    fi
fi

# --- 4. front proxy -------------------------------------------------------------------------------
mkdir -p /tmp/om-front/logs
PORT="$PORT" envsubst '${PORT}' < /etc/om-front.conf.template > /tmp/om-front/nginx.conf
/usr/local/openresty/nginx/sbin/nginx -t -c /tmp/om-front/nginx.conf -p /tmp/om-front/ || die "front proxy config invalid"
/usr/local/openresty/nginx/sbin/nginx -c /tmp/om-front/nginx.conf -p /tmp/om-front/ &
FRONT_PID=$!
log "front proxy listening on :$PORT"

wait -n "$OMS_PID" "$FRONT_PID"
log "a child process exited; stopping"
cleanup
exit 1
