#!/usr/bin/env bash
# Distributed locking via S3 objects

LOCK_KEY=".lock"

acquire_lock() {
    local now
    now=$(date +%s)

    # Check if lock exists
    if s3_exists "$LOCK_KEY"; then
        local lock_file="/tmp/lock.json"
        if s3_download "$LOCK_KEY" "$lock_file" 2>/dev/null; then
            local holder timestamp
            holder=$(python3 -c "import json,sys; print(json.load(open('$lock_file'))['holder'])" 2>/dev/null)
            timestamp=$(python3 -c "import json,sys; print(json.load(open('$lock_file'))['timestamp'])" 2>/dev/null)
            rm -f "$lock_file"

            if [[ -n "$timestamp" ]]; then
                local age=$(( now - timestamp ))
                if [[ "$age" -lt "$LOCK_TTL" && "$holder" != "$HOSTNAME" ]]; then
                    log_warn "Lock held by $holder (age: ${age}s), skipping this cycle"
                    return 1
                fi
                if [[ "$age" -ge "$LOCK_TTL" ]]; then
                    log_warn "Stale lock from $holder (age: ${age}s), taking over"
                fi
            fi
        fi
    fi

    # Write our lock
    local lock_data="{\"holder\": \"$HOSTNAME\", \"timestamp\": $now}"
    echo "$lock_data" > /tmp/lock.json
    s3_upload /tmp/lock.json "$LOCK_KEY"
    rm -f /tmp/lock.json
    log_info "Lock acquired by $HOSTNAME"
    return 0
}

release_lock() {
    s3_delete "$LOCK_KEY"
    log_info "Lock released"
}
