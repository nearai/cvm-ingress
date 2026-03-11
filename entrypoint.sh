#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Source libraries
source "$SCRIPT_DIR/lib/log.sh"
source "$SCRIPT_DIR/lib/validate.sh"
source "$SCRIPT_DIR/lib/crypto.sh"
source "$SCRIPT_DIR/lib/s3.sh"
source "$SCRIPT_DIR/lib/lock.sh"
source "$SCRIPT_DIR/lib/certs.sh"

derive_encryption_key() {
    log_info "Deriving encryption key from dstack..."

    if [[ ! -S /var/run/dstack.sock ]]; then
        log_error "dstack socket not found at /var/run/dstack.sock"
        exit 1
    fi

    ENCRYPTION_KEY=$(curl -s --unix-socket /var/run/dstack.sock \
        "http://localhost/GetKey?path=/ingress/cert-encryption" | jq -r '.key' | head -c 64)

    if [[ -z "$ENCRYPTION_KEY" || "$ENCRYPTION_KEY" == "null" ]]; then
        log_error "Failed to derive encryption key from dstack"
        exit 1
    fi

    export ENCRYPTION_KEY
    log_info "Encryption key derived successfully"
}

generate_nginx_config() {
    log_info "Generating nginx config for $DOMAIN → $BACKEND_HOST:$BACKEND_PORT"
    export DOLLAR='$'
    envsubst < "$SCRIPT_DIR/nginx/default.conf.template" > /etc/nginx/conf.d/default.conf
    log_info "Nginx config generated"
}

renewal_daemon() {
    log_info "Starting renewal daemon (interval: ${RENEWAL_INTERVAL}s)"
    while true; do
        sleep "$RENEWAL_INTERVAL"
        log_info "Renewal daemon: checking certificates..."
        if acquire_lock; then
            renew_certs || log_error "Certificate renewal failed"
            push_certs || log_error "Failed to push certs to S3"
            export_certs
            release_lock || log_warn "Failed to release lock"
            nginx -s reload 2>/dev/null && log_info "Nginx reloaded after renewal check" || true
        fi
    done
}

main() {
    log_info "cvm-ingress starting"

    # Step 1: Validate env vars
    validate_env

    # Step 2: Derive encryption key from dstack
    derive_encryption_key

    # Step 3: Setup Cloudflare credentials
    setup_cloudflare_credentials

    # Step 4: Pull certs from S3 (if they exist)
    if ! pull_certs; then
        log_warn "Failed to pull certs from S3, will attempt fresh request"
    fi

    # Step 5: Request cert if none exist
    if [[ ! -f "/certs/$DOMAIN/fullchain.pem" ]]; then
        log_info "No certs found, requesting new certificate..."
        if acquire_lock; then
            renew_or_request || { log_error "Certificate request failed"; exit 1; }
            push_certs || log_error "Failed to push certs to S3"
            release_lock || log_warn "Failed to release lock"
        else
            log_error "Could not acquire lock for initial cert request"
            exit 1
        fi
    fi

    # Step 6: Verify certs exist before starting nginx
    if [[ ! -f "/certs/$DOMAIN/fullchain.pem" ]] || [[ ! -f "/certs/$DOMAIN/privkey.pem" ]]; then
        log_error "Certificate files not found after setup, cannot start nginx"
        exit 1
    fi

    # Step 7: Generate nginx config
    generate_nginx_config

    # Step 8: Start renewal daemon in background
    renewal_daemon &

    # Step 9: Start nginx in foreground
    log_info "Starting nginx"
    exec nginx -g "daemon off;"
}

main "$@"
