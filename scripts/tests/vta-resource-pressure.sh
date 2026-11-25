#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/vta-pressure-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

cat >"$WORK/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
args=" $* "
if [[ "$args" == *" get pods "* ]]; then
  printf 'fpp-user-2\tvta-10-new\tvta\tvta\ttrue\n'
  printf 'fpp-user-3\tfs-20-vta-new\tfs-vta\tvta\ttrue\n'
elif [[ "$args" == *" exec "* && "$args" == *"/work/vta/config.toml"* ]]; then
  if [[ "$args" == *" fs-20-vta-new "* ]]; then
    printf '%s\n' 'did:webvh:test:full-stack-vta'
  else
    printf '%s\n' 'did:webvh:test:my-vta'
  fi
elif [[ "$args" == *" get pod "* ]]; then
  printf '100m'
elif [[ "$args" == *"memory.max"* ]]; then
  printf '67108864 12582912 2097152\n'
elif [[ "$args" == *" exec "* ]]; then
  while [ "$#" -gt 2 ]; do
    if [ "$1" = perl ] && [ "$2" = -e ]; then
      perl -c -e "$3" >/dev/null 2>&1
      exit
    fi
    shift
  done
  exit 0
else
  echo "unexpected kubectl call: $*" >&2
  exit 1
fi
EOF
chmod +x "$WORK/kubectl"

run() {
  PATH="$WORK:$PATH" "$ROOT/scripts/vta-resource-pressure.sh" "$@"
}

cpu_output="$(run --did did:webvh:test:my-vta --resource cpu --level critical --dry-run)"
grep -q 'Pod:       fpp-user-2/vta-10-new' <<<"$cpu_output"
grep -q 'CPU limit: 100m; planned load: approximately 95m' <<<"$cpu_output"
grep -q 'Duration:  720s' <<<"$cpu_output"

full_stack_output="$(run --did did:webvh:test:full-stack-vta --resource cpu --level critical --dry-run)"
grep -q 'Pod:       fpp-user-3/fs-20-vta-new' <<<"$full_stack_output"

memory_output="$(run --did did:webvh:test:my-vta --resource memory --level warning --dry-run)"
grep -q 'current working set: 10MiB' <<<"$memory_output"
grep -q 'Planned working-set target: 52MiB' <<<"$memory_output"
grep -q 'Duration:  660s' <<<"$memory_output"

memory_run_output="$(run --did did:webvh:test:my-vta --resource memory --level critical --duration 30 --yes)"
grep -q 'Pressure test finished' <<<"$memory_run_output"

if run --context rke2-vtafarm-production --did did:webvh:test:my-vta --resource cpu --level critical --dry-run \
  >"$WORK/non-dev-output" 2>&1; then
  echo 'expected non-development context guard to fail' >&2
  exit 1
fi
grep -q 'refusing non-development context' "$WORK/non-dev-output"

echo 'vta resource pressure tests passed'
