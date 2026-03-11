#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/lib/log.sh"
source "$SCRIPT_DIR/lib/validate.sh"

generate_nginx_config() {
    log_info "Generating nginx config for $DOMAIN → $BACKEND_HOST:$BACKEND_PORT"
    export DOLLAR='$'
    envsubst < "$SCRIPT_DIR/nginx/default.conf.template" > /etc/nginx/conf.d/default.conf
    log_info "Nginx config generated"
}

main() {
    log_info "cvm-ingress starting"

    validate_env

    generate_nginx_config

    log_info "Starting nginx (plain HTTP on 8443)"
    exec nginx -g "daemon off;"
}

main "$@"
