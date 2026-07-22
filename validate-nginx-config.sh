#!/usr/bin/env bash
# Renders nginx/default.conf.template and nginx/tls.conf.template the same way
# entrypoint.sh does (envsubst with DOLLAR='$') and validates each result with
# `nginx -t` inside the image built from this repository's Dockerfile, so the
# check runs against the exact nginx binary and userland tooling (gettext-base,
# openssl) that the deployed image ships — not whatever the base image happens
# to bundle.
#
# Usage: ./validate-nginx-config.sh
#   VALIDATE_IMAGE=<ref>  validate inside <ref> instead of building the
#                         Dockerfile first (local iteration shortcut; CI
#                         always builds).
set -euo pipefail

cd "$(dirname "$0")"

IMAGE="${VALIDATE_IMAGE:-}"
if [[ -z "$IMAGE" ]]; then
    IMAGE="cvm-ingress-validate:local"
    echo "Building $IMAGE from ./Dockerfile"
    docker build -t "$IMAGE" .
fi
echo "Validating nginx templates inside $IMAGE"

docker run --rm -i --entrypoint bash -v "$PWD/nginx:/templates:ro" "$IMAGE" -s <<'SCRIPT'
set -euo pipefail

for tool in envsubst openssl nginx; do
    if ! command -v "$tool" >/dev/null; then
        echo "missing required tool in validation image: $tool" >&2
        exit 1
    fi
done

export DOMAIN=example.test BACKEND_HOST=backend BACKEND_PORT=8080 DOLLAR='$'

mkdir -p /run/nginx "/certs/$DOMAIN"
# Self-signed cert so the TLS template's ssl_certificate paths resolve.
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "/certs/$DOMAIN/privkey.pem" \
    -out "/certs/$DOMAIN/fullchain.pem" \
    -days 1 -subj "/CN=$DOMAIN" >/dev/null 2>&1

cp /templates/nginx.conf /etc/nginx/nginx.conf
mkdir -p /etc/nginx/conf.d
rm -f /etc/nginx/conf.d/*.conf

for template in default tls; do
    envsubst < "/templates/${template}.conf.template" > /etc/nginx/conf.d/default.conf
    echo "--- nginx -t (${template}.conf.template)"
    nginx -t
done
SCRIPT

echo "OK: both templates render and pass nginx -t"
