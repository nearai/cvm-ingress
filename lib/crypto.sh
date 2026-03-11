#!/usr/bin/env bash
# Encrypt/decrypt files using openssl AES-256-CBC

encrypt_file() {
    local input="$1"
    local output="$2"

    openssl enc -aes-256-cbc -salt -pbkdf2 -pass env:ENCRYPTION_KEY \
        -in "$input" -out "$output"
}

decrypt_file() {
    local input="$1"
    local output="$2"

    openssl enc -aes-256-cbc -d -salt -pbkdf2 -pass env:ENCRYPTION_KEY \
        -in "$input" -out "$output"
}
