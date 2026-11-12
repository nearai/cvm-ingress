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
#   5. PROXY protocol mode (PROXY_PROTOCOL=true + REAL_IP_FROM): the env
#      validation accepts/rejects the right inputs (missing or wildcard source,
#      junk, bad boolean), both templates render under it and pass `nginx -t`,
#      and the effective config has proxy_protocol on every TCP listener,
#      trusts only the configured source and has no QUIC listener. Default
#      mode must carry none of that. Runtime behaviour is in
#      tests/test-headers.sh.
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
    [[ "$mode" == tls* ]] && extra_mounts=(-v "$WORKDIR/certs:/certs:ro")

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

# --- PROXY protocol mode (opt-in) ---------------------------------------------

# validate_env in a subshell, as entrypoint.sh would run it. Prints nothing;
# returns validate_env's status.
run_validate() {
    (
        env "$@" bash -c 'source "'"$SCRIPT_DIR"'/lib/log.sh"; source "'"$SCRIPT_DIR"'/lib/validate.sh"; validate_env' >/dev/null 2>&1
    )
}
expect_valid()   { run_validate DOMAIN="$DOMAIN" "$@" || fail "validate_env rejected: $*"; }
expect_invalid() { run_validate DOMAIN="$DOMAIN" "$@" && fail "validate_env accepted: $*"; return 0; }

expect_valid                                           # default: off, no REAL_IP_FROM needed
expect_valid PROXY_PROTOCOL=false
expect_valid PROXY_PROTOCOL=true REAL_IP_FROM=10.0.2.2
expect_valid PROXY_PROTOCOL=true REAL_IP_FROM="10.0.2.2, 192.168.0.0/16,fd00::/8"
expect_invalid PROXY_PROTOCOL=true                      # trusted source is required
expect_invalid PROXY_PROTOCOL=true REAL_IP_FROM=
expect_invalid PROXY_PROTOCOL=true REAL_IP_FROM=0.0.0.0/0
expect_invalid PROXY_PROTOCOL=true REAL_IP_FROM=::/0
expect_invalid PROXY_PROTOCOL=true REAL_IP_FROM=0.0.0.0
expect_invalid PROXY_PROTOCOL=true REAL_IP_FROM=10.0.0.0/0
expect_invalid PROXY_PROTOCOL=true REAL_IP_FROM=all
expect_invalid PROXY_PROTOCOL=true REAL_IP_FROM="10.0.2.2;"
expect_invalid PROXY_PROTOCOL=true REAL_IP_FROM="unix:"
expect_invalid PROXY_PROTOCOL=yes REAL_IP_FROM=10.0.2.2
echo "OK: PROXY protocol env validation"

# Render under PROXY protocol mode with the variables lib/validate.sh derives.
render_pp() {
    local template=$1 out=$2
    (
        source "$SCRIPT_DIR/lib/log.sh"
        source "$SCRIPT_DIR/lib/validate.sh"
        export DOMAIN BACKEND_HOST BACKEND_PORT DOLLAR='$'
        PROXY_PROTOCOL=true REAL_IP_FROM="10.0.2.2" validate_env >/dev/null 2>&1
        envsubst < "$SCRIPT_DIR/nginx/$template" > "$WORKDIR/$out"
    )
}
render_pp default.conf.template default-pp.conf
render_pp tls.conf.template tls-pp.conf
chmod -R a+rX "$WORKDIR"

check_config plain-pp default-pp.conf
check_config tls-pp tls-pp.conf

dump_of() {
    local conf=$1 extra_mounts=()
    [[ "$conf" == tls* ]] && extra_mounts=(-v "$WORKDIR/certs:/certs:ro")
    docker run --rm --tmpfs /run/nginx \
        -v "$SCRIPT_DIR/nginx/nginx.conf:/etc/nginx/nginx.conf:ro" \
        -v "$WORKDIR/$conf:/etc/nginx/conf.d/default.conf:ro" \
        "${extra_mounts[@]}" "$BASE_IMAGE" nginx -T 2>/dev/null
}
for conf in default.conf tls.conf default-pp.conf tls-pp.conf; do
    dump=$(dump_of "$conf")
    # nginx -T echoes raw file text; drop comment lines (incl. the commented-out
    # QUIC toggles) so only active directives are judged.
    dump=$(grep -Ev '^[[:space:]]*#' <<<"$dump")
    listens=$(grep -E '^[[:space:]]*listen ' <<<"$dump")
    case "$conf" in
        *-pp.conf)
            [[ -n "$listens" ]] || fail "$conf: no listeners in effective config"
            grep -vq 'proxy_protocol' <<<"$listens" && fail "$conf: a listener lacks proxy_protocol: $(grep -v proxy_protocol <<<"$listens")"
            grep -Eq '^[[:space:]]*(listen .*quic|http3 |add_header Alt-Svc)' <<<"$dump" && fail "$conf: QUIC/HTTP3/Alt-Svc present in effective config"
            grep -q 'set_real_ip_from 10.0.2.2;' <<<"$dump" || fail "$conf: trusted source missing"
            grep -q 'real_ip_header proxy_protocol;' <<<"$dump" || fail "$conf: real_ip_header proxy_protocol missing"
            grep -q 'proxy_set_header X-Forwarded-For \$remote_addr;' <<<"$dump" || fail "$conf: X-Forwarded-For not overwritten"
            ;;
        *)
            grep -Eq 'proxy_protocol|set_real_ip_from|real_ip_header' <<<"$dump" && fail "$conf: default mode contains PROXY protocol/realip config"
            grep -q 'proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;' <<<"$dump" || fail "$conf: default X-Forwarded-For changed"
            ;;
    esac
done
echo "OK: effective config: PROXY mode on every listener, no QUIC, source pinned; default mode untouched"

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
