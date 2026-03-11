#!/usr/bin/env bash
# S3 helper functions

s3_upload() {
    local local_path="$1"
    local s3_key="$2"

    aws s3 cp "$local_path" "s3://${S3_BUCKET}/${S3_PREFIX}/${s3_key}" --quiet
}

s3_download() {
    local s3_key="$1"
    local local_path="$2"

    aws s3 cp "s3://${S3_BUCKET}/${S3_PREFIX}/${s3_key}" "$local_path" --quiet
}

s3_exists() {
    local s3_key="$1"

    aws s3api head-object \
        --bucket "$S3_BUCKET" \
        --key "${S3_PREFIX}/${s3_key}" \
        >/dev/null 2>&1
}

s3_delete() {
    local s3_key="$1"

    aws s3 rm "s3://${S3_BUCKET}/${S3_PREFIX}/${s3_key}" --quiet
}
