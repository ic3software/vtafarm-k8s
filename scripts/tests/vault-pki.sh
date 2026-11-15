#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
chart="$repo_root/modules/vtafarm-platform/charts/vault-pki"

farm="$(helm template vault-pki "$chart" --namespace vault --set trustBundle.enabled=true)"
transit="$(helm template vault-transit-pki "$chart" --namespace vault-transit --set name=vault-transit)"

grep -Fq "kind: Bundle" <<<"$farm"
grep -Fq "name: vtafarm-vault-trust-source" <<<"$farm"
grep -Fq "key: ca.crt" <<<"$farm"
grep -Fq "managed-by: vtafarm" <<<"$farm"
[[ "$(grep -c "rotationPolicy: Never" <<<"$farm")" -eq 1 ]]
[[ "$(grep -c "rotationPolicy: Always" <<<"$farm")" -eq 1 ]]

if grep -Fq "kind: Bundle" <<<"$transit"; then
  echo "transit PKI unexpectedly rendered a tenant trust bundle" >&2
  exit 1
fi

echo "PASS: farm Vault publishes its stable CA; transit Vault does not"
