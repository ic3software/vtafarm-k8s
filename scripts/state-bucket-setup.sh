#!/usr/bin/env bash
# One-time preparation of the state bucket: versioning, so a bad apply can be
# rolled back, and a retention rule, so versioning does not make the etcd
# snapshots in the same bucket grow without bound. Safe to re-run.
set -euo pipefail

: "${TF_STATE_BUCKET:?set TF_STATE_BUCKET - copy .env.example to .env}"
: "${AWS_ENDPOINT_URL_S3:?set AWS_ENDPOINT_URL_S3 - copy .env.example to .env}"

NONCURRENT_DAYS="${NONCURRENT_DAYS:-30}"
S3API=(aws --endpoint-url "$AWS_ENDPOINT_URL_S3" s3api)

echo "==> enabling versioning on ${TF_STATE_BUCKET}"
"${S3API[@]}" put-bucket-versioning \
  --bucket "$TF_STATE_BUCKET" \
  --versioning-configuration Status=Enabled

lifecycle_file="$(mktemp)"
trap 'rm -f "$lifecycle_file"' EXIT

# Two rules, not one: S3 rejects ExpiredObjectDeleteMarker in the same
# Expiration block as anything else.
cat >"$lifecycle_file" <<EOF
{
  "Rules": [
    {
      "ID": "expire-noncurrent-versions",
      "Status": "Enabled",
      "Filter": { "Prefix": "" },
      "NoncurrentVersionExpiration": { "NoncurrentDays": ${NONCURRENT_DAYS} },
      "Expiration": { "ExpiredObjectDeleteMarker": true }
    },
    {
      "ID": "abort-incomplete-uploads",
      "Status": "Enabled",
      "Filter": { "Prefix": "" },
      "AbortIncompleteMultipartUpload": { "DaysAfterInitiation": 7 }
    }
  ]
}
EOF

echo "==> keeping non-current versions for ${NONCURRENT_DAYS} days"
"${S3API[@]}" put-bucket-lifecycle-configuration \
  --bucket "$TF_STATE_BUCKET" \
  --lifecycle-configuration "file://${lifecycle_file}"

echo "==> versioning"
"${S3API[@]}" get-bucket-versioning --bucket "$TF_STATE_BUCKET"
echo "==> lifecycle"
"${S3API[@]}" get-bucket-lifecycle-configuration --bucket "$TF_STATE_BUCKET"
