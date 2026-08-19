#!/usr/bin/env bash
#
# One-time Vault configuration, run once per cluster after `make apply-vtafarm-platform`
# and after the target Vault has been initialized and unsealed.
#
#   vault-bootstrap.sh transit   enable the transit engine, create the autounseal
#                                key, mint the farm Vault's unseal token and
#                                store it as the vault-transit-token secret
#   vault-bootstrap.sh farm      enable KV v2, Kubernetes auth and AppRole, write
#                                the vtafarm-api-admin policy and the API's role
#
# Both subcommands need VAULT_TOKEN set to the root token that
# `vault operator init` printed for THAT Vault - they are separate Vaults with
# separate roots. Everything else (port-forward, CA material) is handled here.
#
# Idempotent. Re-running `farm` rotates the AppRole secret_id by default; set
# SKIP_SECRET_ID=1 to update the policy and role without rotating it.
set -euo pipefail

VAULT_NS="${VAULT_NS:-vault}"
TRANSIT_NS="${TRANSIT_NS:-vault-transit}"
API_SECRET_NS="${API_SECRET_NS:-default}"

KV_MOUNT="${KV_MOUNT:-secret}"
K8S_AUTH_MOUNT="${K8S_AUTH_MOUNT:-kubernetes}"
APPROLE_MOUNT="${APPROLE_MOUNT:-approle}"
API_ROLE_NAME="${API_ROLE_NAME:-vtafarm-api}"
API_POLICY_NAME="${API_POLICY_NAME:-vtafarm-api-admin}"
TOKEN_SECRET="${TOKEN_SECRET:-vault-transit-token}"
API_SECRET_NAME="${API_SECRET_NAME:-vtafarm-api-vault}"

usage() {
  echo "usage: $0 <transit|farm>" >&2
  exit 2
}

[ "$#" -eq 1 ] || usage
TARGET="$1"

for binary in vault kubectl; do
  command -v "$binary" >/dev/null || {
    echo "${binary} is required but not on PATH" >&2
    exit 1
  }
done

: "${VAULT_TOKEN:?set VAULT_TOKEN to the root token from 'vault operator init' for this Vault}"
export VAULT_TOKEN

case "$TARGET" in
  transit)
    NAMESPACE="$TRANSIT_NS"
    SERVICE="vault-transit"
    TLS_SECRET="vault-transit-tls"
    ;;
  farm)
    NAMESPACE="$VAULT_NS"
    SERVICE="vault"
    TLS_SECRET="vault-tls"
    ;;
  *) usage ;;
esac

WORK_DIR="$(mktemp -d)"
PORT_FORWARD_PID=""
cleanup() {
  [ -n "$PORT_FORWARD_PID" ] && kill "$PORT_FORWARD_PID" 2>/dev/null || true
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# A free local port, so this never collides with a Vault UI port-forward the
# operator already has open.
LOCAL_PORT="${LOCAL_PORT:-18200}"

echo "==> Port-forwarding ${NAMESPACE}/${SERVICE} to 127.0.0.1:${LOCAL_PORT}"
kubectl port-forward -n "$NAMESPACE" "svc/${SERVICE}" "${LOCAL_PORT}:8200" >/dev/null 2>&1 &
PORT_FORWARD_PID=$!

kubectl get secret -n "$NAMESPACE" "$TLS_SECRET" \
  -o jsonpath='{.data.ca\.crt}' | base64 -d >"${WORK_DIR}/ca.crt"

export VAULT_ADDR="https://127.0.0.1:${LOCAL_PORT}"
export VAULT_CACERT="${WORK_DIR}/ca.crt"

for _ in $(seq 1 30); do
  vault status >/dev/null 2>&1 && break
  sleep 1
done
vault status >/dev/null

mount_exists() { # $1 = secrets|auth, $2 = mount path
  vault "$1" list -format=json 2>/dev/null | grep -q "\"$2/\""
}

if [ "$TARGET" = "transit" ]; then
  echo "==> Enabling the transit engine"
  vault secrets enable transit 2>/dev/null || echo "    (already enabled)"
  vault write -f transit/keys/autounseal >/dev/null

  echo "==> Writing the 'autounseal' policy"
  vault policy write autounseal - <<'POLICY'
path "transit/encrypt/autounseal" { capabilities = ["update"] }
path "transit/decrypt/autounseal" { capabilities = ["update"] }
POLICY

  # Orphan so it outlives the root token that created it, periodic so it renews
  # itself indefinitely instead of expiring and stranding the farm Vault sealed.
  echo "==> Minting the farm Vault's unseal token"
  UNSEAL_TOKEN="$(vault token create -orphan -policy=autounseal -period=24h -field=token)"

  echo "==> Storing it as ${VAULT_NS}/${TOKEN_SECRET}"
  kubectl create secret generic "$TOKEN_SECRET" -n "$VAULT_NS" \
    --from-literal=token="$UNSEAL_TOKEN" \
    --dry-run=client -o yaml | kubectl apply -f -

  cat <<MSG

Done. The farm Vault reads this token as VAULT_TOKEN through its seal stanza.
Its pods were waiting on the secret, so restart them to pick it up:

  kubectl -n ${VAULT_NS} rollout restart statefulset/vault

Then initialize the farm Vault and run:  $0 farm
MSG
  exit 0
fi

echo "==> Enabling KV v2 at '${KV_MOUNT}/'"
if mount_exists secrets "$KV_MOUNT"; then
  echo "    (already enabled)"
else
  vault secrets enable -path="$KV_MOUNT" -version=2 kv
fi

echo "==> Enabling Kubernetes auth at '${K8S_AUTH_MOUNT}/'"
if mount_exists auth "$K8S_AUTH_MOUNT"; then
  echo "    (already enabled)"
else
  vault auth enable -path="$K8S_AUTH_MOUNT" kubernetes
fi

# No token_reviewer_jwt and no CA: Vault uses its own in-pod ServiceAccount and
# the cluster CA to call TokenReview, which is what server.authDelegator grants.
vault write "auth/${K8S_AUTH_MOUNT}/config" \
  kubernetes_host="https://kubernetes.default.svc"

echo "==> Enabling AppRole auth at '${APPROLE_MOUNT}/'"
if mount_exists auth "$APPROLE_MOUNT"; then
  echo "    (already enabled)"
else
  vault auth enable -path="$APPROLE_MOUNT" approle
fi

# Deliberately no "read" on any seed path: vtafarm-api provisions and tears down
# tenant access, it never reads a tenant's secret. Whenever EnsureUserAccess
# grows a KV prefix, the matching delete grant belongs here too - the components
# hold the per-user kubernetes-auth token while the API holds this AppRole, so a
# prefix added to one and not the other leaves secrets nobody can delete.
echo "==> Writing policy '${API_POLICY_NAME}'"
vault policy write "$API_POLICY_NAME" - <<POLICY
path "sys/policies/acl/vta-user-*" {
  capabilities = ["create", "read", "update", "delete"]
}

path "auth/${K8S_AUTH_MOUNT}/role/vta-user-*" {
  capabilities = ["create", "read", "update", "delete"]
}

path "${KV_MOUNT}/data/vta/*" {
  capabilities = ["delete"]
}
path "${KV_MOUNT}/metadata/vta/*" {
  capabilities = ["delete"]
}

path "${KV_MOUNT}/data/mediator/*" {
  capabilities = ["delete"]
}
path "${KV_MOUNT}/metadata/mediator/*" {
  capabilities = ["delete"]
}

path "${KV_MOUNT}/data/dids/*" {
  capabilities = ["delete"]
}
path "${KV_MOUNT}/metadata/dids/*" {
  capabilities = ["delete"]
}

path "${KV_MOUNT}/data/vtc/*" {
  capabilities = ["delete"]
}
path "${KV_MOUNT}/metadata/vtc/*" {
  capabilities = ["delete"]
}
POLICY

echo "==> Writing AppRole '${API_ROLE_NAME}'"
vault write "auth/${APPROLE_MOUNT}/role/${API_ROLE_NAME}" \
  token_policies="$API_POLICY_NAME" \
  token_ttl=1h \
  token_max_ttl=4h \
  secret_id_ttl=0 \
  secret_id_num_uses=0

ROLE_ID="$(vault read -field=role_id "auth/${APPROLE_MOUNT}/role/${API_ROLE_NAME}/role-id")"

if [ "${SKIP_SECRET_ID:-0}" = "1" ]; then
  echo "==> SKIP_SECRET_ID=1 - policy and role updated, secret_id left alone"
  exit 0
fi

SECRET_ID="$(vault write -f -field=secret_id "auth/${APPROLE_MOUNT}/role/${API_ROLE_NAME}/secret-id")"

# Written straight into the Secret rather than printed. The secret_id is a
# credential; a terminal scrollback is not where it belongs.
echo "==> Storing the API credentials as ${API_SECRET_NS}/${API_SECRET_NAME}"
kubectl create secret generic "$API_SECRET_NAME" -n "$API_SECRET_NS" \
  --from-literal=role-id="$ROLE_ID" \
  --from-literal=secret-id="$SECRET_ID" \
  --dry-run=client -o yaml | kubectl apply -f -

cat <<MSG

Done. vtafarm-api authenticates with the ${API_SECRET_NAME} secret in the
${API_SECRET_NS} namespace and reaches Vault at:

  https://vault.${VAULT_NS}.svc:8200

  role_id    ${ROLE_ID}
  secret_id  written to the secret, not printed

Re-run with SKIP_SECRET_ID=1 to update the policy without rotating the secret_id.
MSG
