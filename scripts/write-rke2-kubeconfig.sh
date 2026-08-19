#!/usr/bin/env bash
#
# Writes one RKE2 cluster's kubeconfig, pointed at its API server directly.
#
# Rancher returns a kubeconfig whose current context is its own cluster proxy,
# https://<rancher>/k8s/clusters/<id>. That proxy rate-limits: concurrent
# requests come back 429, which during a Helm install surfaces as
# `unable to recognize ""` or a release left in a failed state. The authorized
# cluster endpoint contexts in the same kubeconfig reach the API server without
# that limit, so take the CA and token from one of those and aim them at the
# load balancer rather than at the single node Rancher named.
#
# Usage: write-rke2-kubeconfig.sh <rke2-cluster-dir> <destination>
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <rke2-cluster-dir> <destination>" >&2
  exit 2
fi

CLUSTER_DIR="$1"
DEST="$2"
CLUSTER_NAME="$(basename "$CLUSTER_DIR")"

command -v kubectl >/dev/null 2>&1 || {
  echo "==> ERROR: kubectl not found in PATH" >&2
  exit 1
}

not_ready() {
  echo "==> ERROR: $1" >&2
  echo "    Wait for the cluster to become Active, then: make refresh-rke2 CLUSTER=${CLUSTER_NAME}" >&2
  exit 1
}

RAW="$(mktemp "${CLUSTER_DIR}/.kubeconfig.raw.yaml.XXXXXX")"
OUT="$(mktemp "${CLUSTER_DIR}/.kubeconfig.out.yaml.XXXXXX")"
trap 'rm -f "$RAW" "$OUT"' EXIT

tofu -chdir="$CLUSTER_DIR" output -raw kube_config >"$RAW" 2>/dev/null || true
[ -s "$RAW" ] || not_ready "Rancher has not returned a kubeconfig yet."

SERVER="$(tofu -chdir="$CLUSTER_DIR" output -raw kubernetes_api_endpoint 2>/dev/null || true)"
[ -n "$SERVER" ] || not_ready "stack 03 has no kubernetes_api_endpoint output yet."

# Every context whose server is a real API server ends in :6443; Rancher's proxy
# context is the only one that does not.
ACE_CLUSTER="$(kubectl --kubeconfig="$RAW" config view \
  -o jsonpath='{range .clusters[*]}{.name}{" "}{.cluster.server}{"\n"}{end}' 2>/dev/null |
  awk '$2 ~ /:6443$/ {print $1; exit}')"
[ -n "$ACE_CLUSTER" ] || not_ready "the kubeconfig has no authorized cluster endpoint context."

CA="$(kubectl --kubeconfig="$RAW" config view --raw \
  -o jsonpath="{.clusters[?(@.name==\"${ACE_CLUSTER}\")].cluster.certificate-authority-data}" 2>/dev/null)"
TOKEN="$(kubectl --kubeconfig="$RAW" config view --raw \
  -o jsonpath='{.users[0].user.token}' 2>/dev/null)"
[ -n "$CA" ] && [ -n "$TOKEN" ] || not_ready "the authorized cluster endpoint context carries no CA or token."

# Written out by hand rather than minified from $RAW so the cluster, user and
# context all take the cluster's name. merge-kubeconfig.sh replaces entries by
# name, and only replaces all three when they agree.
cat >"$OUT" <<EOF
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority-data: ${CA}
    server: ${SERVER}
  name: ${CLUSTER_NAME}
users:
- name: ${CLUSTER_NAME}
  user:
    token: ${TOKEN}
contexts:
- context:
    cluster: ${CLUSTER_NAME}
    user: ${CLUSTER_NAME}
  name: ${CLUSTER_NAME}
current-context: ${CLUSTER_NAME}
EOF

kubectl --kubeconfig="$OUT" config current-context >/dev/null 2>&1 ||
  not_ready "the kubeconfig just written is not parseable."

install -m 600 "$OUT" "$DEST"
echo "wrote ${DEST} (${SERVER})"
