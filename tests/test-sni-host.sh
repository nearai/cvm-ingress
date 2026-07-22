#!/usr/bin/env bash
# Exact-image tests for the SNI/Host security boundary (nearai/infra#195).
#
# Builds the image from this repository's Dockerfile (the same artifact that
# ships), renders the templates inside it with its own envsubst — exactly like
# entrypoint.sh does — and asserts against the running container:
#
#   TLS server (tls.conf.template):
#     1. valid SNI + matching Host is proxied, over HTTP/1.1 and HTTP/2, and
#        the backend sees the upstream Host header pinned to DOMAIN;
#     2. unknown SNI and empty SNI are rejected at the TLS handshake
#        (no certificate is ever presented);
#     3. a foreign Host on a valid-SNI connection is rejected before proxying:
#        connection closed (444) over HTTP/1.1, 421 over HTTP/2 — including
#        Host: localhost and IP-literal Hosts;
#     4. /nginx-health works with correct SNI + Host.
#
#   Plain server (default.conf.template, TLS_ENABLED=false):
#     5. matching Host proxied with pinned upstream Host; foreign or IP-literal
#        Host closed without a response; /nginx-health stays reachable by IP.
#
# A future change that weakens any of these merges red, not green.
#
# Requirements: docker, curl, openssl. Run from anywhere: ./tests/test-sni-host.sh
#   SNI_HOST_TEST_IMAGE=<ref>  test <ref> instead of building the Dockerfile
#                              first (local iteration shortcut; CI always builds).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

DOMAIN="ingress-test.invalid"
BACKEND_HOST="backend"
BACKEND_PORT="3000"

TLS_PORT="$((20000 + RANDOM % 10000))"
PLAIN_PORT="$((30000 + RANDOM % 10000))"

NET="snihost-net-$$"
BACKEND_CTR="snihost-backend-$$"
TLS_CTR="snihost-tls-$$"
PLAIN_CTR="snihost-plain-$$"

WORK_DIR="$(mktemp -d)"

cleanup() {
    docker rm -f "$BACKEND_CTR" "$TLS_CTR" "$PLAIN_CTR" >/dev/null 2>&1 || true
    docker network rm "$NET" >/dev/null 2>&1 || true
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- Build (or reuse) the exact image ----------------------------------------

IMAGE="${SNI_HOST_TEST_IMAGE:-}"
if [[ -z "$IMAGE" ]]; then
    IMAGE="cvm-ingress-snihost:local"
    echo "Building $IMAGE from ./Dockerfile"
    DOCKER_BUILDKIT=1 docker build -t "$IMAGE" "$REPO_ROOT" >/dev/null
fi
echo "Testing image: $IMAGE"

# --- Cert + stub backend ------------------------------------------------------

mkdir -p "$WORK_DIR/certs/$DOMAIN"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 2 \
    -subj "/CN=$DOMAIN" \
    -keyout "$WORK_DIR/certs/$DOMAIN/privkey.pem" \
    -out "$WORK_DIR/certs/$DOMAIN/fullchain.pem" >/dev/null 2>&1
chmod -R a+rX "$WORK_DIR"

# Echoes the Host header it receives so we can assert the ingress pins it.
cat >"$WORK_DIR/backend.conf" <<'EOF'
server {
    listen 3000;
    default_type text/plain;
    location / { return 200 "backend-host=$host\n"; }
}
EOF

docker network create "$NET" >/dev/null

docker run -d --name "$BACKEND_CTR" --network "$NET" --network-alias "$BACKEND_HOST" \
    -v "$WORK_DIR/backend.conf:/etc/nginx/conf.d/default.conf:ro" \
    --entrypoint sh "$IMAGE" -c 'mkdir -p /run/nginx && exec nginx -g "daemon off;"' >/dev/null

# --- Start TLS and plain ingress containers from the exact image --------------
# Render inside the image with its own envsubst, exactly like entrypoint.sh
# generate_nginx_config (TLS setup itself needs dstack/S3, so certs are mounted).

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

TLS_BASE="https://$DOMAIN:$TLS_PORT"
CONNECT=(--connect-to "$DOMAIN:$TLS_PORT:127.0.0.1:$TLS_PORT")

for i in $(seq 1 30); do
    if [[ "$(curl -ks --max-time 2 "${CONNECT[@]}" "$TLS_BASE/nginx-health" || true)" == *ok* ]]; then
        break
    fi
    [[ "$i" == "30" ]] && { docker logs "$TLS_CTR" >&2 || true; fail "TLS ingress did not become ready"; }
    sleep 1
done
for i in $(seq 1 30); do
    if [[ "$(curl -s --max-time 2 -H "Host: $DOMAIN" "http://127.0.0.1:$PLAIN_PORT/nginx-health" || true)" == *ok* ]]; then
        break
    fi
    [[ "$i" == "30" ]] && { docker logs "$PLAIN_CTR" >&2 || true; fail "plain ingress did not become ready"; }
    sleep 1
done
echo "Ingress up (tls :$TLS_PORT, plain :$PLAIN_PORT, backend stub :$BACKEND_PORT)"

# --- Helpers ------------------------------------------------------------------

# expect_proxied <label> <http-version-flag> [extra curl args...]
# Asserts 200 + the backend saw Host pinned to DOMAIN.
expect_proxied() {
    local label=$1 vflag=$2; shift 2
    local out code
    out="$(curl -ks "$vflag" --max-time 10 "${CONNECT[@]}" "$@" -w '\n%{http_code} %{http_version}' "$TLS_BASE/echo")" \
        || fail "$label: curl failed"
    code="$(tail -n1 <<<"$out")"
    [[ "$code" == 200\ * ]] || fail "$label: expected 200, got '$code'"
    grep -q "backend-host=$DOMAIN\$" <<<"$out" \
        || fail "$label: upstream Host not pinned to $DOMAIN: $(head -n1 <<<"$out")"
    echo "PASS: $label -> 200, upstream Host pinned to $DOMAIN (http $(awk '{print $2}' <<<"$code"))"
}

# expect_closed_h1 <label> [extra curl args...]
# HTTP/1.1 request whose connection must be closed without an HTTP response
# (444): curl exits 52 "empty reply from server".
expect_closed_h1() {
    local label=$1; shift
    local rc=0
    curl -ks --http1.1 --max-time 10 "${CONNECT[@]}" "$@" -o /dev/null "$TLS_BASE/echo" || rc=$?
    [[ "$rc" == "52" ]] || fail "$label: expected connection close (curl exit 52), got exit $rc"
    echo "PASS: $label -> connection closed without response"
}

# expect_h2_421 <label> [extra curl args...]
# HTTP/2 request whose :authority/Host mismatches: nginx answers 421 and the
# request must never reach the backend.
expect_h2_421() {
    local label=$1; shift
    local out code
    out="$(curl -ks --http2 --max-time 10 "${CONNECT[@]}" "$@" -w '\n%{http_code}' "$TLS_BASE/echo" || true)"
    code="$(tail -n1 <<<"$out")"
    [[ "$code" == "421" ]] || fail "$label: expected 421 over HTTP/2, got '$code'"
    grep -q "backend-host=" <<<"$out" && fail "$label: request reached the backend despite Host mismatch"
    echo "PASS: $label -> 421, not proxied"
}

# expect_handshake_reject <label> <s_client args...>
# The TLS handshake itself must fail: no certificate presented.
expect_handshake_reject() {
    local label=$1; shift
    local out
    out="$(echo | timeout 10 openssl s_client -connect "127.0.0.1:$TLS_PORT" "$@" 2>&1 || true)"
    grep -q "BEGIN CERTIFICATE" <<<"$out" \
        && fail "$label: server presented a certificate — handshake was not rejected"
    grep -Eq "unrecognized name|handshake failure|alert" <<<"$out" \
        || fail "$label: no TLS alert observed; output: $(tail -n3 <<<"$out")"
    echo "PASS: $label -> handshake rejected, no certificate presented"
}

# --- 1+4. Valid SNI + matching Host: proxied, Host pinned, both protocols -----

expect_proxied "valid SNI+Host HTTP/1.1" --http1.1
expect_proxied "valid SNI+Host HTTP/2" --http2

hc="$(curl -ks --max-time 10 "${CONNECT[@]}" "$TLS_BASE/nginx-health")"
[[ "$hc" == "ok" ]] || fail "/nginx-health with correct SNI+Host: expected 'ok', got '$hc'"
echo "PASS: /nginx-health with correct SNI+Host -> 200 ok"

# --- 2. Unknown / empty SNI: rejected at the handshake ------------------------

expect_handshake_reject "unknown SNI" -servername "unknown-$DOMAIN"
expect_handshake_reject "empty SNI" -noservername

# curl equivalents (what a monitoring/deploy probe without --connect-to sees):
rc=0; curl -ks --max-time 10 "https://127.0.0.1:$TLS_PORT/" -o /dev/null || rc=$?
[[ "$rc" == "35" ]] || fail "bare https://127.0.0.1 probe: expected TLS connect error (curl exit 35), got $rc"
echo "PASS: bare https://127.0.0.1:port probe fails at handshake (curl exit 35)"

# --- 3. Valid SNI + foreign/localhost/IP Host: rejected before proxying -------

expect_closed_h1 "foreign Host HTTP/1.1" -H "Host: evil.example.com"
expect_closed_h1 "Host: localhost HTTP/1.1" -H "Host: localhost"
expect_closed_h1 "IP-literal Host HTTP/1.1" -H "Host: 203.0.113.7"
expect_h2_421 "foreign Host HTTP/2" -H "Host: evil.example.com"
expect_h2_421 "Host: localhost HTTP/2" -H "Host: localhost"
expect_h2_421 "IP-literal Host HTTP/2" -H "Host: 203.0.113.7"

# --- 5. Plain (non-TLS) server: same Host allowlist ---------------------------

out="$(curl -s --max-time 10 -H "Host: $DOMAIN" "http://127.0.0.1:$PLAIN_PORT/echo")" \
    || fail "plain: matching Host request failed"
[[ "$out" == "backend-host=$DOMAIN" ]] \
    || fail "plain: upstream Host not pinned to $DOMAIN: '$out'"
echo "PASS: plain matching Host -> proxied, upstream Host pinned"

rc=0; curl -s --max-time 10 -H "Host: evil.example.com" -o /dev/null "http://127.0.0.1:$PLAIN_PORT/echo" || rc=$?
[[ "$rc" == "52" ]] || fail "plain: foreign Host expected connection close (curl exit 52), got $rc"
echo "PASS: plain foreign Host -> connection closed without response"

rc=0; curl -s --max-time 10 -o /dev/null "http://127.0.0.1:$PLAIN_PORT/echo" || rc=$?
[[ "$rc" == "52" ]] || fail "plain: IP-literal Host expected connection close (curl exit 52), got $rc"
echo "PASS: plain IP-literal Host -> connection closed without response"

hc="$(curl -s --max-time 10 "http://127.0.0.1:$PLAIN_PORT/nginx-health")"
[[ "$hc" == "ok" ]] || fail "plain: /nginx-health by IP expected 'ok', got '$hc'"
echo "PASS: plain /nginx-health by IP -> 200 ok"

echo
echo "All SNI/Host enforcement tests passed."
