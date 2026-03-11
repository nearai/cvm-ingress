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

    if [[ "$missing" -eq 1 ]]; then
        log_error "Missing required environment variables, exiting"
        exit 1
    fi

    # Set defaults
    export BACKEND_HOST="${BACKEND_HOST:-127.0.0.1}"
    export BACKEND_PORT="${BACKEND_PORT:-3000}"

    log_info "Configuration:"
    log_info "  DOMAIN=$DOMAIN"
    log_info "  BACKEND_HOST=$BACKEND_HOST"
    log_info "  BACKEND_PORT=$BACKEND_PORT"
}
