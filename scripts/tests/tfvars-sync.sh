#!/usr/bin/env bash
# Verify selective tfvars sync against a local fake of the AWS S3 commands.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
export MOCK_BUCKET_ROOT="${TEST_DIR}/bucket"
export MOCK_AWS_LOG="${TEST_DIR}/aws.log"
REPO="${TEST_DIR}/repo"
mkdir -p "${TEST_DIR}/bin" "${MOCK_BUCKET_ROOT}/opentofu/tfvars/01-infra"
mkdir -p "${MOCK_BUCKET_ROOT}/opentofu/tfvars/02-rancher"
mkdir -p "${REPO}/scripts" "${REPO}/stacks/01-infra" "${REPO}/stacks/02-rancher"
cp "${ROOT}/scripts/tfvars-sync.sh" "${REPO}/scripts/tfvars-sync.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

cat >"${TEST_DIR}/bin/aws" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = --endpoint-url ]
shift 2
[ "$1" = s3 ]
shift
case "$1" in
ls)
  find "${MOCK_BUCKET_ROOT}/opentofu/tfvars" -type f | sort | while read -r file; do
    key="opentofu/tfvars/${file#"${MOCK_BUCKET_ROOT}/opentofu/tfvars/"}"
    printf '2026-01-01 00:00:00 0 %s\n' "$key"
  done
  ;;
cp)
  source="$2"
  destination="$3"
  if [[ "$source" == s3://* ]]; then
    cp "${MOCK_BUCKET_ROOT}/${source#s3://*/}" "$destination"
    printf 'DOWNLOAD %s\n' "$source" >>"$MOCK_AWS_LOG"
  else
    target="${MOCK_BUCKET_ROOT}/${destination#s3://*/}"
    mkdir -p "$(dirname "$target")"
    cp "$source" "$target"
    printf 'UPLOAD %s\n' "$destination" >>"$MOCK_AWS_LOG"
  fi
  ;;
*) exit 1 ;;
esac
MOCK
chmod +x "${TEST_DIR}/bin/aws"

printf 'alpha = "same"\n' >"${REPO}/stacks/01-infra/terraform.tfvars"
printf 'beta = "fake-local"\n' >"${REPO}/stacks/02-rancher/terraform.tfvars"
printf 'alpha = "same"\n' >"${MOCK_BUCKET_ROOT}/opentofu/tfvars/01-infra/terraform.tfvars"
printf 'beta = "fake-remote"\n' >"${MOCK_BUCKET_ROOT}/opentofu/tfvars/02-rancher/terraform.tfvars"

run_sync() {
  PATH="${TEST_DIR}/bin:${PATH}" \
    TF_STATE_BUCKET=test AWS_ENDPOINT_URL_S3=http://mock \
    bash "${REPO}/scripts/tfvars-sync.sh" "$1" >"${TEST_DIR}/output"
}

: >"$MOCK_AWS_LOG"
run_sync push
[ "$(grep -c '^UPLOAD ' "$MOCK_AWS_LOG")" -eq 1 ] || fail 'push did not upload exactly one file'
grep -q '/02-rancher/terraform.tfvars$' "$MOCK_AWS_LOG" || fail 'push missed changed file'
grep -q 'stacks/01-infra/terraform.tfvars: same' "${TEST_DIR}/output" || fail 'push missed same status'
grep -q 'pushed stacks/02-rancher/terraform.tfvars' "${TEST_DIR}/output" || fail 'push missed changed status'
cmp -s "${REPO}/stacks/02-rancher/terraform.tfvars" \
  "${MOCK_BUCKET_ROOT}/opentofu/tfvars/02-rancher/terraform.tfvars" || fail 'push content differs'
echo 'PASS: push uploads only changed tfvars'

: >"$MOCK_AWS_LOG"
run_sync push
if grep -q '^UPLOAD ' "$MOCK_AWS_LOG"; then fail 'identical push still uploaded a file'; fi
grep -q 'nothing to push' "${TEST_DIR}/output" || fail 'identical push did not stop early'
echo 'PASS: push skips uploads when every tfvars is unchanged'

printf 'beta = "fake-pull"\n' >"${MOCK_BUCKET_ROOT}/opentofu/tfvars/02-rancher/terraform.tfvars"
chmod 0444 "${REPO}/stacks/01-infra/terraform.tfvars"
run_sync pull
grep -q 'stacks/01-infra/terraform.tfvars: same' "${TEST_DIR}/output" || fail 'pull missed same status'
grep -q 'pulled stacks/02-rancher/terraform.tfvars' "${TEST_DIR}/output" || fail 'pull missed changed status'
cmp -s "${REPO}/stacks/02-rancher/terraform.tfvars" \
  "${MOCK_BUCKET_ROOT}/opentofu/tfvars/02-rancher/terraform.tfvars" || fail 'pull content differs'
echo 'PASS: pull overwrites only changed tfvars'

chmod 0444 "${REPO}/stacks/02-rancher/terraform.tfvars"
run_sync pull
grep -q 'nothing to pull' "${TEST_DIR}/output" || fail 'identical pull did not stop early'
echo 'PASS: pull skips writes when every tfvars is unchanged'
