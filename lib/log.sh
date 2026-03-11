#!/usr/bin/env bash
# Logging helpers

log_info() {
    echo "[INFO]  $(date -u '+%Y-%m-%d %H:%M:%S') $*"
}

log_warn() {
    echo "[WARN]  $(date -u '+%Y-%m-%d %H:%M:%S') $*" >&2
}

log_error() {
    echo "[ERROR] $(date -u '+%Y-%m-%d %H:%M:%S') $*" >&2
}
