#!/usr/bin/env bash
# Certificate management: pull, push, request, renew, export

ARCHIVE_NAME="certs.tar.enc"
CHECKSUM_FILE="/tmp/certs.checksum"
CERT_PATH="/certs"

_compute_checksum() {
    tar cf - -C /etc/letsencrypt . 2>/dev/null | sha256sum | awk '{print $1}'
}

setup_cloudflare_credentials() {
    local creds_file="/tmp/cloudflare.ini"
    echo "dns_cloudflare_api_token = ${CLOUDFLARE_API_TOKEN}" > "$creds_file"
    chmod 600 "$creds_file"
    log_info "Cloudflare credentials written"
}

pull_certs() {
    log_info "Pulling certificates from S3..."

    if ! s3_exists "$ARCHIVE_NAME"; then
        log_info "No certificate archive found in S3, starting fresh"
        return 0
    fi

    local enc_file="/tmp/certs.tar.enc"
    local tar_file="/tmp/certs.tar"

    if ! s3_download "$ARCHIVE_NAME" "$enc_file"; then
        log_error "Failed to download certificate archive from S3"
        return 1
    fi

    if ! decrypt_file "$enc_file" "$tar_file"; then
        log_error "Failed to decrypt certificate archive"
        rm -f "$enc_file" "$tar_file"
        return 1
    fi

    mkdir -p /etc/letsencrypt
    tar xf "$tar_file" -C /etc/letsencrypt
    rm -f "$enc_file" "$tar_file"

    _compute_checksum > "$CHECKSUM_FILE"
    log_info "Certificates pulled and decrypted"
    export_certs
}

push_certs() {
    log_info "Checking for certificate changes..."

    local current_checksum
    current_checksum=$(_compute_checksum)

    if [[ -f "$CHECKSUM_FILE" ]] && [[ "$current_checksum" == "$(cat "$CHECKSUM_FILE")" ]]; then
        log_info "No certificate changes detected, skipping push"
        return 0
    fi

    log_info "Certificate changes detected, pushing to S3..."

    local tar_file="/tmp/certs.tar"
    local enc_file="/tmp/certs.tar.enc"

    tar cf "$tar_file" -C /etc/letsencrypt .

    if ! encrypt_file "$tar_file" "$enc_file"; then
        log_error "Failed to encrypt certificate archive"
        rm -f "$tar_file" "$enc_file"
        return 1
    fi

    if ! s3_upload "$enc_file" "$ARCHIVE_NAME"; then
        log_error "Failed to upload certificate archive to S3"
        rm -f "$tar_file" "$enc_file"
        return 1
    fi

    rm -f "$tar_file" "$enc_file"
    echo "$current_checksum" > "$CHECKSUM_FILE"
    log_info "Certificates encrypted and pushed to S3"
}

request_cert() {
    log_info "Requesting certificate for: $DOMAIN"

    local -a certbot_args=(
        certonly
        --dns-cloudflare
        --dns-cloudflare-credentials /tmp/cloudflare.ini
        --key-type ecdsa
        --elliptic-curve secp256r1
        --non-interactive
        --agree-tos
        --email "$CERTBOT_EMAIL"
        -d "$DOMAIN"
    )

    if [[ "$STAGING" == "true" ]]; then
        certbot_args+=(--staging)
    fi

    if certbot "${certbot_args[@]}"; then
        log_info "Certificate request successful"
        export_certs
        return 0
    else
        log_error "Certificate request failed"
        return 1
    fi
}

renew_certs() {
    log_info "Attempting certificate renewal..."

    local -a certbot_args=(
        renew
        --dns-cloudflare
        --dns-cloudflare-credentials /tmp/cloudflare.ini
        --non-interactive
    )

    if certbot "${certbot_args[@]}"; then
        log_info "Certificate renewal check complete"
        export_certs
        return 0
    else
        log_error "Certificate renewal failed"
        return 1
    fi
}

renew_or_request() {
    if [[ -d /etc/letsencrypt/live ]] && [[ -n "$(ls -A /etc/letsencrypt/live/ 2>/dev/null)" ]]; then
        renew_certs
    else
        request_cert
    fi
}

export_certs() {
    if [[ ! -d /etc/letsencrypt/live ]]; then
        return 0
    fi

    log_info "Exporting certificates to $CERT_PATH"
    local dest="$CERT_PATH/$DOMAIN"
    mkdir -p "$dest"

    for domain_dir in /etc/letsencrypt/live/*/; do
        local domain
        domain=$(basename "$domain_dir")
        [[ "$domain" == "README" ]] && continue

        for file in fullchain.pem privkey.pem chain.pem cert.pem; do
            if [[ -f "$domain_dir/$file" ]]; then
                cp -L "$domain_dir/$file" "$dest/$file"
            fi
        done

        log_info "  Exported certs for $domain → $dest"
        break  # Single domain, take the first live dir
    done
}
