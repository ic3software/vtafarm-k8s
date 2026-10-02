#!/usr/bin/env bash
# Test the complete apply boundary, including data evacuation and failed retirement.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
export TEST_DIR
mkdir -p "$TEST_DIR/bin" "$TEST_DIR/rke2-test" "$TEST_DIR/repo/scripts" "$TEST_DIR/repo/stacks/01-infra"
touch "$TEST_DIR/rke2-test/kubeconfig.yaml" "$TEST_DIR/repo/stacks/01-infra/kubeconfig.yaml"
cp "$ROOT/scripts/rke2-apply.sh" "$TEST_DIR/repo/scripts/rke2-apply.sh"
export PATH="$TEST_DIR/bin:$PATH"
export RKE2_ETCD_HEALTH_ATTEMPTS=2
fail() { echo "FAIL: $*" >&2; exit 1; }

cat >"$TEST_DIR/fixture.py" <<'PY'
import json, os
from pathlib import Path

root = Path(os.environ['TEST_DIR'])
def save(name, value):
    (root / name).write_text(json.dumps(value))
nodes, machines, longhorn = [], [], []
for i in range(1, 6):
    name = f'rke2-test-server-{i}'
    nodes.append({'metadata': {'name': name, 'uid': f'node-{i}', 'resourceVersion': '42'},
                  'spec': {'providerID': f'hcloud://{i}'},
                  'status': {'conditions': [{'type': 'Ready', 'status': 'True'}]}})
    machines.append({'kind': 'Machine', 'apiVersion': 'cluster.x-k8s.io/v1beta2',
        'metadata': {'name': f'custom-{i}', 'namespace': 'fleet-default', 'uid': f'machine-{i}', 'resourceVersion': '42',
                     'labels': {'cluster.x-k8s.io/cluster-name': 'rke2-test', 'rke.cattle.io/etcd-role': 'true'},
                     'annotations': {'pre-terminate.delete.hook.machine.cluster.x-k8s.io/rke-bootstrap-cleanup': 'rke-bootstrap-controller'},
                     'ownerReferences': [{'kind': 'Cluster', 'name': 'rke2-test', 'uid': 'cluster-uid'}]},
        'spec': {'infrastructureRef': {'apiGroup': 'rke.cattle.io', 'kind': 'CustomMachine', 'name': f'custom-{i}'}},
        'status': {'nodeRef': {'name': name}}})
    longhorn.append({'metadata': {'name': name, 'uid': f'longhorn-{i}', 'resourceVersion': '42'},
                    'spec': {'allowScheduling': True, 'disks': {'disk': {'allowScheduling': True}}},
                    'status': {'diskStatus': {'disk': {'diskUUID': f'disk-{i}',
                        'scheduledReplica': {f'replica-{i}': 10} if i > 3 else {}, 'scheduledBackingImage': {}}}}})
changes = [{'address': f'module.rke2.hcloud_server.node["server-{i}"]', 'mode': 'managed', 'type': 'hcloud_server',
            'change': {'actions': ['delete'], 'before': {'name': f'rke2-test-server-{i}', 'id': str(i)}}} for i in (4, 5)]
changes += [{'address': f'module.rke2.hcloud_server.node["server-{i}"]', 'mode': 'managed', 'type': 'hcloud_server',
             'change': {'actions': ['no-op'], 'after': {'name': f'rke2-test-server-{i}', 'id': str(i)}}} for i in range(1, 4)]
save('plan', {'resource_changes': changes, 'planned_values': {'outputs': {
    'nodes': {'value': {f'server-{i}': {'name': f'rke2-test-server-{i}'} for i in range(1, 4)}},
    'cluster_id': {'value': 'fleet-default/rke2-test'}, 'cluster_v1_id': {'value': 'c-test'}}}})
save('nodes', {'items': nodes})
save('machines', {'items': machines})
save('longhorn', {'items': longhorn})
save('members', {'members': [{'name': f'rke2-test-server-{i}-suffix'} for i in range(1, 6)]})
save('replicas', {'items': [{'metadata': {'name': f'replica-{i}'}, 'spec': {'nodeID': f'rke2-test-server-{i}'}} for i in (4, 5)]})
save('volumes', {'items': [{'status': {'robustness': 'healthy'}}]})
save('engines', {'items': [{'spec': {'nodeID': f'rke2-test-server-{i}'}} for i in (4, 5)]})
save('backingimages', {'items': []})
save('attachments', {'items': []})
PY

cat >"$TEST_DIR/bin/tofu" <<'MOCK'
#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
root = Path(os.environ['TEST_DIR'])
args = sys.argv[1:]
with (root / 'events').open('a') as log:
    log.write('TOFU ' + ' '.join(args[1:]) + '\n')
action = args[1]
if action == 'plan':
    Path(next(a.split('=', 1)[1] for a in args if a.startswith('-out='))).write_text('private-plan')
elif action == 'show':
    print((root / 'plan').read_text())
elif action == 'state':
    changed = os.environ['TEST_MODE'] == 'state-changed' and (root / 'retired').exists()
    print(json.dumps({'serial': 2 if changed else 1, 'lineage': 'test-state'}))
elif action == 'apply':
    assert Path(args[2]).read_text() == 'private-plan'
    (root / 'applied').touch()
else:
    sys.exit(1)
MOCK

cat >"$TEST_DIR/bin/kubectl" <<'MOCK'
#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
root = Path(os.environ['TEST_DIR'])
mode = os.environ['TEST_MODE']
args = [a for a in sys.argv[1:] if not a.startswith(('--kubeconfig=', '--request-timeout='))]
def read(name):
    return json.loads((root / name).read_text())
def save(name, value):
    (root / name).write_text(json.dumps(value))
def event(text):
    with (root / 'events').open('a') as log:
        log.write(text + '\n')
def output(value):
    print(json.dumps(value))
def get(name, resource):
    value = read(resource)
    if name:
        item = next((item for item in value['items'] if item['metadata']['name'] == name), None)
        if item is not None:
            output(item)
    else:
        output(value)

action = args[0]
if action == 'get':
    resource = args[1]
    name = args[2] if len(args) > 2 and not args[2].startswith('-') else None
    if resource == 'clusters.provisioning.cattle.io':
        output({'status': {'clusterName': 'wrong' if mode == 'wrong-cluster' else 'c-test'}})
    elif resource == 'clusters.cluster.x-k8s.io':
        output({'metadata': {'uid': 'cluster-uid'}})
    elif resource == 'machines.cluster.x-k8s.io':
        get(name, 'machines')
    elif resource in ('node', 'nodes'):
        if mode == 'unavailable':
            sys.exit(1)
        if mode == 'node-recreated' and resource == 'node' and name.endswith('-4'):
            data = read('nodes')
            next(item for item in data['items'] if item['metadata']['name'] == name)['metadata']['uid'] = 'new-node'
            save('nodes', data)
        get(name, 'nodes')
    elif resource == 'customresourcedefinitions':
        if mode != 'no-longhorn':
            print('customresourcedefinition.apiextensions.k8s.io/nodes.longhorn.io')
    elif resource == 'nodes.longhorn.io':
        get(name, 'longhorn')
    elif resource == 'volumeattachments.storage.k8s.io':
        output(read('attachments'))
    elif resource.endswith('.longhorn.io'):
        output(read(resource.split('.')[0]))
    else:
        sys.exit(1)
elif action == 'patch':
    resource, name = args[1:3]
    body = read(Path(next(a.split('=', 1)[1] for a in args if a.startswith('--patch-file='))))
    key = 'nodes' if resource == 'node' else 'longhorn'
    data = read(key)
    item = next(item for item in data['items'] if item['metadata']['name'] == name)
    assert body['metadata']['uid'] == item['metadata']['uid']
    assert body['metadata']['resourceVersion'] == item['metadata']['resourceVersion']
    item['spec'].update(body['spec'])
    save(key, data)
    event('PATCH ' + resource + ' ' + name + ' ' + json.dumps(body['spec'], sort_keys=True))
    if body['spec'].get('evictionRequested'):
        assert all(not item['spec']['allowScheduling'] for item in data['items'] if item['metadata']['name'].endswith(('-4', '-5')))
        (root / 'evicting').write_text(name)
elif action == 'drain':
    name = args[1]
    assert not any(a in args for a in ('--force', '--delete-emptydir-data', '--disable-eviction'))
    assert mode == 'no-longhorn' or not any(item['spec']['nodeID'] == name for item in read('replicas')['items'])
    event('DRAIN ' + name)
    if mode == 'drain-blocked':
        sys.exit(1)
    if mode != 'detach-blocked':
        engines = read('engines')
        engines['items'] = [item for item in engines['items'] if item['spec']['nodeID'] != name]
        save('engines', engines)
elif action == 'exec':
    if 'member' in args:
        output(read('members'))
    elif 'health' in args:
        if (mode == 'etcd-transient-after-retire' and (root / 'retired').exists() and
                not (root / 'health-retried').exists()):
            (root / 'health-failed').touch()
        healthy = (mode != 'etcd-unhealthy' and
                   not (mode == 'etcd-fails-after-retire' and (root / 'retired').exists()) and
                   not (mode == 'etcd-transient-after-retire' and (root / 'retired').exists() and
                        not (root / 'health-retried').exists()))
        output([{'health': healthy} for _ in read('members')['members']])
        if not healthy:
            sys.exit(1)
    else:
        sys.exit(1)
elif action == 'delete':
    assert args[1] == '--raw' and args[3] == '-f'
    body = read(Path(args[4]))
    name = args[2].rsplit('/', 1)[1]
    data = read('machines')
    item = next(item for item in data['items'] if item['metadata']['name'] == name)
    node = item['status']['nodeRef']['name']
    assert body['preconditions']['uid'] == item['metadata']['uid']
    assert body['preconditions']['resourceVersion'] == item['metadata']['resourceVersion']
    event('RETIRE ' + node)
    if mode == 'machine-conflict':
        sys.exit(1)
    (root / 'deleting').write_text(node)
elif action == 'wait':
    name = args[2]
    if name.startswith('machines.'):
        if mode == 'machine-pending':
            sys.exit(1)
        node = (root / 'deleting').read_text()
        data = read('machines')
        data['items'] = [item for item in data['items'] if item['status']['nodeRef']['name'] != node]
        save('machines', data)
        data = read('nodes')
        data['items'] = [item for item in data['items'] if item['metadata']['name'] != node]
        save('nodes', data)
        if mode != 'member-stuck':
            data = read('members')
            data['members'] = [item for item in data['members'] if not item['name'].startswith(node + '-')]
            save('members', data)
        (root / 'retired').touch()
        event('RETIRED ' + node)
        if mode == 'storage-reappears' and node.endswith('-5'):
            data = read('replicas')
            data['items'].append({'spec': {'nodeID': 'rke2-test-server-4'}})
            save('replicas', data)
    elif name.startswith('node/'):
        assert not any(item['metadata']['name'] == name[5:] for item in read('nodes')['items'])
    else:
        sys.exit(1)
else:
    sys.exit(1)
MOCK

cat >"$TEST_DIR/bin/sleep" <<'MOCK'
#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
root = Path(os.environ['TEST_DIR'])
mode = os.environ['TEST_MODE']
if mode == 'etcd-transient-after-retire' and (root / 'health-failed').exists():
    (root / 'health-retried').touch()
if not (root / 'evicting').exists():
    sys.exit(0)
if mode in ('eviction-blocked', 'detach-blocked'):
    sys.exit(1)
name = (root / 'evicting').read_text()
data = json.loads((root / 'replicas').read_text())
for item in data['items']:
    if item['spec']['nodeID'] == name:
        item['spec']['nodeID'] = 'rke2-test-server-1'
(root / 'replicas').write_text(json.dumps(data))
data = json.loads((root / 'longhorn').read_text())
for item in data['items']:
    if item['metadata']['name'] == name:
        item['status']['diskStatus']['disk']['scheduledReplica'] = {}
(root / 'longhorn').write_text(json.dumps(data))
with (root / 'events').open('a') as log:
    log.write('EVACUATED ' + name + '\n')
MOCK
chmod +x "$TEST_DIR/bin/"*

reset_case() {
  export TEST_MODE="$1"
  python3 "$TEST_DIR/fixture.py"
  rm -f "$TEST_DIR/applied" "$TEST_DIR/evicting" "$TEST_DIR/retired" "$TEST_DIR/deleting" \
    "$TEST_DIR/health-failed" "$TEST_DIR/health-retried"
  : >"$TEST_DIR/events"
}
run() {
  bash "$TEST_DIR/repo/scripts/rke2-apply.sh" "$TEST_DIR/rke2-test" <<<"${1:-yes}" >"$TEST_DIR/log" 2>&1
}
expect_blocked() {
  if run; then fail "$TEST_MODE unexpectedly succeeded"; fi
  [ ! -f "$TEST_DIR/applied" ] || fail "$TEST_MODE allowed VM deletion"
  [ ! -d "$TEST_DIR/rke2-test/.rke2-apply-lock" ] || fail 'left the apply lock behind'
}

reset_case ok
run || { cat "$TEST_DIR/log"; fail 'safe shrink'; }
python3 - <<'PY'
import os
from pathlib import Path
root = Path(os.environ['TEST_DIR'])
events = (root / 'events').read_text().splitlines()
for i in (4, 5):
    node = f'rke2-test-server-{i}'
    assert events.index('EVACUATED ' + node) < events.index('DRAIN ' + node) < events.index('RETIRE ' + node) < events.index('RETIRED ' + node)
assert events.index('RETIRED rke2-test-server-4') < events.index('RETIRE rke2-test-server-5')
assert events[-1].startswith('TOFU apply ')
assert (root / 'applied').exists()
assert not (root / 'rke2-test/.rke2-apply-lock').exists()
PY
echo 'PASS: single-replica data is rebuilt before drain; Rancher retires servers sequentially before VM apply'

for mode in eviction-blocked drain-blocked detach-blocked etcd-unhealthy etcd-fails-after-retire member-stuck machine-conflict machine-pending wrong-cluster unavailable state-changed node-recreated storage-reappears; do
  reset_case "$mode"
  expect_blocked
done
echo 'PASS: blocked evacuation, PDB/drain, detach, etcd and Rancher failures all prevent VM deletion'

reset_case etcd-transient-after-retire
run || { cat "$TEST_DIR/log"; fail 'transient etcd convergence'; }
[ -f "$TEST_DIR/applied" ] || fail 'did not continue after etcd recovered'
rg -q 'Waiting for etcd membership and endpoints to converge' "$TEST_DIR/log" || fail 'did not retry transient etcd health'
echo 'PASS: transient etcd convergence after member removal is retried before proceeding'

reset_case ok
for resource in nodes machines longhorn replicas engines; do
  case "$resource" in
    nodes|longhorn) key=metadata.name;;
    machines) key=status.nodeRef.name;;
    *) key=spec.nodeID;;
  esac
  jq --arg node rke2-test-server-4 ".items |= map(select(.$key != \$node))" "$TEST_DIR/$resource" >"$TEST_DIR/next"
  mv "$TEST_DIR/next" "$TEST_DIR/$resource"
done
jq '.members |= map(select(.name | startswith("rke2-test-server-4-") | not))' "$TEST_DIR/members" >"$TEST_DIR/next"
mv "$TEST_DIR/next" "$TEST_DIR/members"
run || { cat "$TEST_DIR/log"; fail 'resume after partial retirement'; }
[ -f "$TEST_DIR/applied" ] || fail 'did not apply after resuming partial retirement'
if rg -q '^RETIRE rke2-test-server-4$' "$TEST_DIR/events"; then fail 'retired the already absent server again'; fi
rg -q '^RETIRED rke2-test-server-5$' "$TEST_DIR/events" || fail 'did not continue with the remaining server'
echo 'PASS: rerun resumes after one server was already retired and its VM was preserved'

for change in '.[3].spec.providerID="hcloud://999"' '.[4].status.conditions[0].status="False"'; do
  reset_case ok
  jq ".items |= ($change)" "$TEST_DIR/nodes" >"$TEST_DIR/next"
  mv "$TEST_DIR/next" "$TEST_DIR/nodes"
  expect_blocked
  if rg -q '^PATCH|^DRAIN|^RETIRE' "$TEST_DIR/events"; then fail 'mutated before validating every node'; fi
done
reset_case ok
jq '.items[3].metadata.ownerReferences[0].uid="other-cluster"' "$TEST_DIR/machines" >"$TEST_DIR/next"
mv "$TEST_DIR/next" "$TEST_DIR/machines"
expect_blocked
echo 'PASS: wrong VM identities, non-Ready nodes and unrelated Machine ownership are rejected before mutation'

reset_case ok
run no && fail 'cancelled plan was executed'
if rg -q '^PATCH|^DRAIN|^RETIRE|TOFU apply' "$TEST_DIR/events"; then fail 'mutated a cancelled plan'; fi
echo 'PASS: cancellation changes neither the cluster nor VMs'

for filter in '.resource_changes[0].change.actions=["delete","create"]' \
  '.resource_changes += [{mode:"managed",type:"hcloud_server",change:{actions:["create"]}}]' \
  '.resource_changes += [{mode:"managed",type:"rancher2_cluster_v2",change:{actions:["update"]}}]'; do
  reset_case ok
  jq "$filter" "$TEST_DIR/plan" >"$TEST_DIR/next"
  mv "$TEST_DIR/next" "$TEST_DIR/plan"
  expect_blocked
  if rg -q '^PATCH|^DRAIN|^RETIRE' "$TEST_DIR/events"; then fail 'mutated an unsupported plan'; fi
done
echo 'PASS: replacements, mixed grow/shrink and unrelated infrastructure updates cannot bypass staged retirement'

reset_case no-longhorn
run || { cat "$TEST_DIR/log"; fail 'retirement without Longhorn'; }
[ -f "$TEST_DIR/applied" ] || fail 'blocked a cluster without Longhorn'
echo 'PASS: clusters without Longhorn still drain and retire nodes before VM deletion'

reset_case ok
python3 - <<'PY'
import json, os
from pathlib import Path
root = Path(os.environ['TEST_DIR'])
mapping = {'rke2-test-server-4': 'rke2-test-worker-1', 'rke2-test-server-5': 'rke2-test-worker-2'}
for filename in ('plan', 'nodes', 'machines', 'longhorn', 'replicas', 'engines'):
    text = (root / filename).read_text()
    for before, after in mapping.items():
        text = text.replace(before, after)
    if filename == 'plan':
        text = text.replace('server-4', 'worker-1').replace('server-5', 'worker-2')
    (root / filename).write_text(text)
members = json.loads((root / 'members').read_text())
members['members'] = members['members'][:3]
(root / 'members').write_text(json.dumps(members))
PY
run || { cat "$TEST_DIR/log"; fail 'dedicated worker shrink'; }
[ -f "$TEST_DIR/applied" ] || fail 'did not apply worker shrink'
rg -q '^RETIRED rke2-test-worker-2$' "$TEST_DIR/events" || fail 'missed the second worker'
echo 'PASS: dedicated worker shrink evacuates storage without removing a surviving server'

reset_case ok
jq '.resource_changes=[]' "$TEST_DIR/plan" >"$TEST_DIR/next"
mv "$TEST_DIR/next" "$TEST_DIR/plan"
run || { cat "$TEST_DIR/log"; fail 'ordinary apply'; }
[ -f "$TEST_DIR/applied" ] || fail 'did not apply the ordinary saved plan'
[ ! -d "$TEST_DIR/rke2-test/.rke2-apply-lock" ] || fail 'ordinary apply left its lock'
if rg -q '^PATCH|^DRAIN|^RETIRE' "$TEST_DIR/events"; then fail 'retired nodes on an ordinary apply'; fi
echo 'PASS: an apply without VM deletion uses the same saved plan and needs no cluster mutations'
