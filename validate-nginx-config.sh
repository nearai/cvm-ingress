#!/usr/bin/env bash
# Renders nginx/default.conf.template and nginx/tls.conf.template the same way
# entrypoint.sh does (envsubst with DOLLAR='$') and validates each result with
# `nginx -t` inside the exact base image pinned in the Dockerfile, so the
# check runs against the nginx binary the deployed image ships.
#
# Usage: ./validate-nginx-config.sh
set -euo pipefail

cd "$(dirname "$0")"

IMAGE="$(sed -n 's/^FROM[[:space:]]\+\([^ ]\+\).*/\1/p' Dockerfile | head -1)"
if [[ -z "$IMAGE" ]]; then
    echo "Could not determine base image from Dockerfile" >&2
    exit 1
fi
echo "Validating nginx templates against $IMAGE"

docker run --rm -i -v "$PWD/nginx:/templates:ro" "$IMAGE" bash -s <<'SCRIPT'
set -euo pipefail
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
