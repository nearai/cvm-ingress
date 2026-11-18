#!/usr/bin/env bash
# Validate required environment variables on startup

# PROXY protocol mode (opt-in; PROXY_PROTOCOL=true). Derives the template
# variables the nginx templates substitute. They are deliberately all-empty
# when unset, and every use in the templates renders to the pre-existing
# behaviour in that case, so a bare `envsubst` (as several tests do) yields
# the default, PROXY-protocol-free config.
#
#   INGRESS_PP_LISTEN     " proxy_protocol" appended to each TCP listen line
#   INGRESS_QUIC_OFF      "#" prefix that comments out QUIC/HTTP3/Alt-Svc lines
#   INGRESS_XFF_LEGACY_OFF "#" prefix that comments out the pass-through
#                         X-Forwarded-For line
#   INGRESS_REAL_IP_CONF  set_real_ip_from/real_ip_header directives
#   INGRESS_XFF_CONF      X-Forwarded-For overwrite from the client address, Forwarded blanked
#
# REAL_IP_FROM is a comma/space separated list of IPs or CIDRs. Wildcards that
# would trust every peer (/0, 0.0.0.0, ::) are refused: the header is trusted
# only from a configured source, never from arbitrary callers.
derive_proxy_protocol_vars() {
    local entry ok=0 conf=""
    local -a entries
    IFS=', ' read -r -a entries <<<"$REAL_IP_FROM"
    for entry in "${entries[@]}"; do
        [[ -z "$entry" ]] && continue
        if [[ ! "$entry" =~ ^[0-9A-Fa-f:.]+(/[0-9]{1,3})?$ ]]; then
            log_error "REAL_IP_FROM entry '$entry' is not an IP address or CIDR"
            return 1
        fi
        if [[ "$entry" == */0 || "$entry" =~ ^(0\.0\.0\.0|::|0:0:0:0:0:0:0:0)(/|$) ]]; then
            log_error "REAL_IP_FROM entry '$entry' would trust every peer; name the actual source"
            return 1
        fi
        conf+="set_real_ip_from $entry;"$'\n    '
        ok=1
    done
    if [[ "$ok" -ne 1 ]]; then
        log_error "REAL_IP_FROM contains no usable address"
        return 1
    fi
    export INGRESS_PP_LISTEN=" proxy_protocol"
    export INGRESS_QUIC_OFF="#"
    export INGRESS_XFF_LEGACY_OFF="#"
    export INGRESS_REAL_IP_CONF="${conf}real_ip_header proxy_protocol;"
    # Forwarded (RFC 7239) is blanked too: chat-api falls back to it when
    # X-Forwarded-For does not parse, so a caller-supplied copy must not survive.
    export INGRESS_XFF_CONF='proxy_set_header X-Forwarded-For $remote_addr;
        proxy_set_header Forwarded "";'
}

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
    export PROXY_PROTOCOL="${PROXY_PROTOCOL:-false}"
    export REAL_IP_FROM="${REAL_IP_FROM:-}"

    if [[ "$PROXY_PROTOCOL" != "true" && "$PROXY_PROTOCOL" != "false" ]]; then
        log_error "PROXY_PROTOCOL must be 'true' or 'false' (got '$PROXY_PROTOCOL')"
        missing=1
    fi

    # TLS mode requires additional vars
    if [[ "$TLS_ENABLED" == "true" ]]; then
        for var in CERTBOT_EMAIL CLOUDFLARE_API_TOKEN S3_BUCKET; do
            if [[ -z "${!var}" ]]; then
                log_error "TLS_ENABLED=true but required variable $var is not set"
                missing=1
            fi
        done
    fi

    # PROXY protocol mode requires a trusted source for the header.
    if [[ "$PROXY_PROTOCOL" == "true" ]]; then
        if [[ -z "$REAL_IP_FROM" ]]; then
            log_error "PROXY_PROTOCOL=true but required variable REAL_IP_FROM is not set"
            missing=1
        elif ! derive_proxy_protocol_vars; then
            missing=1
        fi
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
    log_info "  PROXY_PROTOCOL=$PROXY_PROTOCOL"
    if [[ "$PROXY_PROTOCOL" == "true" ]]; then
        log_info "  REAL_IP_FROM=$REAL_IP_FROM"
        log_info "  QUIC/HTTP3 and Alt-Svc disabled (PROXY protocol cannot be carried over UDP)"
    fi
    if [[ "$TLS_ENABLED" == "true" ]]; then
        log_info "  CERTBOT_EMAIL=$CERTBOT_EMAIL"
        log_info "  S3_BUCKET=$S3_BUCKET"
        log_info "  S3_PREFIX=$S3_PREFIX"
        log_info "  STAGING=$STAGING"
        log_info "  RENEWAL_INTERVAL=${RENEWAL_INTERVAL}s"
    fi
}
