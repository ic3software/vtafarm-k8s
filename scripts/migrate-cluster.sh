#!/usr/bin/env bash
#
# Move a running vtafarm farm from one Kubernetes cluster to another.
#
# The two clusters must serve the SAME domain: a VTA's did:webvh identity and a
# user's passkey are both bound to the hostname, so a farm that changes domain
# is a new farm, not a migrated one. The cutover is therefore a DNS change, and
# everything here exists to have the new cluster ready before it.
#
# Phases, in order. Each is idempotent and each stops on the first error.
#
#   preflight   compare the two clusters and report what would break the move
#   freeze      scale the source down and record what was running
#   db          stream the database from the source into the target
#   vault       copy the KV tree, the per-user policies and the k8s-auth roles
#   tenants     recreate the tenant namespaces, their volumes and their workloads
#   dns         list every record that still points at the old cluster
#   verify      check the target came up
#   unfreeze    scale the source back up, if you need to roll back
#
# Nothing here deletes anything on the source cluster. Rolling back is
# `unfreeze` plus pointing DNS back.
#
# Required: kubectl, jq, vault, and both contexts in ~/.kube/config.
set -euo pipefail

SRC="${SRC_CONTEXT:-k8s-fpp-production}"
DST="${DST_CONTEXT:-rke2-vtafarm-production}"
APP_NS="${APP_NAMESPACE:-default}"
NS_PREFIX="${NS_PREFIX:-vtafarm-user}"
VAULT_NS="${VAULT_NS:-vault}"
DB_NAME="${DB_NAME:-vtafarm}"
DB_USER="${DB_USER:-postgres}"
PG_DEPLOY="${PG_DEPLOY:-vtafarm-api-postgresql}"
API_DEPLOY="${API_DEPLOY:-vtafarm-api}"

# Records what freeze scaled down, so tenants and unfreeze can put it back.
REPLICA_ANNOTATION="migration.vtafarm/replicas"
HELPER_IMAGE="${HELPER_IMAGE:-busybox:1.37.0}"

ksrc() { kubectl --context "$SRC" "$@"; }
kdst() { kubectl --context "$DST" "$@"; }

log()  { printf '==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

confirm() {
  printf '%s [yes/N] ' "$1"
  read -r reply
  [ "$reply" = "yes" ] || die "aborted"
}

usage() {
  awk 'NR > 2 && /^#/ { sub(/^# ?/, ""); print; next } NR > 2 { exit }' "$0"
  echo
  echo "usage: SRC_CONTEXT=... DST_CONTEXT=... $0 <phase>"
  exit 2
}

require_tools() {
  for binary in "$@"; do
    command -v "$binary" >/dev/null || die "$binary is required but not on PATH"
  done
}

# Every tenant namespace on the source, in a stable order.
tenant_namespaces() {
  ksrc get ns -o json |
    jq -r --arg p "${NS_PREFIX}-" '.items[].metadata.name | select(startswith($p))' |
    sort -V
}

# Fields the API server owns. Copying them into another cluster is at best
# ignored and at worst rejected, so they come off every exported object.
sanitize() {
  jq 'del(
        .metadata.uid,
        .metadata.resourceVersion,
        .metadata.creationTimestamp,
        .metadata.generation,
        .metadata.managedFields,
        .metadata.ownerReferences,
        .metadata.finalizers,
        .metadata.annotations["kubectl.kubernetes.io/last-applied-configuration"],
        .metadata.annotations["deployment.kubernetes.io/revision"],
        .status
      )
      | if .kind == "Service" then
          del(.spec.clusterIP, .spec.clusterIPs, .spec.ipFamilies,
              .spec.ipFamilyPolicy, .spec.internalTrafficPolicy)
        else . end
      | if .kind == "PersistentVolumeClaim" then
          del(.spec.volumeName,
              .metadata.annotations["pv.kubernetes.io/bind-completed"],
              .metadata.annotations["pv.kubernetes.io/bound-by-controller"],
              .metadata.annotations["volume.beta.kubernetes.io/storage-provisioner"],
              .metadata.annotations["volume.kubernetes.io/storage-provisioner"],
              .metadata.annotations["volume.kubernetes.io/selected-node"])
        else . end
      | if .kind == "ServiceAccount" then del(.secrets) else . end
      | if .kind == "Namespace" then del(.spec.finalizers) else . end'
}

# Copy one resource, or a whole kind, from the source namespace to the same
# namespace on the target.
copy_kind() {
  local ns="$1" kind="$2" jq_filter="${3:-.items[]}"
  local objects
  objects="$(ksrc -n "$ns" get "$kind" -o json | jq -c "$jq_filter" || true)"
  [ -n "$objects" ] || return 0
  while IFS= read -r object; do
    [ -n "$object" ] || continue
    printf '%s' "$object" | sanitize | kdst apply -f - >/dev/null
  done <<<"$objects"
}

# SHA-256 of one key in the API's secret, or of nothing when the secret is
# absent. Values are never printed: two of these are key material.
secret_digest() { # $1 = context, $2 = key
  kubectl --context "$1" -n "$APP_NS" get secret vtafarm-api-secrets \
    -o "jsonpath={.data.$2}" 2>/dev/null | shasum -a 256 | cut -c1-12 || true
}

ingress_ip() { # $1 = context
  kubectl --context "$1" -n "$APP_NS" get secret vtafarm-api-secrets \
    -o 'jsonpath={.data.CLUSTER_INGRESS_IP}' 2>/dev/null | base64 -d || true
}

pg_pod() { # $1 = context
  kubectl --context "$1" -n "$APP_NS" get pod \
    -l "app=${PG_DEPLOY}" -o jsonpath='{.items[0].metadata.name}'
}

# ─── preflight ───────────────────────────────────────────────────────────────

phase_preflight() {
  require_tools kubectl jq vault
  local failures=0

  log "Reaching both clusters"
  ksrc version -o json >/dev/null 2>&1 || die "cannot reach context $SRC"
  kdst version -o json >/dev/null 2>&1 || die "cannot reach context $DST"
  info "source  $SRC"
  info "target  $DST"

  log "Comparing PostgreSQL"
  local src_pg dst_pg
  src_pg="$(ksrc -n "$APP_NS" get deploy "$PG_DEPLOY" \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
  dst_pg="$(kdst -n "$APP_NS" get deploy "$PG_DEPLOY" \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
  info "source  ${src_pg:-<missing>}"
  info "target  ${dst_pg:-<missing>}"
  [ -n "$dst_pg" ] || { warn "the target has no database - apply stack 05 first"; failures=$((failures + 1)); }
  if [ -n "$src_pg" ] && [ -n "$dst_pg" ] && [ "$src_pg" != "$dst_pg" ]; then
    warn "different PostgreSQL images; pg_restore only reads a dump from the same or an older major"
    failures=$((failures + 1))
  fi

  local key src_hash dst_hash
  if ! kdst -n "$APP_NS" get secret vtafarm-api-secrets >/dev/null 2>&1; then
    log "The target has no app stack yet"
    info "Apply stack 05 there before the rest of this preflight means anything."
    info "Three of its values are not free choices - read them off the old"
    info "cluster and put them in the new cluster's terraform.tfvars:"
    echo
    for key in DID_HOSTING_DID DID_HOSTING_PRIVATE_KEY MONITOR_TOKEN; do
      info "  kubectl --context $SRC -n $APP_NS get secret vtafarm-api-secrets \\"
      info "    -o jsonpath='{.data.$key}' | base64 -d"
    done
    echo
    info "domain and cloudflare_zone_id must match the old cluster too."
    info "cluster_ingress_ip must NOT - it is the new load balancer."
    die "target not ready; nothing was changed"
  fi

  log "Comparing the API's secret material"
  for key in DID_HOSTING_DID DID_HOSTING_PRIVATE_KEY CLOUDFLARE_ZONE_ID MONITOR_TOKEN JWT_SECRET; do
    src_hash="$(secret_digest "$SRC" "$key")"
    dst_hash="$(secret_digest "$DST" "$key")"
    if [ "$src_hash" = "$dst_hash" ]; then
      info "$key  identical"
    else
      case "$key" in
        DID_HOSTING_DID|DID_HOSTING_PRIVATE_KEY)
          warn "$key DIFFERS - every existing tenant's DID-hosting daemon has the old DID in its ACL. Copy the old value into stack 05's terraform.tfvars and re-apply."
          failures=$((failures + 1))
          ;;
        JWT_SECRET)
          info "$key  differs - every signed-in session is invalidated; users log in again. Passkeys are unaffected."
          ;;
        *)
          warn "$key differs"
          ;;
      esac
    fi
  done

  local src_ip dst_ip
  src_ip="$(ingress_ip "$SRC")"
  dst_ip="$(ingress_ip "$DST")"
  info "CLUSTER_INGRESS_IP  source ${src_ip:-<unset>}  target ${dst_ip:-<unset>}"
  [ "$src_ip" != "$dst_ip" ] || warn "both clusters claim the same ingress IP - one of them is wrong"

  log "Comparing the API's configuration"
  local field
  for field in CLUSTER_DOMAIN WEBAUTHN_RP_ID K8S_NAMESPACE_PREFIX VAULT_KV_MOUNT VAULT_ADDR; do
    local src_value dst_value
    src_value="$(ksrc -n "$APP_NS" get cm vtafarm-api-config -o "jsonpath={.data.$field}" 2>/dev/null || true)"
    dst_value="$(kdst -n "$APP_NS" get cm vtafarm-api-config -o "jsonpath={.data.$field}" 2>/dev/null || true)"
    [ -n "$src_value$dst_value" ] || continue
    if [ "$src_value" = "$dst_value" ]; then
      info "$field  $src_value"
    else
      warn "$field differs: '$src_value' -> '$dst_value'"
      failures=$((failures + 1))
    fi
  done

  log "Checking the target Vault"
  local sealed initialized
  initialized="$(kdst -n "$VAULT_NS" exec vault-0 -- vault status -format=json 2>/dev/null | jq -r '.initialized' || echo unknown)"
  sealed="$(kdst -n "$VAULT_NS" exec vault-0 -- vault status -format=json 2>/dev/null | jq -r '.sealed' || echo unknown)"
  info "initialized=$initialized sealed=$sealed"
  if [ "$initialized" != "true" ] || [ "$sealed" != "false" ]; then
    warn "the target Vault must be initialized, unsealed and bootstrapped - see docs/vault.md"
    failures=$((failures + 1))
  fi

  log "Checking the target StorageClasses"
  local class
  for class in $(ksrc get pvc -A -o json | jq -r '.items[].spec.storageClassName | select(. != null)' | sort -u); do
    if kdst get sc "$class" >/dev/null 2>&1; then
      info "$class  present"
    else
      warn "StorageClass '$class' does not exist on the target"
      failures=$((failures + 1))
    fi
  done

  log "What would move"
  local ns
  for ns in $(tenant_namespaces); do
    info "$ns"
    ksrc -n "$ns" get deploy -o custom-columns=:.metadata.name --no-headers |
      sed 's/^/        deployment /'
    ksrc -n "$ns" get pvc -o 'custom-columns=:.metadata.name,:.spec.resources.requests.storage' --no-headers |
      sed 's/^/        pvc        /'
  done

  echo
  if [ "$failures" -eq 0 ]; then
    log "Preflight clean."
  else
    die "$failures problem(s) above. Fix them before freezing the source."
  fi
}

# ─── freeze ──────────────────────────────────────────────────────────────────

phase_freeze() {
  require_tools kubectl jq
  confirm "Scale down every vtafarm workload on $SRC? The farm stops serving."

  local ns deploy replicas
  for ns in "$APP_NS" $(tenant_namespaces); do
    for deploy in $(ksrc -n "$ns" get deploy -o custom-columns=:.metadata.name --no-headers); do
      # The database keeps running: the dump is read out of it.
      [ "$ns" = "$APP_NS" ] && [ "$deploy" = "$PG_DEPLOY" ] && continue
      replicas="$(ksrc -n "$ns" get deploy "$deploy" -o jsonpath='{.spec.replicas}')"
      [ "$replicas" = "0" ] && continue
      log "$ns/$deploy: $replicas -> 0"
      ksrc -n "$ns" annotate deploy "$deploy" "${REPLICA_ANNOTATION}=${replicas}" --overwrite >/dev/null
      ksrc -n "$ns" scale deploy "$deploy" --replicas=0 >/dev/null
    done
  done

  log "Waiting for the pods to go away"
  for ns in "$APP_NS" $(tenant_namespaces); do
    local waited=0
    while [ "$(ksrc -n "$ns" get pods --no-headers 2>/dev/null | grep -cv "^${PG_DEPLOY}" || true)" -gt 0 ]; do
      [ "$waited" -ge 120 ] && { warn "$ns still has pods after 120s"; break; }
      sleep 5
      waited=$((waited + 5))
    done
  done
  log "The source is frozen. Its data is now consistent to copy."
}

phase_unfreeze() {
  require_tools kubectl jq
  local ns deploy replicas
  for ns in "$APP_NS" $(tenant_namespaces); do
    for deploy in $(ksrc -n "$ns" get deploy -o custom-columns=:.metadata.name --no-headers); do
      replicas="$(ksrc -n "$ns" get deploy "$deploy" -o json |
        jq -r --arg a "$REPLICA_ANNOTATION" '.metadata.annotations[$a] // empty')"
      [ -n "$replicas" ] || continue
      log "$ns/$deploy: 0 -> $replicas"
      ksrc -n "$ns" scale deploy "$deploy" --replicas="$replicas" >/dev/null
    done
  done
  log "The source is serving again. Point DNS back at it to complete the rollback."
}

# ─── db ──────────────────────────────────────────────────────────────────────

phase_db() {
  require_tools kubectl jq
  local src_pod dst_pod
  src_pod="$(pg_pod "$SRC")"
  dst_pod="$(pg_pod "$DST")"
  [ -n "$src_pod" ] && [ -n "$dst_pod" ] || die "a PostgreSQL pod is missing on one side"

  log "Stopping the target API so nothing writes during the restore"
  kdst -n "$APP_NS" scale deploy "$API_DEPLOY" --replicas=0 >/dev/null 2>&1 || true
  kdst -n "$APP_NS" wait --for=delete pod -l "app=${API_DEPLOY}" --timeout=120s >/dev/null 2>&1 || true

  local rows
  rows="$(ksrc -n "$APP_NS" exec "$src_pod" -- \
    psql -U "$DB_USER" -d "$DB_NAME" -tAc 'select count(*) from users' 2>/dev/null || echo '?')"
  log "Source has $rows user row(s)"

  confirm "Drop and recreate '$DB_NAME' on $DST, then restore the source dump into it?"

  log "Recreating an empty '$DB_NAME' on the target"
  kdst -n "$APP_NS" exec "$dst_pod" -- psql -U "$DB_USER" -d postgres \
    -c "DROP DATABASE IF EXISTS ${DB_NAME} WITH (FORCE)" >/dev/null
  kdst -n "$APP_NS" exec "$dst_pod" -- psql -U "$DB_USER" -d postgres \
    -c "CREATE DATABASE ${DB_NAME}" >/dev/null

  # Streamed, so the dump - which holds passkey material and session rows -
  # never lands on the operator's disk. --no-owner/--no-acl because the two
  # clusters generated different passwords for the same 'postgres' role.
  log "Streaming pg_dump -> pg_restore"
  ksrc -n "$APP_NS" exec "$src_pod" -- \
    pg_dump -U "$DB_USER" -d "$DB_NAME" -Fc --no-owner --no-acl |
    kdst -n "$APP_NS" exec -i "$dst_pod" -- \
      pg_restore -U "$DB_USER" -d "$DB_NAME" --no-owner --no-acl --exit-on-error

  local restored
  restored="$(kdst -n "$APP_NS" exec "$dst_pod" -- \
    psql -U "$DB_USER" -d "$DB_NAME" -tAc 'select count(*) from users')"
  log "Target now has $restored user row(s)"
  [ "$rows" = "$restored" ] || warn "row counts differ - inspect before continuing"

  log "Starting the target API again"
  kdst -n "$APP_NS" scale deploy "$API_DEPLOY" --replicas=1 >/dev/null
}

# ─── vault ───────────────────────────────────────────────────────────────────

VAULT_PF_PIDS=()
vault_cleanup() {
  local pid
  for pid in "${VAULT_PF_PIDS[@]:-}"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  done
  [ -n "${VAULT_WORK:-}" ] && rm -rf "$VAULT_WORK"
}

vault_open() { # $1 = context, $2 = local port, $3 = ca file
  kubectl --context "$1" -n "$VAULT_NS" port-forward svc/vault "$2:8200" >/dev/null 2>&1 &
  VAULT_PF_PIDS+=("$!")
  kubectl --context "$1" -n "$VAULT_NS" get secret vault-tls \
    -o jsonpath='{.data.ca\.crt}' | base64 -d >"$3"
  local waited=0
  until VAULT_ADDR="https://127.0.0.1:$2" VAULT_CACERT="$3" vault status >/dev/null 2>&1; do
    waited=$((waited + 1))
    [ "$waited" -gt 30 ] && die "Vault on $1 did not answer through the port-forward"
    sleep 1
  done
}

phase_vault() {
  require_tools kubectl jq vault
  : "${SRC_VAULT_TOKEN:?set SRC_VAULT_TOKEN to the root token of the OLD farm Vault}"
  : "${DST_VAULT_TOKEN:?set DST_VAULT_TOKEN to the root token of the NEW farm Vault}"

  VAULT_WORK="$(mktemp -d)"
  trap vault_cleanup EXIT

  log "Opening both Vaults"
  vault_open "$SRC" 18201 "$VAULT_WORK/src-ca.crt"
  vault_open "$DST" 18202 "$VAULT_WORK/dst-ca.crt"

  vsrc() { VAULT_ADDR="https://127.0.0.1:18201" VAULT_CACERT="$VAULT_WORK/src-ca.crt" VAULT_TOKEN="$SRC_VAULT_TOKEN" vault "$@"; }
  vdst() { VAULT_ADDR="https://127.0.0.1:18202" VAULT_CACERT="$VAULT_WORK/dst-ca.crt" VAULT_TOKEN="$DST_VAULT_TOKEN" vault "$@"; }

  local kv="${VAULT_KV_MOUNT:-secret}"
  vdst secrets list -format=json | jq -e --arg m "${kv}/" 'has($m)' >/dev/null ||
    die "KV mount '${kv}/' is missing on the target - run 'make vault-bootstrap TARGET=farm' first"

  # KV v2 lists one level at a time; a trailing slash is a folder.
  walk_kv() {
    local prefix="$1" entry
    for entry in $({ vsrc kv list -format=json "${kv}/${prefix}" 2>/dev/null || true; } | jq -r '.[]?' || true); do
      if [ "${entry%/}" != "$entry" ]; then
        walk_kv "${prefix}${entry}"
      else
        printf '%s%s\n' "$prefix" "$entry"
      fi
    done
  }

  log "Copying the KV tree at '${kv}/'"
  local copied=0 path
  for path in $(walk_kv ""); do
    # Only the current version moves. Values go straight from one API to the
    # other; nothing is written to disk and nothing is echoed.
    vsrc kv get -format=json "${kv}/${path}" |
      jq -c '.data.data' |
      vdst kv put "${kv}/${path}" - >/dev/null
    copied=$((copied + 1))
    info "$path"
  done
  log "$copied secret(s) copied"

  # vtafarm-api creates one policy and one kubernetes-auth role per user at
  # runtime, and only when a session is created. Existing tenants would never
  # get theirs back, so they are copied rather than regenerated.
  log "Copying the per-user policies"
  local policy count=0
  for policy in $(vsrc policy list | grep '^vta-user-' || true); do
    vsrc policy read "$policy" | vdst policy write "$policy" - >/dev/null
    count=$((count + 1))
    info "$policy"
  done
  log "$count policy(ies) copied"

  log "Copying the per-user kubernetes-auth roles"
  local mount="${VAULT_K8S_AUTH_MOUNT:-kubernetes}" role
  count=0
  for role in $(vsrc list -format=json "auth/${mount}/role" 2>/dev/null | jq -r '.[]' | grep '^vta-user-' || true); do
    vsrc read -format=json "auth/${mount}/role/${role}" |
      jq -c '.data | {
               bound_service_account_names,
               bound_service_account_namespaces,
               audience,
               alias_name_source,
               token_policies,
               token_ttl,
               token_max_ttl,
               token_period,
               token_type
             } | with_entries(select(.value != null and .value != ""))' |
      vdst write "auth/${mount}/role/${role}" - >/dev/null
    count=$((count + 1))
    info "$role"
  done
  log "$count role(s) copied"

  log "Vault content migrated. The target keeps its own recovery keys and root token."
}

# ─── tenants ─────────────────────────────────────────────────────────────────

helper_pod() { # $1 = context, $2 = namespace, $3 = pvc, $4 = pod name
  kubectl --context "$1" -n "$2" get pod "$4" >/dev/null 2>&1 || \
  kubectl --context "$1" -n "$2" apply -f - >/dev/null <<POD
apiVersion: v1
kind: Pod
metadata:
  name: $4
  labels:
    app.kubernetes.io/managed-by: migrate-cluster
spec:
  restartPolicy: Never
  containers:
    - name: copy
      image: ${HELPER_IMAGE}
      command: ["sleep", "3600"]
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: $3
POD
  kubectl --context "$1" -n "$2" wait --for=condition=Ready "pod/$4" --timeout=180s >/dev/null
}

copy_volume() { # $1 = namespace, $2 = pvc
  local ns="$1" pvc="$2" pod="migrate-${2}"
  # Pod names are DNS labels; PVC names already are, so this only needs bounding.
  pod="$(printf '%s' "$pod" | cut -c1-63)"
  log "$ns/$pvc: copying volume contents"
  helper_pod "$SRC" "$ns" "$pvc" "$pod"
  helper_pod "$DST" "$ns" "$pvc" "$pod"
  # tar preserves uid/gid, which matters: these components run as a fixed
  # non-root user and will not read a tree owned by someone else.
  ksrc -n "$ns" exec "$pod" -- tar -cf - -C /data . |
    kdst -n "$ns" exec -i "$pod" -- tar -xf - -C /data
  local src_bytes dst_bytes
  src_bytes="$(ksrc -n "$ns" exec "$pod" -- du -s /data | cut -f1)"
  dst_bytes="$(kdst -n "$ns" exec "$pod" -- du -s /data | cut -f1)"
  info "source ${src_bytes}K, target ${dst_bytes}K"
  ksrc -n "$ns" delete pod "$pod" --wait=false >/dev/null
  kdst -n "$ns" delete pod "$pod" --wait=false >/dev/null
}

phase_tenants() {
  require_tools kubectl jq

  local ns
  for ns in $(tenant_namespaces); do
    log "Namespace $ns"

    ksrc get ns "$ns" -o json | sanitize | kdst apply -f - >/dev/null

    # The ServiceAccount names are what Vault's per-user kubernetes-auth role is
    # bound to, so they have to survive the move exactly.
    copy_kind "$ns" serviceaccount '.items[] | select(.metadata.name != "default")'
    copy_kind "$ns" role
    copy_kind "$ns" rolebinding
    copy_kind "$ns" configmap '.items[] | select(.metadata.name != "kube-root-ca.crt")'

    copy_kind "$ns" pvc
    local pvc
    for pvc in $(ksrc -n "$ns" get pvc -o custom-columns=:.metadata.name --no-headers); do
      kdst -n "$ns" wait --for=jsonpath='{.status.phase}'=Bound "pvc/$pvc" --timeout=180s >/dev/null
      copy_volume "$ns" "$pvc"
    done

    copy_kind "$ns" service
    copy_kind "$ns" ingress

    # Namespaced, but invisible to `kubectl get all` - which is how a first run
    # of this script missed the Middleware an ingress annotation pointed at.
    # Traefik refuses to register a router whose middleware is absent, so the
    # host answered 404 with every other object correctly in place.
    local crd
    for crd in middlewares.traefik.io middlewaretcps.traefik.io \
               ingressroutes.traefik.io ingressroutetcps.traefik.io \
               serverstransports.traefik.io certificates.cert-manager.io; do
      kdst get crd "$crd" >/dev/null 2>&1 || continue
      copy_kind "$ns" "$crd"
    done
    # Recreated at the replica count freeze recorded, not at the frozen zero.
    copy_kind "$ns" deployment \
      ".items[] | .spec.replicas = ((.metadata.annotations[\"${REPLICA_ANNOTATION}\"] // ((.spec.replicas // 1) | tostring)) | tonumber)"
  done

  log "Tenants recreated. They will stay unready until DNS points at the new cluster."
}

# ─── dns ─────────────────────────────────────────────────────────────────────

phase_dns() {
  require_tools kubectl jq
  local dst_ip
  dst_ip="$(ingress_ip "$DST")"

  log "Every A record below must point at ${dst_ip:-the load balancer of the new cluster}"
  ksrc get ingress -A -o json |
    jq -r '.items[].spec.rules[].host' | sort -u | sed 's/^/    /'
  echo
  info "vtafarm-api only writes a tenant's A record when the session is created,"
  info "so these are edited in Cloudflare by hand. Lower the TTL a day ahead."
}

# ─── verify ──────────────────────────────────────────────────────────────────

phase_verify() {
  require_tools kubectl jq
  log "Target workloads"
  kdst -n "$APP_NS" get deploy
  local ns
  for ns in $(tenant_namespaces); do
    echo
    info "$ns"
    kdst -n "$ns" get deploy,pvc --no-headers | sed 's/^/    /'
  done

  echo
  log "Pods that are not Running"
  kdst get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded --no-headers |
    sed 's/^/    /' || info "none"

  echo
  log "Certificates"
  kdst get certificate -A --no-headers | sed 's/^/    /' || true
}

# ─────────────────────────────────────────────────────────────────────────────

[ "$#" -eq 1 ] || usage
case "$1" in
  preflight) phase_preflight ;;
  freeze)    phase_freeze ;;
  unfreeze)  phase_unfreeze ;;
  db)        phase_db ;;
  vault)     phase_vault ;;
  tenants)   phase_tenants ;;
  dns)       phase_dns ;;
  verify)    phase_verify ;;
  *)         usage ;;
esac
