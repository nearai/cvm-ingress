#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/lib/log.sh"
source "$SCRIPT_DIR/lib/validate.sh"

generate_nginx_config() {
    local template="$SCRIPT_DIR/nginx/default.conf.template"
    if [[ "$TLS_ENABLED" == "true" ]]; then
        template="$SCRIPT_DIR/nginx/tls.conf.template"
    fi
    log_info "Generating nginx config for $DOMAIN → $BACKEND_HOST:$BACKEND_PORT (TLS=$TLS_ENABLED)"
    export DOLLAR='$'
    envsubst < "$template" > /etc/nginx/conf.d/default.conf
}

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
    log_info "Encryption key derived"
}

ensure_s3_bucket() {
    if ! aws s3api head-bucket --bucket "$S3_BUCKET" 2>/dev/null; then
        log_info "Bucket $S3_BUCKET does not exist, creating..."
        if ! aws s3api create-bucket --bucket "$S3_BUCKET" --region "${AWS_DEFAULT_REGION:-us-east-1}" \
            --create-bucket-configuration LocationConstraint="${AWS_DEFAULT_REGION:-us-east-1}" 2>/dev/null; then
            log_error "Failed to create S3 bucket $S3_BUCKET"
            exit 1
        fi
        log_info "Bucket $S3_BUCKET created"
    fi
}

setup_tls() {
    source "$SCRIPT_DIR/lib/crypto.sh"
    source "$SCRIPT_DIR/lib/s3.sh"
    source "$SCRIPT_DIR/lib/lock.sh"
    source "$SCRIPT_DIR/lib/certs.sh"

    derive_encryption_key
    ensure_s3_bucket
    setup_cloudflare_credentials

    # Pull certs from S3
    if ! pull_certs; then
        log_warn "Failed to pull certs from S3, will attempt fresh request"
    fi

    # Request cert if none exist, or wait for another instance to provide them
    local attempts=0
    local max_attempts=60  # 60 * 5s = 5 min max wait
    while [[ ! -f "/certs/$DOMAIN/fullchain.pem" ]]; do
        if acquire_lock; then
            # We got the lock — check S3 again (another instance may have pushed while we waited)
            pull_certs || true
            if [[ ! -f "/certs/$DOMAIN/fullchain.pem" ]]; then
                log_info "No certs found, requesting new certificate..."
                renew_or_request || { log_error "Certificate request failed"; release_lock || true; exit 1; }
                push_certs || log_error "Failed to push certs to S3"
            fi
            release_lock || log_warn "Failed to release lock"
        else
            attempts=$((attempts + 1))
            if [[ "$attempts" -ge "$max_attempts" ]]; then
                log_error "Timed out waiting for certs after ${max_attempts} attempts"
                exit 1
            fi
            log_info "Lock held by another instance, waiting for certs (attempt $attempts/$max_attempts)..."
            sleep 5
            pull_certs || true
        fi
    done

    # Verify certs exist
    if [[ ! -f "/certs/$DOMAIN/fullchain.pem" ]] || [[ ! -f "/certs/$DOMAIN/privkey.pem" ]]; then
        log_error "Certificate files not found after setup, cannot start nginx"
        exit 1
    fi
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
            nginx -s reload 2>/dev/null && log_info "Nginx reloaded" || true
        fi
    done
}

main() {
    log_info "cvm-ingress starting"

    validate_env

    if [[ "$TLS_ENABLED" == "true" ]]; then
        setup_tls
    fi

    generate_nginx_config

    if [[ "$TLS_ENABLED" == "true" ]]; then
        renewal_daemon &
    fi

    log_info "Starting nginx"
    exec nginx -g "daemon off;"
}

main "$@"
