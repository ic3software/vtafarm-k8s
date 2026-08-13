#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <cluster-name>" >&2
  exit 2
fi

CLUSTER_NAME="$1"
if [[ ! "$CLUSTER_NAME" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
  echo "cluster name must be lowercase, DNS-safe, and contain no slashes" >&2
  exit 2
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE_DIR="${REPO_ROOT}/stacks/03-rke2-clusters/_template"
TARGET_DIR="${REPO_ROOT}/stacks/03-rke2-clusters/${CLUSTER_NAME}"

if [ -e "$TARGET_DIR" ]; then
  echo "refusing to overwrite existing path: ${TARGET_DIR}" >&2
  exit 1
fi

mkdir "$TARGET_DIR"
cp "$TEMPLATE_DIR"/*.tf "$TARGET_DIR/"
cp "$TEMPLATE_DIR"/*.example "$TARGET_DIR/"
if [ -f "${TEMPLATE_DIR}/.terraform.lock.hcl" ]; then
  cp "${TEMPLATE_DIR}/.terraform.lock.hcl" "$TARGET_DIR/"
fi
cp "${TARGET_DIR}/terraform.tfvars.example" "${TARGET_DIR}/terraform.tfvars"

for config_file in backend.tf.example; do
  temporary_file="$(mktemp "${TARGET_DIR}/.${config_file}.XXXXXX")"
  sed "s/REPLACE_CLUSTER_NAME/${CLUSTER_NAME}/g" \
    "${TARGET_DIR}/${config_file}" >"$temporary_file"
  mv "$temporary_file" "${TARGET_DIR}/${config_file}"
done

echo "created ${TARGET_DIR}"
echo "next: edit ${TARGET_DIR}/terraform.tfvars"
