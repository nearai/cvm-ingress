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
#   4. PROXY protocol mode (PROXY_PROTOCOL=true, nearai/cvm-ingress client
#      address handling): rendered config has proxy_protocol on every TCP
#      listener, no QUIC listener / http3 / Alt-Svc, and the same security
#      headers; at runtime the PROXY-header address (v1 IPv4/IPv6, v2) from a
#      trusted source replaces X-Forwarded-For and X-Real-IP (caller-supplied
#      values discarded), an untrusted source's PROXY header is not honoured,
#      and a connection without a PROXY header is refused. Default mode keeps
#      the legacy X-Forwarded-For append and the Alt-Svc advertisement.
#
# Requirements: docker, openssl, curl, awk, python3. Run from anywhere:
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
PP_CTR="sechdr-pp-$$"
PPU_CTR="sechdr-ppu-$$"
HOST_PORT="$((20000 + RANDOM % 20000))"

cleanup() {
    docker rm -f "$BACKEND_CTR" "$INGRESS_CTR" "$PP_CTR" "$PPU_CTR" >/dev/null 2>&1 || true
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

# PROXY protocol mode render: derive the INGRESS_* template variables with the
# same code the entrypoint uses (lib/validate.sh), then render as above.
render_pp() {
    local template="$1" out="$2" real_ip_from="$3"
    (
        # shellcheck source=/dev/null
        source "$REPO_ROOT/lib/log.sh"
        # shellcheck source=/dev/null
        source "$REPO_ROOT/lib/validate.sh"
        export DOMAIN BACKEND_HOST BACKEND_PORT
        PROXY_PROTOCOL=true REAL_IP_FROM="$real_ip_from" validate_env >/dev/null 2>&1 \
            || { echo "validate_env rejected REAL_IP_FROM=$real_ip_from" >&2; exit 1; }
        if command -v envsubst >/dev/null 2>&1; then
            DOLLAR='$' envsubst <"$template" >"$out"
        else
            docker run --rm -i -e DOLLAR='$' -e DOMAIN -e BACKEND_HOST -e BACKEND_PORT \
                -e INGRESS_PP_LISTEN -e INGRESS_QUIC_OFF -e INGRESS_XFF_LEGACY_OFF \
                -e INGRESS_REAL_IP_CONF -e INGRESS_XFF_CONF \
                --entrypoint envsubst "$IMAGE" <"$template" >"$out"
        fi
    )
}

render "$REPO_ROOT/nginx/tls.conf.template" "$WORK_DIR/tls.conf"
render "$REPO_ROOT/nginx/default.conf.template" "$WORK_DIR/default.conf"
# Trusted source for the runtime PROXY tests: the private ranges Docker hands
# out for bridge networks / the host gateway. The untrusted variant names an
# address (TEST-NET-3) that no test traffic can originate from.
TRUSTED_FROM="10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
UNTRUSTED_FROM="203.0.113.1"
render_pp "$REPO_ROOT/nginx/tls.conf.template" "$WORK_DIR/tls-pp.conf" "$TRUSTED_FROM"
render_pp "$REPO_ROOT/nginx/default.conf.template" "$WORK_DIR/default-pp.conf" "$TRUSTED_FROM"
render_pp "$REPO_ROOT/nginx/tls.conf.template" "$WORK_DIR/tls-pp-untrusted.conf" "$UNTRUSTED_FROM"
echo "Rendered default and PROXY-protocol templates"

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

# --- 1b. Static checks: default vs PROXY protocol mode ------------------------

for f in tls default; do
    ! grep -Eq 'proxy_protocol|set_real_ip_from|real_ip_header' "$WORK_DIR/$f.conf" \
        || fail "default $f render must not contain any PROXY protocol / realip directive"
    grep -Eq '^[[:space:]]*proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;' "$WORK_DIR/$f.conf" \
        || fail "default $f render lost the legacy X-Forwarded-For line"
done
n="$(grep -Ec '^[[:space:]]*listen .*quic' "$WORK_DIR/tls.conf" || true)"
[[ "$n" == "4" ]] || fail "default tls render: expected 4 active QUIC listeners, found $n"
grep -Eq "^[[:space:]]*add_header Alt-Svc 'h3=\":8443\"; ma=86400' always;" "$WORK_DIR/tls.conf" \
    || fail "default tls render lost the Alt-Svc advertisement"
grep -Eq '^[[:space:]]*http3 on;' "$WORK_DIR/tls.conf" || fail "default tls render lost http3 on"

for f in tls-pp default-pp; do
    # Every active TCP listen carries proxy_protocol; none may be without it.
    listens="$(grep -E '^[[:space:]]*listen ' "$WORK_DIR/$f.conf")"
    [[ -n "$listens" ]] || fail "$f: no active listen directives"
    bare="$(printf '%s\n' "$listens" | grep -vc 'proxy_protocol' || true)"
    [[ "$bare" == "0" ]] || fail "$f: $bare active listen directive(s) without proxy_protocol"
    # No active QUIC/HTTP3/Alt-Svc (commented-out template lines are fine).
    ! grep -Eq '^[[:space:]]*(listen .*quic|http3 |add_header Alt-Svc)' "$WORK_DIR/$f.conf" \
        || fail "$f: QUIC/HTTP3/Alt-Svc still active in PROXY protocol mode"
    # Each server block recovers the address from the PROXY header, only from
    # the configured source, and overwrites the forwarding headers.
    n="$(grep -Ec '^[[:space:]]*real_ip_header proxy_protocol;' "$WORK_DIR/$f.conf" || true)"
    [[ "$n" == "2" ]] || fail "$f: expected real_ip_header proxy_protocol in both server blocks, found $n"
    n="$(grep -Ec '^[[:space:]]*set_real_ip_from ' "$WORK_DIR/$f.conf" || true)"
    [[ "$n" == "6" ]] || fail "$f: expected 3 trusted sources x 2 server blocks, found $n"
    ! grep -Eq 'set_real_ip_from (0\.0\.0\.0|::|[^;]*/0;)' "$WORK_DIR/$f.conf" || fail "$f: trusts a wildcard source"
    ! grep -Eq '^[[:space:]]*proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;' "$WORK_DIR/$f.conf" \
        || fail "$f: caller-appending X-Forwarded-For still active"
    grep -Eq '^[[:space:]]*proxy_set_header X-Forwarded-For \$remote_addr;' "$WORK_DIR/$f.conf" \
        || fail "$f: X-Forwarded-For is not overwritten with the client address"
    grep -Eq '^[[:space:]]*proxy_set_header Forwarded "";' "$WORK_DIR/$f.conf" \
        || fail "$f: caller-supplied Forwarded header is not blanked"
    grep -Eq '^[[:space:]]*proxy_set_header X-Real-IP \$remote_addr;' "$WORK_DIR/$f.conf" \
        || fail "$f: X-Real-IP is not set from the client address"
done
# Security headers survive PROXY mode and the inheritance guard still holds.
grep -Fq "add_header Strict-Transport-Security '$HSTS_VALUE' always;" "$WORK_DIR/tls-pp.conf" \
    || fail "tls-pp: HSTS header missing"
grep -Fq "add_header X-Content-Type-Options '$XCTO_VALUE' always;" "$WORK_DIR/tls-pp.conf" \
    || fail "tls-pp: X-Content-Type-Options header missing"
echo "PASS: static checks (default vs PROXY protocol render)"

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

for f in tls-pp tls-pp-untrusted; do
    docker run --rm \
        -v "$REPO_ROOT/nginx/nginx.conf:/etc/nginx/nginx.conf:ro" \
        -v "$WORK_DIR/$f.conf:/etc/nginx/conf.d/default.conf:ro" \
        -v "$WORK_DIR/certs:/certs:ro" \
        --entrypoint sh "$IMAGE" -c 'mkdir -p /run/nginx && nginx -t' \
        || fail "nginx -t rejected the rendered $f config"
done
docker run --rm \
    -v "$REPO_ROOT/nginx/nginx.conf:/etc/nginx/nginx.conf:ro" \
    -v "$WORK_DIR/default-pp.conf:/etc/nginx/conf.d/default.conf:ro" \
    --entrypoint sh "$IMAGE" -c 'mkdir -p /run/nginx && nginx -t' \
    || fail "nginx -t rejected the rendered plain PROXY protocol config"

echo "PASS: nginx -t on all rendered configs (default, PROXY protocol trusted/untrusted)"

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
    # Echo what the ingress forwards: used by the PROXY protocol tests.
    location = /echo {
        return 200 "xff=[$http_x_forwarded_for] rip=[$http_x_real_ip] peer=[$remote_addr] fwd=[$http_forwarded]\n";
    }
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

# The TLS server rejects unknown SNI/Host (nearai/infra#195), so every probe
# must present the configured DOMAIN as SNI + Host: connect to the published
# loopback port via --connect-to while keeping the domain in the URL.
BASE="https://$DOMAIN:$HOST_PORT"
CURL_CONNECT=(--connect-to "$DOMAIN:$HOST_PORT:127.0.0.1:$HOST_PORT")
for i in $(seq 1 30); do
    if [[ "$(curl -ks --max-time 2 "${CURL_CONNECT[@]}" "$BASE/nginx-health" || true)" == *ok* ]]; then
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
    raw="$(curl -ksi --max-time 15 "${CURL_CONNECT[@]}" "$BASE$path" | tr -d '\r')"
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
read -r sse_status sse_ct sse_ttfb sse_total < <(curl -ksN --max-time 60 "${CURL_CONNECT[@]}" -o "$sse_out" \
    -w '%{http_code} %{content_type} %{time_starttransfer} %{time_total}\n' "$BASE/sse")
[[ "$sse_status" == "200" ]] || fail "/sse: expected 200, got $sse_status"
[[ "$sse_ct" == *"text/event-stream"* ]] || fail "/sse: expected text/event-stream, got $sse_ct"
sse_got="$(wc -c <"$sse_out")"
[[ "$sse_got" == "$SSE_SIZE" ]] || fail "/sse: body truncated ($sse_got of $SSE_SIZE bytes)"
awk -v ttfb="$sse_ttfb" -v total="$sse_total" 'BEGIN { exit !(total - ttfb >= 1.0) }' \
    || fail "/sse: response was not streamed (TTFB $sse_ttfb vs total $sse_total)"
check_headers /sse 200
echo "PASS: /sse streamed (TTFB ${sse_ttfb}s, total ${sse_total}s, $sse_got bytes intact)"

# --- 4. Client address handling ------------------------------------------------

# Default mode (unchanged behaviour): the ingress appends its TCP peer to a
# caller-supplied X-Forwarded-For, and still advertises HTTP/3.
echo_out="$(curl -ks --max-time 15 "${CURL_CONNECT[@]}" -H 'X-Forwarded-For: 1.2.3.4' "$BASE/echo")"
[[ "$echo_out" == "xff=[1.2.3.4, "* ]] || fail "default mode: expected legacy appended X-Forwarded-For, got: $echo_out"
curl -ksi --max-time 15 "${CURL_CONNECT[@]}" "$BASE/ok" | tr -d '\r' | grep -qi '^alt-svc: h3=' \
    || fail "default mode: Alt-Svc advertisement missing"
echo "PASS: default mode unchanged (legacy X-Forwarded-For append, Alt-Svc present)"

# PROXY protocol mode: two ingresses, one trusting the test client's source
# range, one trusting an address nobody uses.
PP_PORT="$((HOST_PORT + 1))"
PPU_PORT="$((HOST_PORT + 2))"

start_pp_ingress() {
    local ctr="$1" port="$2" conf="$3"
    docker run -d --name "$ctr" --network "$NET" -p "127.0.0.1:$port:8443" \
        -v "$REPO_ROOT/nginx/nginx.conf:/etc/nginx/nginx.conf:ro" \
        -v "$WORK_DIR/$conf:/etc/nginx/conf.d/default.conf:ro" \
        -v "$WORK_DIR/certs:/certs:ro" \
        --entrypoint sh "$IMAGE" -c 'mkdir -p /run/nginx && exec nginx -g "daemon off;"' >/dev/null
}
start_pp_ingress "$PP_CTR" "$PP_PORT" tls-pp.conf
start_pp_ingress "$PPU_CTR" "$PPU_PORT" tls-pp-untrusted.conf

# pp_request <port> <proxy-line|v2|none> [<path>] -> prints the HTTP response
# (status line + body) or "NO-RESPONSE". Sends the PROXY header (if any), then
# TLS (SNI + Host = DOMAIN), then a request carrying spoofed forwarding headers.
pp_request() {
    python3 -I - "$1" "$2" "$DOMAIN" "${3:-/echo}" <<'PY'
import socket, ssl, struct, sys
port, mode, domain, path = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
try:
    s = socket.create_connection(("127.0.0.1", port), timeout=10)
    if mode == "v2":
        hdr = b"\r\n\r\n\x00\r\nQUIT\n" + b"\x21\x11" + struct.pack("!H", 12)
        hdr += socket.inet_aton("198.51.100.7") + socket.inet_aton("10.0.0.1") + struct.pack("!HH", 40000, 8443)
        s.sendall(hdr)
    elif mode != "none":
        s.sendall(mode.encode() + b"\r\n")
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    t = ctx.wrap_socket(s, server_hostname=domain)
    t.sendall(("GET %s HTTP/1.1\r\nHost: %s\r\nX-Forwarded-For: 1.2.3.4, 5.6.7.8\r\n"
               "X-Real-IP: 9.9.9.9\r\nForwarded: for=8.8.8.8\r\nConnection: close\r\n\r\n" % (path, domain)).encode())
    data = b""
    while True:
        c = t.recv(4096)
        if not c:
            break
        data += c
    text = data.decode("latin1").replace("\r", "")
    print(text.split("\n", 1)[0], text.rsplit("\n\n", 1)[-1].strip())
except Exception:
    print("NO-RESPONSE")
PY
}

for i in $(seq 1 30); do
    [[ "$(pp_request "$PP_PORT" "PROXY TCP4 198.51.100.7 10.0.0.1 40000 8443" /nginx-health)" == *"200"* ]] && break
    [[ "$i" == "30" ]] && { docker logs "$PP_CTR" >&2 || true; fail "PROXY protocol ingress did not become ready"; }
    sleep 1
done

# Trusted source: the PROXY-header address wins, every caller-supplied value is
# discarded (single value, no comma chain).
got="$(pp_request "$PP_PORT" "PROXY TCP4 198.51.100.7 10.0.0.1 40000 8443")"
[[ "$got" == *"xff=[198.51.100.7] rip=[198.51.100.7]"* ]] || fail "trusted v1 IPv4: got: $got"
got="$(pp_request "$PP_PORT" "PROXY TCP6 2001:db8::7 2001:db8::1 40000 8443")"
[[ "$got" == *"xff=[2001:db8::7] rip=[2001:db8::7]"* ]] || fail "trusted v1 IPv6: got: $got"
got="$(pp_request "$PP_PORT" v2)"
[[ "$got" == *"xff=[198.51.100.7] rip=[198.51.100.7]"* ]] || fail "trusted v2: got: $got"
[[ "$got" == *"fwd=[]"* ]] || fail "trusted v2: caller-supplied Forwarded header reached the backend: $got"
echo "PASS: trusted PROXY header sets X-Forwarded-For/X-Real-IP, spoofed values and Forwarded discarded (v1 IPv4, v1 IPv6, v2)"

# No PROXY header at all: the listener requires one, so the connection is refused.
got="$(pp_request "$PP_PORT" none)"
[[ "$got" == "NO-RESPONSE" ]] || fail "connection without PROXY header should be refused, got: $got"
echo "PASS: connection without a PROXY header is refused"

# Untrusted source: a PROXY header is parsed but not honoured; neither the
# claimed address nor the caller's values reach the backend.
got="$(pp_request "$PPU_PORT" "PROXY TCP4 198.51.100.7 10.0.0.1 40000 8443")"
[[ "$got" == *"200"* ]] || fail "untrusted-source request should still be served, got: $got"
for bad in 198.51.100.7 1.2.3.4 5.6.7.8 9.9.9.9 8.8.8.8; do
    [[ "$got" != *"$bad"* ]] || fail "untrusted PROXY source: $bad leaked to the backend: $got"
done
[[ "$got" =~ xff=\[([0-9.]+)\]\ rip=\[([0-9.]+)\] ]] && [[ "${BASH_REMATCH[1]}" == "${BASH_REMATCH[2]}" ]] \
    || fail "untrusted PROXY source: expected a single TCP-peer address in both headers, got: $got"
echo "PASS: PROXY header from an untrusted source is ignored (peer address used, nothing caller-supplied forwarded)"

# PROXY mode serves no HTTP/3: no Alt-Svc, and nothing listens on UDP 8443.
alt="$(python3 -I - "$PP_PORT" "$DOMAIN" <<'PY'
import socket, ssl, sys
port, domain = int(sys.argv[1]), sys.argv[2]
s = socket.create_connection(("127.0.0.1", port), timeout=10)
s.sendall(b"PROXY TCP4 198.51.100.7 10.0.0.1 40000 8443\r\n")
ctx = ssl.create_default_context(); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
t = ctx.wrap_socket(s, server_hostname=domain)
t.sendall(("GET /ok HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n" % domain).encode())
d = b""
while True:
    c = t.recv(4096)
    if not c: break
    d += c
print(d.decode("latin1").lower())
PY
)"
[[ "$alt" == *"strict-transport-security"* ]] || fail "PROXY mode response lacks the security headers"
[[ "$alt" != *"alt-svc"* ]] || fail "PROXY mode must not advertise Alt-Svc"
udp="$(docker exec "$PP_CTR" sh -c 'cat /proc/net/udp /proc/net/udp6 2>/dev/null | awk "NR>1 && \$2 ~ /:20FB\$/"' || true)"
[[ -z "$udp" ]] || fail "PROXY mode: something listens on UDP 8443: $udp"
echo "PASS: PROXY mode has no Alt-Svc and no UDP 8443 listener"

echo
echo "All header tests passed."
