#!/usr/bin/env bash
# Deletes one stack's remote state. Used after the cluster a stack lived inside
# is destroyed, so that the next apply does not refresh against resources that
# no longer exist. Bucket versioning keeps the object recoverable for a while.
set -euo pipefail

KEY="${1:?usage: $0 <stack path below $TF_PREFIX/tfstate>}"
: "${TF_STATE_BUCKET:?set TF_STATE_BUCKET - copy .env.example to .env}"
: "${AWS_ENDPOINT_URL_S3:?set AWS_ENDPOINT_URL_S3 - copy .env.example to .env}"

OBJECT="${TF_PREFIX:-opentofu}/tfstate/${KEY}/terraform.tfstate"
S3API=(aws --endpoint-url "$AWS_ENDPOINT_URL_S3" s3api)

if ! "${S3API[@]}" head-object --bucket "$TF_STATE_BUCKET" --key "$OBJECT" >/dev/null 2>&1; then
  exit 0
fi

"${S3API[@]}" delete-object --bucket "$TF_STATE_BUCKET" --key "$OBJECT" >/dev/null
"${S3API[@]}" delete-object --bucket "$TF_STATE_BUCKET" --key "${OBJECT}.tflock" >/dev/null 2>&1 || true
echo "==> removed remote state ${OBJECT} (its resources died with the cluster)"
