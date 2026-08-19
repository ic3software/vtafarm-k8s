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
TEMPLATE_DIR="${REPO_ROOT}/stacks/04-vtafarm-platform/_template"
CLUSTERS_DIR="${REPO_ROOT}/stacks/04-vtafarm-platform/clusters"
TARGET_DIR="${CLUSTERS_DIR}/${CLUSTER_NAME}"
RKE2_DIR="${REPO_ROOT}/stacks/03-rke2-clusters/clusters/${CLUSTER_NAME}"

if [ -e "$TARGET_DIR" ]; then
  echo "refusing to overwrite existing path: ${TARGET_DIR}" >&2
  exit 1
fi

# The directory name is what main.tf uses to locate the cluster's kubeconfig,
# so a name with no RKE2 root behind it would only fail later, during apply.
if [ ! -d "$RKE2_DIR" ]; then
  echo "no RKE2 cluster root at ${RKE2_DIR}" >&2
  echo "the platform installs into that cluster; create it first with:" >&2
  echo "  make new-rke2-cluster CLUSTER=${CLUSTER_NAME}" >&2
  exit 2
fi

mkdir -p "$CLUSTERS_DIR"
mkdir "$TARGET_DIR"
cp "$TEMPLATE_DIR"/*.tf "$TARGET_DIR/"
cp "$TEMPLATE_DIR"/*.example "$TARGET_DIR/"
if [ -f "${TEMPLATE_DIR}/.terraform.lock.hcl" ]; then
  cp "${TEMPLATE_DIR}/.terraform.lock.hcl" "$TARGET_DIR/"
fi
cp "${TARGET_DIR}/terraform.tfvars.example" "${TARGET_DIR}/terraform.tfvars"

for config_file in backend.tf.example main.tf; do
  temporary_file="$(mktemp "${TARGET_DIR}/.${config_file}.XXXXXX")"
  sed \
    -e "s/REPLACE_CLUSTER_NAME/${CLUSTER_NAME}/g" \
    -e 's|source = "../../../modules/vtafarm-platform"|source = "../../../../modules/vtafarm-platform"|' \
    "${TARGET_DIR}/${config_file}" >"$temporary_file"
  mv "$temporary_file" "${TARGET_DIR}/${config_file}"
done

echo "created ${TARGET_DIR}"
echo "next: make kubeconfig-rke2 CLUSTER=${CLUSTER_NAME} (if you have not already)"
echo "then:  make apply-vtafarm-platform CLUSTER=${CLUSTER_NAME}"
