#!/usr/bin/env bash
# Template/config tests for the security response headers (nearai/infra#196).
#
# What this covers:
#   1. Static checks on the rendered TLS config:
#      - exactly one Strict-Transport-Security and one X-Content-Type-Options
#        add_header, with the exact expected values and the `always` flag;
#      - proxy_hide_header present for both (duplicate prevention);
#      - no add_header inside any location block (nginx drops ALL server-level
#        add_header directives in a location that declares its own — the
#        inheritance trap would silently remove these headers).
#   2. `nginx -t` on both rendered templates (TLS and plain) inside the same
#      pinned nginx image the production Dockerfile builds FROM.
#   3. A runtime test: the TLS config proxying to a stub backend, verifying on
#      live responses that 200/301/404/controlled-500, the local health
#      endpoint, and a streaming (SSE) response each carry exactly one copy of
#      each header — including when the backend emits its own conflicting
#      copies (proxy_hide_header must win).
#
# Requirements: docker, openssl, curl, awk. Run from anywhere:
#   ./tests/test-headers.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

HSTS_VALUE='max-age=31536000; includeSubDomains'
XCTO_VALUE='nosniff'

DOMAIN="ingress-test.invalid"
BACKEND_HOST="backend"
BACKEND_PORT="3000"

# Use the exact base image the production image is built FROM (pinned digest),
# so nginx -t and the runtime test exercise the same nginx binary.
IMAGE="$(awk '/^FROM[[:space:]]+nginx/ { print $2; exit }' "$REPO_ROOT/Dockerfile")"
if [[ -z "$IMAGE" ]]; then
    echo "FAIL: could not parse pinned nginx image from Dockerfile" >&2
    exit 1
fi
echo "Using pinned image: $IMAGE"

WORK_DIR="$(mktemp -d)"
NET="sechdr-net-$$"
BACKEND_CTR="sechdr-backend-$$"
INGRESS_CTR="sechdr-ingress-$$"
HOST_PORT="$((20000 + RANDOM % 20000))"

cleanup() {
    docker rm -f "$BACKEND_CTR" "$INGRESS_CTR" >/dev/null 2>&1 || true
    docker network rm "$NET" >/dev/null 2>&1 || true
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# --- Render templates exactly like entrypoint.sh generate_nginx_config -------

render() {
    local template="$1" out="$2"
    if command -v envsubst >/dev/null 2>&1; then
        DOLLAR='$' DOMAIN="$DOMAIN" BACKEND_HOST="$BACKEND_HOST" BACKEND_PORT="$BACKEND_PORT" \
            envsubst <"$template" >"$out"
    else
        docker run --rm -i \
            -e DOLLAR='$' -e DOMAIN="$DOMAIN" -e BACKEND_HOST="$BACKEND_HOST" -e BACKEND_PORT="$BACKEND_PORT" \
            --entrypoint envsubst "$IMAGE" <"$template" >"$out"
    fi
}

render "$REPO_ROOT/nginx/tls.conf.template" "$WORK_DIR/tls.conf"
render "$REPO_ROOT/nginx/default.conf.template" "$WORK_DIR/default.conf"
echo "Rendered both templates"

# --- 1. Static checks on the rendered TLS config ------------------------------

count_directive() {
    grep -c "$1" "$WORK_DIR/tls.conf" || true
}

n="$(count_directive "add_header Strict-Transport-Security '$HSTS_VALUE' always;")"
[[ "$n" == "1" ]] || fail "expected exactly 1 HSTS add_header with value '$HSTS_VALUE' + always, found $n"

n="$(count_directive "add_header X-Content-Type-Options '$XCTO_VALUE' always;")"
[[ "$n" == "1" ]] || fail "expected exactly 1 X-Content-Type-Options add_header with value '$XCTO_VALUE' + always, found $n"

n="$(count_directive "proxy_hide_header Strict-Transport-Security;")"
[[ "$n" == "1" ]] || fail "expected proxy_hide_header Strict-Transport-Security (duplicate prevention), found $n"

n="$(count_directive "proxy_hide_header X-Content-Type-Options;")"
[[ "$n" == "1" ]] || fail "expected proxy_hide_header X-Content-Type-Options (duplicate prevention), found $n"

# Inheritance-trap guard: an add_header inside ANY location block makes nginx
# drop every server-level add_header for responses served by that location.
awk '
    BEGIN { depth = 0; inloc = 0; locdepth = 0; bad = 0 }
    {
        line = $0
        if (!inloc && line ~ /^[[:space:]]*location[[:space:]]/) { inloc = 1; locdepth = depth }
        if (inloc && line ~ /add_header/) {
            print "add_header inside a location block (drops server-level headers): " line
            bad = 1
        }
        opens = gsub(/{/, "{", line)
        closes = gsub(/}/, "}", line)
        depth += opens - closes
        if (inloc && depth <= locdepth) inloc = 0
    }
    END { exit bad }
' "$WORK_DIR/tls.conf" || fail "add_header inheritance trap detected in rendered TLS config"

echo "PASS: static config checks"

# --- 2. nginx -t on both rendered configs -------------------------------------

mkdir -p "$WORK_DIR/certs/$DOMAIN"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 2 \
    -subj "/CN=$DOMAIN" \
    -keyout "$WORK_DIR/certs/$DOMAIN/privkey.pem" \
    -out "$WORK_DIR/certs/$DOMAIN/fullchain.pem" >/dev/null 2>&1

docker run --rm \
    -v "$REPO_ROOT/nginx/nginx.conf:/etc/nginx/nginx.conf:ro" \
    -v "$WORK_DIR/tls.conf:/etc/nginx/conf.d/default.conf:ro" \
    -v "$WORK_DIR/certs:/certs:ro" \
    --entrypoint sh "$IMAGE" -c 'mkdir -p /run/nginx && nginx -t' \
    || fail "nginx -t rejected the rendered TLS config"

docker run --rm \
    -v "$REPO_ROOT/nginx/nginx.conf:/etc/nginx/nginx.conf:ro" \
    -v "$WORK_DIR/default.conf:/etc/nginx/conf.d/default.conf:ro" \
    --entrypoint sh "$IMAGE" -c 'mkdir -p /run/nginx && nginx -t' \
    || fail "nginx -t rejected the rendered plain config"

echo "PASS: nginx -t on both rendered configs"

# --- 3. Runtime header behavior ------------------------------------------------

# Stub backend covering the response classes from the acceptance criteria.
# /dup deliberately sets both security headers itself to prove
# proxy_hide_header leaves exactly one (the ingress) copy.
cat >"$WORK_DIR/backend.conf" <<'EOF'
server {
    listen 3000;
    default_type text/plain;

    location = /ok       { return 200 "ok\n"; }
    location = /missing  { return 404 "missing\n"; }
    location = /boom     { return 500 "boom\n"; }
    location = /redirect { return 301 /ok; }
    location = /dup {
        add_header Strict-Transport-Security "max-age=1" always;
        add_header X-Content-Type-Options "nosniff" always;
        return 200 "dup\n";
    }
    location = /sse {
        default_type text/event-stream;
        limit_rate 10k;
        alias /data/sse.txt;
    }
}
EOF

# ~40 KB event-stream body; at limit_rate 10k it trickles out over ~4s, which
# lets us verify the ingress relays it as a stream (TTFB well before EOF).
: >"$WORK_DIR/sse.txt"
for i in $(seq 1 800); do
    printf 'data: event number %04d padded to fifty bytes.\n\n' "$i" >>"$WORK_DIR/sse.txt"
done
SSE_SIZE="$(wc -c <"$WORK_DIR/sse.txt")"

docker network create "$NET" >/dev/null

docker run -d --name "$BACKEND_CTR" --network "$NET" --network-alias "$BACKEND_HOST" \
    -v "$WORK_DIR/backend.conf:/etc/nginx/conf.d/backend.conf:ro" \
    -v "$WORK_DIR/sse.txt:/data/sse.txt:ro" \
    "$IMAGE" >/dev/null

docker run -d --name "$INGRESS_CTR" --network "$NET" \
    -p "127.0.0.1:$HOST_PORT:8443" \
    -v "$REPO_ROOT/nginx/nginx.conf:/etc/nginx/nginx.conf:ro" \
    -v "$WORK_DIR/tls.conf:/etc/nginx/conf.d/default.conf:ro" \
    -v "$WORK_DIR/certs:/certs:ro" \
    --entrypoint sh "$IMAGE" -c 'mkdir -p /run/nginx && exec nginx -g "daemon off;"' >/dev/null

BASE="https://127.0.0.1:$HOST_PORT"
for i in $(seq 1 30); do
    if [[ "$(curl -ks --max-time 2 "$BASE/nginx-health" || true)" == *ok* ]]; then
        break
    fi
    [[ "$i" == "30" ]] && { docker logs "$INGRESS_CTR" >&2 || true; fail "ingress did not become ready"; }
    sleep 1
done
echo "Ingress up on $BASE (backend: stub on :$BACKEND_PORT)"

# check_headers <path> <expected-status> [<expected substring in body>]
check_headers() {
    local path="$1" want_status="$2" want_body="${3:-}"
    local raw status hsts_n xcto_n hsts_line xcto_line body
    # Strip CRs up front; tr consumes the whole stream, so no early-exit
    # consumer (head/-q grep) can SIGPIPE the producer under pipefail.
    raw="$(curl -ksi --max-time 15 "$BASE$path" | tr -d '\r')"
    read -r _ status _ <<<"$raw"
    [[ "$status" == "$want_status" ]] || fail "$path: expected status $want_status, got $status"

    hsts_n="$(printf '%s' "$raw" | grep -ci '^strict-transport-security:' || true)"
    xcto_n="$(printf '%s' "$raw" | grep -ci '^x-content-type-options:' || true)"
    [[ "$hsts_n" == "1" ]] || fail "$path: expected exactly 1 Strict-Transport-Security header, got $hsts_n"
    [[ "$xcto_n" == "1" ]] || fail "$path: expected exactly 1 X-Content-Type-Options header, got $xcto_n"

    hsts_line="$(printf '%s' "$raw" | grep -i '^strict-transport-security:')"
    xcto_line="$(printf '%s' "$raw" | grep -i '^x-content-type-options:')"
    [[ "$hsts_line" == *"$HSTS_VALUE"* ]] || fail "$path: HSTS value mismatch: '$hsts_line'"
    [[ "$xcto_line" == *"$XCTO_VALUE"* ]] || fail "$path: X-Content-Type-Options value mismatch: '$xcto_line'"

    if [[ -n "$want_body" ]]; then
        body="$(printf '%s' "$raw" | tail -n1)"
        [[ "$body" == *"$want_body"* ]] || fail "$path: expected body containing '$want_body'"
    fi
    echo "PASS: $path -> $status, one copy of each header"
}

check_headers /nginx-health 200 ok       # locally generated 200
check_headers /ok           200 ok       # proxied 200
check_headers /redirect     301          # proxied 3xx
check_headers /missing      404          # proxied 4xx
check_headers /boom         500          # controlled proxied 5xx (passes through)
check_headers /dup          200 dup      # backend sets its own copies -> hidden

# Streaming/SSE: exactly one copy of each header, intact body, and first byte
# delivered well before the (rate-limited) body completes = streamed, not
# buffered end-to-end.
sse_out="$WORK_DIR/sse.out"
read -r sse_status sse_ct sse_ttfb sse_total < <(curl -ksN --max-time 60 -o "$sse_out" \
    -w '%{http_code} %{content_type} %{time_starttransfer} %{time_total}\n' "$BASE/sse")
[[ "$sse_status" == "200" ]] || fail "/sse: expected 200, got $sse_status"
[[ "$sse_ct" == *"text/event-stream"* ]] || fail "/sse: expected text/event-stream, got $sse_ct"
sse_got="$(wc -c <"$sse_out")"
[[ "$sse_got" == "$SSE_SIZE" ]] || fail "/sse: body truncated ($sse_got of $SSE_SIZE bytes)"
awk -v ttfb="$sse_ttfb" -v total="$sse_total" 'BEGIN { exit !(total - ttfb >= 1.0) }' \
    || fail "/sse: response was not streamed (TTFB $sse_ttfb vs total $sse_total)"
check_headers /sse 200
echo "PASS: /sse streamed (TTFB ${sse_ttfb}s, total ${sse_total}s, $sse_got bytes intact)"

echo
echo "All header tests passed."
