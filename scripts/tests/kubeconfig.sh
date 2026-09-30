#!/usr/bin/env bash
# Offline integration checks: real kubeconfig parsing/merging, fake Rancher and node APIs.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export REAL_KUBECTL="$(command -v kubectl)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
export TEST_DIR
mkdir -p "$TEST_DIR/bin" "$TEST_DIR/rke2-test"
export PATH="$TEST_DIR/bin:$PATH"
export TEST_MODE=ok
DEST="$TEST_DIR/rke2-test/config"
fail() { echo "FAIL: $*" >&2; exit 1; }

jq -n '{apiVersion:"v1",kind:"Config",
  clusters:[{name:"rke2-test",cluster:{server:"https://127.0.0.1:6443","certificate-authority-data":"dGVzdA=="}}],
  users:[{name:"unrelated",user:{token:"wrong:fake-unrelated"}},{name:"rke2-test",user:{token:"token-new:fake-new"}}],
  contexts:[{name:"rke2-test",context:{cluster:"rke2-test",user:"rke2-test"}}],"current-context":"rke2-test"}' >"$TEST_DIR/new"
jq '(.users[] | select(.name == "rke2-test").user.token) = "token-old:fake-old"' "$TEST_DIR/new" >"$TEST_DIR/old"
jq -n --rawfile config "$TEST_DIR/old" '{cluster_v1_id:{value:"c-test"},kubernetes_api_endpoint:{value:"https://127.0.0.1:6443"},kube_config:{value:$config}}' >"$TEST_DIR/outputs"
cat >"$TEST_DIR/bin/tofu" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  *output*) cat "$TEST_DIR/outputs";;
  *console*)
    cat >/dev/null
    echo 'Acquiring state lock...'
    jq -nc '{url:"https://rancher.example.test",token:"token-api:fake-api",insecure:false} | tojson'
    echo 'Releasing state lock...';;
  *) exit 1;;
esac
MOCK
cat >"$TEST_DIR/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
method=GET; output=''; body=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --request) method="$2"; shift 2;;
    --output) output="$2"; shift 2;;
    --data-binary) body="${2#@}"; shift 2;;
    --config|--write-out|--proto|--connect-timeout|--max-time) shift 2;;
    https://*) url="$1"; shift;;
    *) shift;;
  esac
done
printf '%s %s\n' "$method" "$url" >>"$TEST_DIR/calls"
case "$method $url" in
  POST*)
    cp "$body" "$TEST_DIR/body"
    jq -n --rawfile config "$TEST_DIR/new" '{metadata:{name:"kubeconfig-candidate"},status:{summary:"Complete",value:$config}}' >"$output";;
  DELETE*)
    echo '{}' >"$output"
    if [ "$TEST_MODE" = cleanup-fail ]; then printf 500; exit; fi;;
  *'/v3/tokens/'*|*'/apis/ext.cattle.io/v1/tokens/'*)
    jq -n --arg mode "$TEST_MODE" '{clusterId:(if $mode == "scope" then "c-other" else "c-test" end),
      expiresAt:(if $mode == "expired" then "2000-01-01T00:00:00.000Z" else "2099-01-01T00:00:00Z" end),
      expired:false,enabled:($mode != "disabled")}' >"$output"
    if [ "$TEST_MODE" = missing ]; then printf 404; exit; fi;;
  *'/k8s/clusters/'*) echo '{"items":[]}' >"$output";;
  *) exit 1;;
esac
printf 200
MOCK
cat >"$TEST_DIR/bin/kubectl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  *'get nodes'*)
    case "$TEST_MODE" in
      unauthorized) echo 'error: You must be logged in to the server (Unauthorized)' >&2; exit 1;;
      forbidden) echo 'Forbidden' >&2; exit 1;;
      tls) echo 'x509: certificate failure' >&2; exit 1;;
    esac
    echo '{"items":[]}'
    exit;;
  *--flatten*) if [ "$TEST_MODE" = flatten-fail ]; then exit 42; fi;;
esac
exec "$REAL_KUBECTL" "$@"
MOCK
chmod +x "$TEST_DIR/bin/"*
run() {
  bash "$ROOT/scripts/rke2-kubeconfig.sh" "$1" "$TEST_DIR/rke2-test" "$DEST" "${2:-0}" 0 >"$TEST_DIR/log" 2>&1
}
assert_private() {
  [ "$(find "$1" -prune -perm 0600 | wc -l | tr -d ' ')" = 1 ] || fail 'file permissions'
}
assert_no_secrets() {
  if grep -q 'fake-' "$TEST_DIR/log"; then fail 'credentials in diagnostics'; fi
}
for TEST_MODE in unauthorized scope expired disabled missing forbidden tls; do
  export TEST_MODE
  cp "$TEST_DIR/old" "$DEST"
  : >"$TEST_DIR/calls"
  if run renew; then fail "$TEST_MODE accepted"; fi
  cmp -s "$TEST_DIR/old" "$DEST" || fail "$TEST_MODE changed local file"
  [ "$(grep -c '^DELETE .*kubeconfig-candidate$' "$TEST_DIR/calls")" = 1 ] || fail "$TEST_MODE candidate not cleaned"
  assert_no_secrets
  if [ "$TEST_MODE" = unauthorized ]; then grep -q 'ClusterAuthToken synchronization' "$TEST_DIR/log" || fail 'missing sync diagnosis'; fi
  echo "PASS: $TEST_MODE rejects candidate, preserves old config and cleans up"
done
export TEST_MODE=ok
: >"$TEST_DIR/calls"
run renew || { cat "$TEST_DIR/log"; fail renewal; }
grep -qx 'apiVersion: v1' "$DEST" || fail 'renewal did not write YAML'
kubectl --kubeconfig="$DEST" config view --raw -o json |
  jq -e '.users | length == 1 and .[0].user.token == "token-new:fake-new"' >/dev/null || fail 'wrong referenced user'
assert_private "$DEST"
backup=("$DEST".backup.*)
[ "${#backup[@]}" = 1 ] || fail 'backup missing'
cmp -s "${backup[0]}" "$TEST_DIR/old" || fail 'backup differs'
assert_private "${backup[0]}"
if grep -q '^DELETE' "$TEST_DIR/calls"; then fail 'deleted installed token'; fi
assert_no_secrets
cp "$DEST" "$TEST_DIR/installed"
run write
cmp -s "$DEST" "$TEST_DIR/installed" || fail 'write replaced renewed token from old state'
echo 'PASS: successful renewal uses referenced user, private backup; write preserves renewed file'
: >"$TEST_DIR/calls"
run test
cmp -s "$DEST" "$TEST_DIR/installed" || fail 'test changed working file'
jq -e '.spec.ttl == 600 and .spec.clusters == ["c-test"]' "$TEST_DIR/body" >/dev/null || fail 'wrong test scope or lifetime'
grep -q '^DELETE .*kubeconfig-candidate$' "$TEST_DIR/calls" || fail 'successful test not cleaned'
echo 'PASS: live-test command cleans up and keeps working file'
export TEST_MODE=cleanup-fail
if run test; then fail 'cleanup failure reported as success'; fi
grep -q 'Cleanup failed; delete Rancher Kubeconfig resource kubeconfig-candidate' "$TEST_DIR/log" || fail 'missing cleanup instructions'
export TEST_MODE=ok
rm "$DEST"
run write
grep -qx 'apiVersion: v1' "$DEST" || fail 'initial write did not write YAML'
kubectl --kubeconfig="$DEST" config view --raw -o json |
  jq -e '.users[0].user.token == "token-old:fake-old"' >/dev/null || fail 'initial write from state failed'
echo 'PASS: cleanup failures reported; missing local file initialized from state'

# Merging must keep other credentials and the current context, including an unset context.
jq '{apiVersion,kind,clusters:[{name:"other",cluster:{server:"https://127.0.0.2:6443"}}],
  users:[{name:"other",user:{token:"token-other:fake-other"}}],
  contexts:[{name:"other",context:{cluster:"other",user:"other"}}],"current-context":"other"}' "$TEST_DIR/old" >"$TEST_DIR/other"
for current in other rke2-test ''; do
  jq -s --arg current "$current" '.[0] as $old | .[1] as $other | $old |
    .users |= map(select(.name != "unrelated")) |
    .clusters += $other.clusters | .users += $other.users | .contexts += $other.contexts | ."current-context" = $current' \
    "$TEST_DIR/old" "$TEST_DIR/other" >"$TEST_DIR/merged"
  bash "$ROOT/scripts/merge-kubeconfig.sh" "$TEST_DIR/installed" "$TEST_DIR/merged" >"$TEST_DIR/log" 2>&1
  kubectl --kubeconfig="$TEST_DIR/merged" config view --raw -o json >"$TEST_DIR/merged.json"
  jq -e --arg current "$current" '(."current-context" // "") == $current and
    any(.users[]; .name == "rke2-test" and .user.token == "token-new:fake-new") and
    any(.users[]; .name == "other" and .user.token == "token-other:fake-other")' "$TEST_DIR/merged.json" >/dev/null || fail 'merge dropped credentials or changed current context'
  assert_private "$TEST_DIR/merged"
  assert_no_secrets
done
cp "$TEST_DIR/merged" "$TEST_DIR/before"
export TEST_MODE=flatten-fail
if bash "$ROOT/scripts/merge-kubeconfig.sh" "$TEST_DIR/installed" "$TEST_DIR/merged" >"$TEST_DIR/log" 2>&1; then fail 'flatten error accepted'; fi
cmp -s "$TEST_DIR/before" "$TEST_DIR/merged" || fail 'failed merge altered destination'
[ -z "$(find "$TEST_DIR" -name '.kubeconfig-work.*' -o -name 'merged.tmp.*')" ] || fail 'temporary files remain'
echo 'PASS: merge replaces credentials, preserves other/current contexts and keeps destination on failure'
