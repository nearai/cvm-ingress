#!/usr/bin/env bash
# Exact-image tests for the admin audit correlation field in the access log.
#
# Cloud API returns a server-generated UUID in the X-Admin-Audit-Request-Id
# response header on every /v1/admin/* response, denials included. The access
# log (log_format main in nginx/nginx.conf) records that UPSTREAM RESPONSE
# header as its last field, admin_audit_request_id="...". With a stub backend
# that issues its own IDs, this asserts against the running image:
#
#   1. a client-supplied X-Admin-Audit-Request-Id / X-Request-Id never becomes
#      the logged ID: the log records the backend's ID (TLS listener over
#      HTTP/1.1 and HTTP/2, and the plain listener);
#   2. a denial (403) records the backend's ID in the same entry as its status
#      and body_bytes_sent;
#   3. missing and empty values are unambiguous: no header -> "-" (also when
#      the client sent one), header present but empty -> "", and a response
#      nginx serves itself -> "-" with uct=- urt=-;
#   4. a client-controlled field (User-Agent) cannot forge the audit field:
#      its quotes are escaped and the end-anchored field holds the backend's ID;
#   5. every pre-existing field keeps its order and format; responses (status,
#      body, audit header) and forwarded request headers are unchanged;
#   6. credentials never reach the log: the request path and Referer are
#      logged without their query string or fragment, the Basic auth user is
#      logged as "-", and a path or Referer holding a credential-shaped token
#      is logged as "[redacted]";
#   7. the error log, run through the image's real entrypoint, keeps nginx's
#      message but loses query strings and credential-shaped tokens.
#
# Runs against the image built from this repo's Dockerfile, using the image's
# own /etc/nginx/nginx.conf and templates rendered like entrypoint.sh.
# VALIDATE_IMAGE=<ref> skips the build (same convention as
# validate-nginx-config.sh).
#
# Requirements: docker, curl, openssl. Run from anywhere:
#   ./tests/test-admin-audit-log.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

DOMAIN="ingress-test.invalid"
BACKEND_HOST="backend"
BACKEND_PORT="3000"

IMAGE="${VALIDATE_IMAGE:-}"
if [[ -z "$IMAGE" ]]; then
    IMAGE="cvm-ingress-validate:local"
    echo "Building $IMAGE from $REPO_ROOT/Dockerfile"
    docker build -q -t "$IMAGE" "$REPO_ROOT" >/dev/null
fi
echo "Using image: $IMAGE"

WORK_DIR="$(mktemp -d)"
NET="audit-net-$$"
BACKEND_CTR="audit-backend-$$"
TLS_CTR="audit-tls-$$"
PLAIN_CTR="audit-plain-$$"
ENTRY_CTR="audit-entrypoint-$$"
TLS_PORT="$((20000 + RANDOM % 10000))"
PLAIN_PORT="$((30000 + RANDOM % 10000))"
ENTRY_PORT="$((40000 + RANDOM % 10000))"

cleanup() {
    docker rm -f "$BACKEND_CTR" "$TLS_CTR" "$PLAIN_CTR" "$ENTRY_CTR" >/dev/null 2>&1 || true
    docker network rm "$NET" >/dev/null 2>&1 || true
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

uuid() {
    openssl rand -hex 16 | sed -E 's/^(.{8})(.{4})(.{4})(.{4})(.{12})$/\1-\2-\3-\4-\5/'
}

# What the backend issues vs what a client tries to impose: the log must only
# ever carry the backend's IDs.
SERVER_ID="$(uuid)"
SERVER_DENIED_ID="$(uuid)"
CLIENT_AUDIT_ID="$(uuid)"
CLIENT_REQUEST_ID="$(uuid)"
CLIENT_HEADERS=(-H "X-Admin-Audit-Request-Id: $CLIENT_AUDIT_ID" -H "X-Request-Id: $CLIENT_REQUEST_ID")
DENIED_BODY='{"error":{"message":"Forbidden","type":"forbidden","param":null,"code":null}}'
UA="admin-audit-log-test"

# --- Cert + stub backend ------------------------------------------------------

mkdir -p "$WORK_DIR/certs/$DOMAIN"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 2 \
    -subj "/CN=$DOMAIN" \
    -keyout "$WORK_DIR/certs/$DOMAIN/privkey.pem" \
    -out "$WORK_DIR/certs/$DOMAIN/fullchain.pem" >/dev/null 2>&1

# Header names are lowercase, as Cloud API (hyper) sends them. The 200 body
# echoes the client-supplied headers the backend received.
cat >"$WORK_DIR/backend.conf" <<EOF
server {
    listen $BACKEND_PORT;
    default_type application/json;

    location = /v1/admin/organizations {
        add_header x-admin-audit-request-id "$SERVER_ID" always;
        return 200 '{"seen_audit_header":"\$http_x_admin_audit_request_id","seen_request_id":"\$http_x_request_id"}';
    }
    location = /v1/admin/users {
        add_header x-admin-audit-request-id "$SERVER_DENIED_ID" always;
        return 403 '$DENIED_BODY';
    }
    # add_header skips empty values; a whitespace-only value reaches the
    # ingress as a present-but-empty header (field values exclude surrounding
    # whitespace, RFC 9110 section 5.5).
    location = /v1/admin/blank {
        add_header x-admin-audit-request-id " " always;
        return 200 '{"ok":true}';
    }
    # Non-admin route: no audit header.
    location / {
        return 200 '{"ok":true}';
    }
}
EOF
chmod -R a+rX "$WORK_DIR"

docker network create "$NET" >/dev/null

docker run -d --name "$BACKEND_CTR" --network "$NET" --network-alias "$BACKEND_HOST" \
    -v "$WORK_DIR/backend.conf:/etc/nginx/conf.d/default.conf:ro" \
    --entrypoint sh "$IMAGE" -c 'mkdir -p /run/nginx && exec nginx -g "daemon off;"' >/dev/null

# --- TLS and plain ingress from the exact image -------------------------------
# Render inside the image with its own envsubst, exactly like entrypoint.sh
# generate_nginx_config, and keep the image's own /etc/nginx/nginx.conf (where
# the log format lives). TLS setup itself needs dstack/S3, so certs are mounted.

start_ingress() {
    local name=$1 template=$2 port=$3 mounts=()
    [[ "$template" == "tls" ]] && mounts=(-v "$WORK_DIR/certs:/certs:ro")
    docker run -d --name "$name" --network "$NET" \
        -e DOMAIN="$DOMAIN" -e BACKEND_HOST="$BACKEND_HOST" -e BACKEND_PORT="$BACKEND_PORT" \
        "${mounts[@]}" \
        -p "127.0.0.1:$port:8443" \
        --entrypoint bash "$IMAGE" -c '
            set -euo pipefail
            export DOLLAR="$"
            mkdir -p /run/nginx
            envsubst < "/app/nginx/'"$template"'.conf.template" > /etc/nginx/conf.d/default.conf
            nginx -t
            exec nginx -g "daemon off;"
        ' >/dev/null
}

start_ingress "$TLS_CTR" tls "$TLS_PORT"
start_ingress "$PLAIN_CTR" default "$PLAIN_PORT"

# The TLS server rejects unknown SNI/Host: present DOMAIN as
# SNI + Host by connecting to the published loopback port via --connect-to.
TLS_BASE="https://$DOMAIN:$TLS_PORT"
CONNECT=(--connect-to "$DOMAIN:$TLS_PORT:127.0.0.1:$TLS_PORT")
PLAIN_BASE="http://127.0.0.1:$PLAIN_PORT"

for i in $(seq 1 30); do
    if [[ "$(curl -ks --max-time 2 "${CONNECT[@]}" "$TLS_BASE/nginx-health" || true)" == "ok" ]] &&
        [[ "$(curl -s --max-time 2 "$PLAIN_BASE/nginx-health" || true)" == "ok" ]]; then
        break
    fi
    if [[ "$i" == "30" ]]; then
        docker logs "$TLS_CTR" >&2 || true
        docker logs "$PLAIN_CTR" >&2 || true
        fail "ingress containers did not become ready"
    fi
    sleep 1
done
for ctr in "$TLS_CTR" "$PLAIN_CTR"; do
    startup="$(docker logs "$ctr" 2>&1)"
    grep -q 'nginx.conf test is successful' <<<"$startup" || fail "$ctr: nginx -t did not succeed: $startup"
done
echo "PASS: nginx -t on the image's nginx.conf with both rendered templates (tls :$TLS_PORT, plain :$PLAIN_PORT)"

# --- Helpers ------------------------------------------------------------------

# Every pre-existing field in its original order, then the new last field.
# nginx escapes '"' inside logged values, so [^"]* cannot cross a field.
# Groups: 1 request line, 2 status, 3 body_bytes_sent, 4 uct, 5 urt,
# 6 admin_audit_request_id.
ENTRY_RE='^[^ ]+ - [^ ]+ \[[^]]+\] "([^"]*)" ([0-9]{3}) ([0-9]+) "[^"]*" "[^"]*" "[^"]*" rt=[0-9.]+ uct=([0-9.]+|-) urt=([0-9.]+|-) admin_audit_request_id="([^"]*)"$'

# send <container> <probe> <url> [curl args...]
# Sends one request to <url>?probe=<probe> with X-Forwarded-For: probe-<probe>.
# The query string is not logged, so the entry is found by the X-Forwarded-For
# field. Sets STATUS, BYTES, HEADERS (CRs stripped) and BODY as the client saw
# them, and ENTRY to the single access-log line <container> wrote for it.
send() {
    local ctr=$1 probe=$2 url=$3 meta
    shift 3
    meta="$(curl -ks --max-time 10 -A "$UA" -D "$WORK_DIR/headers" -o "$WORK_DIR/body" \
        -H "X-Forwarded-For: probe-$probe" \
        -w '%{http_code} %{size_download}' "$@" "$url?probe=$probe")" \
        || fail "$probe: request failed"
    read -r STATUS BYTES <<<"$meta"
    HEADERS="$(tr -d '\r' <"$WORK_DIR/headers")"
    BODY="$(cat "$WORK_DIR/body")"
    ENTRY=""
    for _ in $(seq 1 50); do
        ENTRY="$(docker logs "$ctr" 2>/dev/null | grep -F "\"probe-$probe\" rt=" || true)"
        [[ -n "$ENTRY" ]] && break
        sleep 0.1
    done
    [[ -n "$ENTRY" ]] || fail "$probe: no access-log entry in $ctr"
    [[ "$ENTRY" != *$'\n'* ]] || fail "$probe: expected one access-log entry, got: $ENTRY"
}

# expect_entry <label> <status> <request line> <admin_audit_request_id> <proxied: yes|no>
# ENTRY keeps the pre-existing format, logs the status and body size the
# client received, carries exactly the given ID, and contains neither
# client-supplied ID anywhere.
expect_entry() {
    local label=$1 want_status=$2 want_request=$3 want_id=$4 proxied=$5 id
    [[ "$STATUS" == "$want_status" ]] || fail "$label: expected status $want_status, client got $STATUS"
    [[ "$ENTRY" =~ $ENTRY_RE ]] || fail "$label: unexpected access-log format: $ENTRY"
    [[ "${BASH_REMATCH[1]}" == "$want_request" ]] \
        || fail "$label: logged request '${BASH_REMATCH[1]}', expected '$want_request'"
    [[ "${BASH_REMATCH[2]}" == "$STATUS" && "${BASH_REMATCH[3]}" == "$BYTES" ]] \
        || fail "$label: logged status/bytes ${BASH_REMATCH[2]}/${BASH_REMATCH[3]}, client got $STATUS/$BYTES"
    if [[ "$proxied" == "yes" ]]; then
        [[ "${BASH_REMATCH[4]}" != "-" && "${BASH_REMATCH[5]}" != "-" ]] \
            || fail "$label: expected upstream timings, got uct=${BASH_REMATCH[4]} urt=${BASH_REMATCH[5]}"
    else
        [[ "${BASH_REMATCH[4]}" == "-" && "${BASH_REMATCH[5]}" == "-" ]] \
            || fail "$label: expected no upstream, got uct=${BASH_REMATCH[4]} urt=${BASH_REMATCH[5]}"
    fi
    [[ "${BASH_REMATCH[6]}" == "$want_id" ]] \
        || fail "$label: admin_audit_request_id=\"${BASH_REMATCH[6]}\", expected \"$want_id\""
    for id in "$CLIENT_AUDIT_ID" "$CLIENT_REQUEST_ID"; do
        [[ "$ENTRY" != *"$id"* ]] || fail "$label: client-supplied ID $id appears in the entry: $ENTRY"
    done
    echo "PASS: $label -> $STATUS, $BYTES bytes, admin_audit_request_id=\"$want_id\""
}

# --- 1. Client-supplied IDs never become the logged audit ID ------------------

send "$TLS_CTR" tls-h1 "$TLS_BASE/v1/admin/organizations" --http1.1 "${CONNECT[@]}" "${CLIENT_HEADERS[@]}"
expect_entry "tls HTTP/1.1 admin" 200 "GET /v1/admin/organizations HTTP/1.1" "$SERVER_ID" yes

# Response and request behavior are unchanged: the client still receives the
# backend's header and body, and the backend still receives the client's
# headers as sent (so Cloud API must ignore them, never adopt them).
[[ "$(grep -ci "^x-admin-audit-request-id: $SERVER_ID\$" <<<"$HEADERS" || true)" == "1" ]] \
    || fail "tls-h1: client did not receive exactly one backend audit header: $HEADERS"
[[ "$BODY" == "{\"seen_audit_header\":\"$CLIENT_AUDIT_ID\",\"seen_request_id\":\"$CLIENT_REQUEST_ID\"}" ]] \
    || fail "tls-h1: backend did not receive the client headers unchanged: $BODY"
echo "PASS: tls HTTP/1.1 response passes through; client headers still forwarded as sent"

send "$TLS_CTR" tls-h2 "$TLS_BASE/v1/admin/organizations" --http2 "${CONNECT[@]}" "${CLIENT_HEADERS[@]}"
expect_entry "tls HTTP/2 admin" 200 "GET /v1/admin/organizations HTTP/2.0" "$SERVER_ID" yes

send "$PLAIN_CTR" plain "$PLAIN_BASE/v1/admin/organizations" -H "Host: $DOMAIN" "${CLIENT_HEADERS[@]}"
expect_entry "plain admin" 200 "GET /v1/admin/organizations HTTP/1.1" "$SERVER_ID" yes

# --- 2. Denial: backend ID logged with the denial's status and size -----------

send "$TLS_CTR" denied "$TLS_BASE/v1/admin/users" --http1.1 "${CONNECT[@]}" "${CLIENT_HEADERS[@]}"
expect_entry "tls admin denial" 403 "GET /v1/admin/users HTTP/1.1" "$SERVER_DENIED_ID" yes
[[ "$BODY" == "$DENIED_BODY" ]] || fail "denied: backend 403 envelope was rewritten: $BODY"

# --- 3. Missing and empty values are unambiguous ------------------------------

# The backend sends no audit header; the client's must not fill the gap.
send "$TLS_CTR" no-header "$TLS_BASE/v1/models" --http1.1 "${CONNECT[@]}" "${CLIENT_HEADERS[@]}"
expect_entry "tls non-admin, no audit header" 200 "GET /v1/models HTTP/1.1" "-" yes

send "$TLS_CTR" blank "$TLS_BASE/v1/admin/blank" --http1.1 "${CONNECT[@]}"
expect_entry "tls admin, empty audit header" 200 "GET /v1/admin/blank HTTP/1.1" "" yes

# Answered by nginx itself: no upstream at all.
send "$TLS_CTR" health "$TLS_BASE/nginx-health" --http1.1 "${CONNECT[@]}" "${CLIENT_HEADERS[@]}"
expect_entry "tls /nginx-health, no backend" 200 "GET /nginx-health HTTP/1.1" "-" no

# --- 4. A client-controlled field cannot forge the audit field ----------------

send "$TLS_CTR" forged-ua "$TLS_BASE/v1/admin/organizations" --http1.1 "${CONNECT[@]}" \
    -A "x\" admin_audit_request_id=\"$CLIENT_AUDIT_ID"
[[ "$ENTRY" =~ $ENTRY_RE && "${BASH_REMATCH[6]}" == "$SERVER_ID" ]] \
    || fail "forged-ua: end-anchored admin_audit_request_id is not the backend's ID: $ENTRY"
[[ "$ENTRY" == *"admin_audit_request_id=\\x22$CLIENT_AUDIT_ID"* ]] \
    || fail "forged-ua: forged text not found escaped inside the User-Agent field: $ENTRY"
[[ "$(grep -o 'admin_audit_request_id="' <<<"$ENTRY" | wc -l | tr -d ' ')" == "1" ]] \
    || fail "forged-ua: more than one unescaped admin_audit_request_id=\" in the entry: $ENTRY"
echo "PASS: forged User-Agent is escaped; the end-anchored field holds the backend's ID"

# --- 5. Credentials in URLs and Basic auth are never logged -------------------

# Random values in the shape of real credentials, generated per run.
FAKE_KEY="sk-$(openssl rand -hex 16)"
FAKE_ADMIN="adm_$(openssl rand -hex 16)"
FAKE_SESSION="sess_$(openssl rand -hex 16)"
FAKE_JWT="eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ0ZXN0In0.$(openssl rand -hex 8)"
# Group 1: Referer field.
REFERER_RE='^[^ ]+ - - \[[^]]+\] "[^"]*" [0-9]{3} [0-9]+ "([^"]*)"'

# expect_no_secrets <label>: ENTRY holds none of the fake credentials.
expect_no_secrets() {
    local label=$1 secret
    for secret in "$FAKE_KEY" "$FAKE_ADMIN" "$FAKE_SESSION" "$FAKE_JWT"; do
        [[ "$ENTRY" != *"$secret"* ]] || fail "$label: a credential reached the access log: $ENTRY"
    done
}

# expect_referer <label> <referer field>
expect_referer() {
    local label=$1 want=$2
    [[ "$ENTRY" =~ $REFERER_RE ]] || fail "$label: unexpected access-log format: $ENTRY"
    [[ "${BASH_REMATCH[1]}" == "$want" ]] \
        || fail "$label: logged Referer '${BASH_REMATCH[1]}', expected '$want'"
    echo "PASS: $label -> Referer logged as \"$want\""
}

send "$TLS_CTR" cred-query "$TLS_BASE/v1/models" --http1.1 "${CONNECT[@]}" \
    -G --data-urlencode "api_key=$FAKE_KEY" --data-urlencode "token=$FAKE_SESSION"
expect_entry "credentials in the query string" 200 "GET /v1/models HTTP/1.1" "-" yes
expect_referer "no Referer" "-"
expect_no_secrets "credentials in the query string"

send "$TLS_CTR" cred-basic "$TLS_BASE/v1/models" --http1.1 "${CONNECT[@]}" -u "$FAKE_KEY:"
expect_entry "API key as the Basic auth user" 200 "GET /v1/models HTTP/1.1" "-" yes
[[ "$ENTRY" == *" - - ["* ]] || fail "cred-basic: expected '-' for the auth user: $ENTRY"
expect_no_secrets "API key as the Basic auth user"

send "$TLS_CTR" cred-path "$TLS_BASE/v1,api_key=$FAKE_KEY,model=test" --http1.1 "${CONNECT[@]}"
expect_entry "API key inside the path" 200 "GET [redacted] HTTP/1.1" "-" yes
expect_no_secrets "API key inside the path"

send "$TLS_CTR" cred-path-hyphen "$TLS_BASE/v1/key-$FAKE_KEY" --http1.1 "${CONNECT[@]}"
expect_entry "API key after a hyphen in the path" 200 "GET [redacted] HTTP/1.1" "-" yes
expect_no_secrets "API key after a hyphen in the path"

send "$TLS_CTR" cred-path-encoded "$TLS_BASE/v1/x%3D$FAKE_ADMIN" --http1.1 "${CONNECT[@]}"
expect_entry "percent-encoded admin token in the path" 200 "GET [redacted] HTTP/1.1" "-" yes
expect_no_secrets "percent-encoded admin token in the path"

send "$TLS_CTR" cred-path-jwt "$TLS_BASE/v1/session/$FAKE_JWT" --http1.1 "${CONNECT[@]}"
expect_entry "JWT in the path" 200 "GET [redacted] HTTP/1.1" "-" yes
expect_no_secrets "JWT in the path"

send "$TLS_CTR" cred-referer-query "$TLS_BASE/v1/models" --http1.1 "${CONNECT[@]}" \
    -e "https://app.example.invalid/settings?api_key=$FAKE_KEY#frag"
expect_entry "credential in the Referer query" 200 "GET /v1/models HTTP/1.1" "-" yes
expect_referer "credential in the Referer query" "https://app.example.invalid/settings"
expect_no_secrets "credential in the Referer query"

send "$TLS_CTR" cred-referer-path "$TLS_BASE/v1/models" --http1.1 "${CONNECT[@]}" \
    -e "https://app.example.invalid/v1,api_key=$FAKE_KEY"
expect_referer "credential in the Referer path" "[redacted]"
expect_no_secrets "credential in the Referer path"

# Look-alikes stay readable: "task-..." is not an API key.
send "$TLS_CTR" lookalike "$TLS_BASE/v1/tasks/task-0123456789abcdef0123" --http1.1 "${CONNECT[@]}" \
    -e "https://app.example.invalid/tasks/task-0123456789abcdef0123"
expect_entry "API-key look-alike in the path" 200 "GET /v1/tasks/task-0123456789abcdef0123 HTTP/1.1" "-" yes
expect_referer "API-key look-alike in the Referer" "https://app.example.invalid/tasks/task-0123456789abcdef0123"

# --- 6. The error log keeps its detail but not the credentials ----------------
# nginx quotes the request line, upstream URL and Referer in error messages.
# Start the image through its real entrypoint (plain mode) with an unreachable
# backend, so every proxied request writes a connect() error.

docker run -d --name "$ENTRY_CTR" -e DOMAIN="$DOMAIN" -e BACKEND_HOST=127.0.0.1 -e BACKEND_PORT=9 \
    -p "127.0.0.1:$ENTRY_PORT:8443" "$IMAGE" >/dev/null
ENTRY_BASE="http://127.0.0.1:$ENTRY_PORT"
for i in $(seq 1 30); do
    [[ "$(curl -s --max-time 2 "$ENTRY_BASE/nginx-health" || true)" == "ok" ]] && break
    [[ "$i" == "30" ]] && { docker logs "$ENTRY_CTR" >&2 || true; fail "entrypoint container did not become ready"; }
    sleep 1
done

curl -s --max-time 5 -o /dev/null -H "Host: $DOMAIN" \
    -e "https://app.example.invalid/settings?token=$FAKE_SESSION" \
    "$ENTRY_BASE/v1/models?api_key=$FAKE_KEY&probe=error-log" || true
curl -s --max-time 5 -o /dev/null -H "Host: $DOMAIN" \
    "$ENTRY_BASE/v1,api_key=$FAKE_ADMIN,model=test" || true

ERROR_LOG=""
for _ in $(seq 1 50); do
    ERROR_LOG="$(docker logs "$ENTRY_CTR" 2>&1 >/dev/null | grep -F 'connect() failed' || true)"
    [[ "$(grep -c . <<<"$ERROR_LOG")" -ge 2 ]] && break
    sleep 0.1
done
[[ "$(grep -c . <<<"$ERROR_LOG")" -ge 2 ]] \
    || fail "error log: expected two connect() errors on stderr, got: $ERROR_LOG"
grep -qE '^[0-9/]+ [0-9:]+ \[error\] [0-9]+#[0-9]+: \*[0-9]+ connect\(\) failed' <<<"$ERROR_LOG" \
    || fail "error log: nginx's line prefix was altered: $ERROR_LOG"
for want in 'request: "GET /v1/models HTTP/1.1"' 'upstream: "http://127.0.0.1:9/v1/models"' \
    'referrer: "https://app.example.invalid/settings"' 'request: "GET /v1,api_key=[redacted],model=test HTTP/1.1"'; do
    grep -qF "$want" <<<"$ERROR_LOG" || fail "error log: missing '$want' in: $ERROR_LOG"
done
ENTRY="$(docker logs "$ENTRY_CTR" 2>&1)"
expect_no_secrets "error log"
echo "PASS: error log keeps nginx's detail; query strings and tokens are removed"

echo
echo "All admin audit log tests passed."
