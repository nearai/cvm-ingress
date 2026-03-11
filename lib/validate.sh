#!/usr/bin/env bash
# Validate required environment variables on startup

validate_env() {
    local missing=0

    for var in DOMAIN; do
        if [[ -z "${!var}" ]]; then
            log_error "Required environment variable $var is not set"
            missing=1
        fi
    done

    # Set defaults
    export BACKEND_HOST="${BACKEND_HOST:-127.0.0.1}"
    export BACKEND_PORT="${BACKEND_PORT:-3000}"
    export TLS_ENABLED="${TLS_ENABLED:-false}"
    export STAGING="${STAGING:-false}"
    export RENEWAL_INTERVAL="${RENEWAL_INTERVAL:-43200}"
    export LOCK_TTL="${LOCK_TTL:-600}"
    export S3_PREFIX="${S3_PREFIX:-cvm-ingress}"

    # TLS mode requires additional vars
    if [[ "$TLS_ENABLED" == "true" ]]; then
        for var in CERTBOT_EMAIL CLOUDFLARE_API_TOKEN S3_BUCKET; do
            if [[ -z "${!var}" ]]; then
                log_error "TLS_ENABLED=true but required variable $var is not set"
                missing=1
            fi
        done
    fi

    if [[ "$missing" -eq 1 ]]; then
        log_error "Missing required environment variables, exiting"
        exit 1
    fi

    log_info "Configuration:"
    log_info "  DOMAIN=$DOMAIN"
    log_info "  BACKEND_HOST=$BACKEND_HOST"
    log_info "  BACKEND_PORT=$BACKEND_PORT"
    log_info "  TLS_ENABLED=$TLS_ENABLED"
    if [[ "$TLS_ENABLED" == "true" ]]; then
        log_info "  CERTBOT_EMAIL=$CERTBOT_EMAIL"
        log_info "  S3_BUCKET=$S3_BUCKET"
        log_info "  S3_PREFIX=$S3_PREFIX"
        log_info "  STAGING=$STAGING"
        log_info "  RENEWAL_INTERVAL=${RENEWAL_INTERVAL}s"
    fi
}
