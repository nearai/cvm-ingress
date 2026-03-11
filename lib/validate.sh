#!/usr/bin/env bash
# Validate required environment variables on startup

validate_env() {
    local missing=0

    for var in DOMAIN CERTBOT_EMAIL CLOUDFLARE_API_TOKEN S3_BUCKET; do
        if [[ -z "${!var}" ]]; then
            log_error "Required environment variable $var is not set"
            missing=1
        fi
    done

    if [[ "$missing" -eq 1 ]]; then
        log_error "Missing required environment variables, exiting"
        exit 1
    fi

    # Set defaults
    export S3_PREFIX="${S3_PREFIX:-cvm-ingress}"
    export BACKEND_HOST="${BACKEND_HOST:-127.0.0.1}"
    export BACKEND_PORT="${BACKEND_PORT:-3000}"
    export LOCK_TTL="${LOCK_TTL:-600}"
    export STAGING="${STAGING:-false}"
    export RENEWAL_INTERVAL="${RENEWAL_INTERVAL:-43200}"

    log_info "Configuration:"
    log_info "  DOMAIN=$DOMAIN"
    log_info "  CERTBOT_EMAIL=$CERTBOT_EMAIL"
    log_info "  S3_BUCKET=$S3_BUCKET"
    log_info "  S3_PREFIX=$S3_PREFIX"
    log_info "  BACKEND_HOST=$BACKEND_HOST"
    log_info "  BACKEND_PORT=$BACKEND_PORT"
    log_info "  LOCK_TTL=${LOCK_TTL}s"
    log_info "  STAGING=$STAGING"
    log_info "  RENEWAL_INTERVAL=${RENEWAL_INTERVAL}s"
}
