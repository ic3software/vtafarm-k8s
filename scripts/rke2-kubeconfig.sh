#!/usr/bin/env bash
# Renew through Rancher's Kubeconfig API; install only after direct access succeeds.
set +x
set -euo pipefail
umask 077

fail() { echo "ERROR: $*" >&2; exit 1; }
[ "$#" -ge 3 ] && [ "$#" -le 5 ] || fail 'usage: rke2-kubeconfig.sh <write|check|renew|test> <cluster-dir> <destination> [ttl-seconds] [wait-seconds]'
ACTION="$1"; CLUSTER_DIR="$2"; DEST="$3"; TTL="${4:-0}"; AUTH_WAIT="${5:-60}"
case "$ACTION" in write|check|renew|test) ;; *) fail 'Unknown action';; esac
[[ "$TTL" =~ ^[0-9]+$ && "$AUTH_WAIT" =~ ^[0-9]+$ ]] || fail 'TTL and wait must be nonnegative integers'
[ "${#TTL}" -le 9 ] && [ "${#AUTH_WAIT}" -le 3 ] || fail 'TTL or wait is too large'
TTL=$((10#$TTL)); AUTH_WAIT=$((10#$AUTH_WAIT))
[ "$AUTH_WAIT" -le 300 ] || fail 'Wait must be at most 300 seconds'
if [ "$ACTION" = test ] && [ "$TTL" -eq 0 ]; then TTL=600; fi
for tool in tofu kubectl curl jq; do command -v "$tool" >/dev/null || fail "$tool is required"; done
NAME="$(basename "$CLUSTER_DIR")"
[[ "$NAME" =~ ^[a-z0-9][-a-z0-9]*$ ]] || fail 'Invalid cluster directory name'
[ -d "$CLUSTER_DIR" ] || fail 'Cluster directory does not exist'
mkdir -p "$(dirname "$DEST")"
WORK="$(mktemp -d "$(dirname "$DEST")/.kubeconfig-work.XXXXXX")"
RESOURCE=''; INSTALLED=false

# Credentials stay in private files, never in curl's process arguments or diagnostics.
request() {
  local method="$1" path="$2" output="$3" auth="${4:-$WORK/auth}" body="${5:-}"
  local args=(--disable --silent --show-error --proto '=https' --connect-timeout 10 --max-time 20
    --config "$auth" --request "$method" --output "$output" --write-out '%{http_code}')
  [ -z "$body" ] || args+=(--data-binary "@$body")
  HTTP_STATUS="$(curl "${args[@]}" "$URL$path" 2>"$WORK/error")" || {
    echo 'ERROR: Cannot reach Rancher with the configured TLS settings.' >&2; return 1;
  }
  case "$HTTP_STATUS" in 2??) return 0;; esac
  echo "ERROR: Rancher API returned HTTP $HTTP_STATUS; check API credentials, permissions and request settings." >&2
  return 1
}
cleanup() {
  local result=$?
  trap - EXIT
  if [ -n "$RESOURCE" ] && [ "$INSTALLED" = false ]; then
    if request DELETE "/apis/ext.cattle.io/v1/kubeconfigs/$RESOURCE" "$WORK/deleted"; then
      echo 'Removed candidate kubeconfig and its tokens; existing files preserved.'
    else
      echo "ERROR: Cleanup failed; delete Rancher Kubeconfig resource $RESOURCE manually." >&2
      result=1
    fi
  fi
  rm -rf "$WORK"
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

tofu -chdir="$CLUSTER_DIR" output -json >"$WORK/outputs" 2>"$WORK/error" || fail 'Cannot read OpenTofu outputs; check initialization and backend access'
ID="$(jq -er '.cluster_v1_id.value | select(test("^[a-zA-Z0-9-]+$"))' "$WORK/outputs")" || fail 'Missing cluster_v1_id'
SERVER="$(jq -er '.kubernetes_api_endpoint.value | select(startswith("https://"))' "$WORK/outputs")" || fail 'Missing Kubernetes endpoint'
printf '%s\n' 'nonsensitive(jsonencode({url=var.rancher_api_url,token=var.rancher_token_key,insecure=var.rancher_insecure}))' |
  tofu -chdir="$CLUSTER_DIR" console -no-color >"$WORK/console" 2>"$WORK/error" || fail 'Cannot read Rancher settings from OpenTofu'
jq -Rse 'split("\n") | map(select(startswith("\""))) | select(length == 1) | .[0] | fromjson | fromjson' \
  "$WORK/console" >"$WORK/settings" 2>"$WORK/error" || fail 'Invalid Rancher settings from OpenTofu'
URL="$(jq -er '.url | sub("/+$"; "") | select(test("^https://[^/@?#[:space:]]+(/[^?#[:space:]]*)?$"))' "$WORK/settings")" || fail 'Rancher URL must use HTTPS without embedded credentials'
jq -er 'select(.token | type == "string" and length > 0 and (test("[\\r\\n]") | not)) |
  "header = " + (("Authorization: Bearer " + .token) | @json),
  "header = \"Content-Type: application/json\"", "user-agent = \"vtafarm-k8s-kubeconfig/1.0\"",
  (if .insecure then "insecure" else empty end)' "$WORK/settings" >"$WORK/auth" || fail 'Missing Rancher API credential'

parse_config() {
  kubectl --kubeconfig="$1" config view --raw -o json >"$WORK/raw.json" 2>"$WORK/error" || fail 'Cannot parse kubeconfig'
}
normalize() {
  # Follow the context's user reference; users[0] may belong to the proxy or another cluster.
  jq -e --arg name "$NAME" --arg server "$SERVER" '
    . as $raw | first(.contexts[] | .context as $ctx |
      $raw.clusters[] | select(.name == $ctx.cluster) | .cluster as $cluster |
      select($cluster.server | test(":6443/?$")) |
      $raw.users[] | select(.name == $ctx.user) | .user as $user |
      select(($cluster["certificate-authority-data"] // "") != "" and ($user.token // "") != "") |
      {apiVersion:"v1", kind:"Config",
       clusters:[{name:$name, cluster:{server:$server,"certificate-authority-data":$cluster["certificate-authority-data"]}}],
       users:[{name:$name,user:{token:$user.token}}],
       contexts:[{name:$name,context:{cluster:$name,user:$name}}],"current-context":$name})' \
    "$WORK/raw.json" >"$WORK/candidate" 2>"$WORK/error" || fail 'No direct API context with a CA and bearer token; check ACE configuration'
}
validate() {
  local token_id token_path deadline
  token_id="$(jq -er '.users[0].user.token | split(":") |
    if length == 2 then .[0] elif length == 3 and .[0] == "ext" then .[1] else empty end |
    select(test("^[a-zA-Z0-9-]+$"))' "$WORK/candidate")" || fail 'Unsupported Rancher bearer token'
  if jq -e '.users[0].user.token | startswith("ext:")' "$WORK/candidate" >/dev/null; then
    token_path="/apis/ext.cattle.io/v1/tokens/$token_id"
  else
    token_path="/v3/tokens/$token_id"
  fi
  request GET "$token_path" "$WORK/metadata" || fail 'Cannot read token metadata; missing tokens require kubeconfig-renew-rke2'
  jq -e --arg id "$ID" '(.clusterId // .spec.clusterName) == $id' "$WORK/metadata" >/dev/null ||
    fail 'Token is not scoped to this cluster; use kubeconfig-renew-rke2'
  jq -e '(.status // .) as $s | (.spec.enabled != false and .enabled != false) and
    ($s.expired != true) and (($s.expiresAt | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) > now)' \
    "$WORK/metadata" >/dev/null 2>"$WORK/error" || fail 'Token is expired, disabled or has no valid expiry; use kubeconfig-renew-rke2'
  jq -r '"Token scope OK; expires " + ((.status // .).expiresAt) + "."' "$WORK/metadata"
  deadline=$((SECONDS + AUTH_WAIT))
  while ! kubectl --kubeconfig="$WORK/candidate" --request-timeout=10s get nodes -o json >"$WORK/nodes" 2>"$WORK/probe-error"; do
    if grep -Eiq 'unauthorized|provide credentials|must be logged in' "$WORK/probe-error"; then
      if [ "$SECONDS" -lt "$deadline" ]; then sleep 2; continue; fi
      jq -nr --slurpfile settings "$WORK/settings" --slurpfile config "$WORK/candidate" '
        "header = " + (("Authorization: Bearer " + $config[0].users[0].user.token) | @json),
        "user-agent = \"vtafarm-k8s-kubeconfig/1.0\"",
        (if $settings[0].insecure then "insecure" else empty end)' >"$WORK/proxy-auth"
      if request GET "/k8s/clusters/$ID/api/v1/nodes?limit=1" "$WORK/proxy-nodes" "$WORK/proxy-auth"; then
        fail 'Rancher proxy accepts the token, but direct API authentication failed. Check Rancher ClusterAuthToken synchronization; repeating merge will not fix it.'
      fi
      fail 'Both direct API and Rancher proxy rejected the request'
    elif grep -qi forbidden "$WORK/probe-error"; then
      fail 'Direct API denied get nodes; check cluster permissions'
    elif grep -Eiq 'x509|certificate' "$WORK/probe-error"; then
      fail 'Direct API TLS verification failed; check endpoint and cluster CA'
    else
      fail 'Direct API request failed; check endpoint, firewall and cluster availability'
    fi
  done
  echo 'Direct API get nodes: OK.'
}
install_config() {
  local backup
  kubectl --kubeconfig="$WORK/candidate" config view --raw -o yaml >"$WORK/install.yaml" 2>"$WORK/error" ||
    fail 'Cannot serialize the validated kubeconfig as YAML'
  if [ -f "$DEST" ]; then
    backup="$(mktemp "${DEST}.backup.XXXXXX")"
    cp "$DEST" "$backup"
    chmod 600 "$backup"
    echo 'Backed up the previous kubeconfig in its cluster directory.'
  fi
  chmod 600 "$WORK/install.yaml"
  mv "$WORK/install.yaml" "$DEST"
  INSTALLED=true
}

case "$ACTION" in
  renew|test)
    jq -n --arg id "$ID" --arg name "$NAME" --argjson ttl "$TTL" '
      {apiVersion:"ext.cattle.io/v1",kind:"Kubeconfig",spec:{clusters:[$id],currentContext:$id,description:("vtafarm-k8s " + $name)}} |
      if $ttl > 0 then .spec.ttl=$ttl else . end' >"$WORK/request"
    request POST /apis/ext.cattle.io/v1/kubeconfigs "$WORK/created" "$WORK/auth" "$WORK/request" || fail 'Could not create a kubeconfig'
    RESOURCE="$(jq -er '.metadata.name | select(test("^kubeconfig-[a-z0-9-]+$"))' "$WORK/created")" || fail 'Rancher response has no candidate resource name; inspect Rancher for incomplete creation'
    echo "Candidate for $NAME: $RESOURCE; waiting up to ${AUTH_WAIT}s for direct access."
    jq -er 'select(.status.summary == "Complete") | .status.value | select(length > 0)' "$WORK/created" >"$WORK/raw" || fail 'Rancher could not generate a complete kubeconfig'
    parse_config "$WORK/raw"
    normalize
    validate
    if [ "$ACTION" = renew ]; then
      install_config
      echo "Renewed $NAME; Rancher Kubeconfig resource: $RESOURCE."
    fi
    ;;
  write|check)
    AUTH_WAIT=0
    if [ -f "$DEST" ]; then
      parse_config "$DEST"
      jq -e --arg name "$NAME" --arg server "$SERVER" '
        . as $raw | .contexts |= map(select(.name == $name)) |
        select(.contexts | length == 1) | .contexts[0].context.cluster as $cluster |
        select(any($raw.clusters[]; .name == $cluster and .cluster.server == $server))' \
        "$WORK/raw.json" >"$WORK/selected" || fail 'Local context or endpoint differs from cluster state; use kubeconfig-renew-rke2'
      mv "$WORK/selected" "$WORK/raw.json"
    elif [ "$ACTION" = write ]; then
      jq -er '.kube_config.value | select(length > 0)' "$WORK/outputs" >"$WORK/raw" || fail 'No kubeconfig in state; use kubeconfig-renew-rke2'
      parse_config "$WORK/raw"
    else
      fail 'No local kubeconfig; use kubeconfig-renew-rke2'
    fi
    normalize
    validate
    if [ "$ACTION" = write ] && [ ! -f "$DEST" ]; then install_config; fi
    echo "Validated kubeconfig for $NAME."
    ;;
esac
