#!/usr/bin/env bash
# Validates the nginx configuration shipped in this repo without building the
# full image:
#
#   1. Renders default.conf.template and tls.conf.template exactly like
#      entrypoint.sh does (envsubst with DOLLAR='$').
#   2. Runs `nginx -t` and `nginx -T` inside the same pinned base image the
#      Dockerfile builds FROM, for both the plain and the TLS server config.
#   3. Asserts the effective config suppresses version disclosure
#      (`server_tokens off`, nearai/infra#194).
#   4. Boots each config and asserts the live `Server` response header carries
#      no version string.
#
# Requirements: docker, openssl, curl. Run from anywhere: ./test-nginx-config.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Single-source the nginx base image from the Dockerfile so this test always
# exercises the same binary the image ships.
BASE_IMAGE=$(awk '/^FROM /{print $2; exit}' "$SCRIPT_DIR/Dockerfile")
[[ -n "$BASE_IMAGE" ]] || { echo "FAIL: could not read base image from Dockerfile" >&2; exit 1; }
echo "Using base image: $BASE_IMAGE"

DOMAIN="ingress.test"
BACKEND_HOST="127.0.0.1"
BACKEND_PORT="8080"
PLAIN_PORT="18443"
TLS_PORT="18444"

WORKDIR=$(mktemp -d)
CONTAINERS=()
cleanup() {
    for c in "${CONTAINERS[@]:-}"; do
        [[ -n "$c" ]] && docker rm -f "$c" >/dev/null 2>&1 || true
    done
    rm -rf "$WORKDIR"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- Render templates the same way entrypoint.sh does -----------------------
render() {
    local template=$1 out=$2
    DOMAIN="$DOMAIN" BACKEND_HOST="$BACKEND_HOST" BACKEND_PORT="$BACKEND_PORT" DOLLAR='$' \
        envsubst < "$SCRIPT_DIR/nginx/$template" > "$WORKDIR/$out"
}
render default.conf.template default.conf
render tls.conf.template tls.conf

# --- Self-signed cert for the TLS server block ------------------------------
mkdir -p "$WORKDIR/certs/$DOMAIN"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout "$WORKDIR/certs/$DOMAIN/privkey.pem" \
    -out "$WORKDIR/certs/$DOMAIN/fullchain.pem" \
    -days 1 -subj "/CN=$DOMAIN" >/dev/null 2>&1

chmod -R a+rX "$WORKDIR"

# --- Config-test + effective-config assertions ------------------------------
check_config() {
    local mode=$1 conf=$2 extra_mounts=()
    [[ "$mode" == "tls" ]] && extra_mounts=(-v "$WORKDIR/certs:/certs:ro")

    docker run --rm --tmpfs /run/nginx \
        -v "$SCRIPT_DIR/nginx/nginx.conf:/etc/nginx/nginx.conf:ro" \
        -v "$WORKDIR/$conf:/etc/nginx/conf.d/default.conf:ro" \
        "${extra_mounts[@]}" \
        "$BASE_IMAGE" nginx -t \
        || fail "nginx -t failed for $mode config"

    local dump
    dump=$(docker run --rm --tmpfs /run/nginx \
        -v "$SCRIPT_DIR/nginx/nginx.conf:/etc/nginx/nginx.conf:ro" \
        -v "$WORKDIR/$conf:/etc/nginx/conf.d/default.conf:ro" \
        "${extra_mounts[@]}" \
        "$BASE_IMAGE" nginx -T 2>/dev/null)

    grep -q "server_tokens off;" <<<"$dump" \
        || fail "$mode: effective config does not contain 'server_tokens off'"
    grep -Eq "server_tokens[[:space:]]+(on|build)" <<<"$dump" \
        && fail "$mode: effective config re-enables server_tokens"
    echo "OK: $mode config passes nginx -t and suppresses server_tokens"
}
check_config plain default.conf
check_config tls tls.conf

# --- Runtime assertion: Server header has no version ------------------------
# Extra arguments after the URL are passed to curl. The TLS caller needs
# --connect-to so the probe presents the configured DOMAIN as SNI + Host:
# the TLS server rejects unknown SNI/Host (nearai/infra#195), so a bare
# https://127.0.0.1 probe would fail at the handshake.
assert_banner() {
    local name=$1 url=$2 headers
    shift 2
    for _ in $(seq 1 20); do
        headers=$(curl -skI --max-time 2 "$@" "$url" 2>/dev/null) && break
        sleep 0.5
    done
    [[ -n "${headers:-}" ]] || fail "$name: no response from $url"
    grep -iq '^server:' <<<"$headers" \
        || fail "$name: no Server header in response"
    grep -iEq '^server:[[:space:]]*nginx[[:space:]]*$' <<<"$headers" \
        || fail "$name: Server header discloses a version: $(grep -i '^server:' <<<"$headers")"
    echo "OK: $name Server header is version-free ($(grep -i '^server:' <<<"$headers" | tr -d '\r'))"
}

docker run -d --name cvm-ingress-test-plain --tmpfs /run/nginx \
    -v "$SCRIPT_DIR/nginx/nginx.conf:/etc/nginx/nginx.conf:ro" \
    -v "$WORKDIR/default.conf:/etc/nginx/conf.d/default.conf:ro" \
    -p "127.0.0.1:$PLAIN_PORT:8443" \
    "$BASE_IMAGE" nginx -g 'daemon off;' >/dev/null
CONTAINERS+=(cvm-ingress-test-plain)
assert_banner plain "http://127.0.0.1:$PLAIN_PORT/nginx-health"

docker run -d --name cvm-ingress-test-tls --tmpfs /run/nginx \
    -v "$SCRIPT_DIR/nginx/nginx.conf:/etc/nginx/nginx.conf:ro" \
    -v "$WORKDIR/tls.conf:/etc/nginx/conf.d/default.conf:ro" \
    -v "$WORKDIR/certs:/certs:ro" \
    -p "127.0.0.1:$TLS_PORT:8443" \
    "$BASE_IMAGE" nginx -g 'daemon off;' >/dev/null
CONTAINERS+=(cvm-ingress-test-tls)
assert_banner tls "https://$DOMAIN:$TLS_PORT/nginx-health" \
    --connect-to "$DOMAIN:$TLS_PORT:127.0.0.1:$TLS_PORT"

echo "All nginx config checks passed."
