#!/usr/bin/env bash
# Fixture-driven regression test for the dump sanitization step.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
step_dir="${repo_root}/ci-operator/step-registry/hypershift/destroy-nested-management-cluster"
chain_file="${step_dir}/hypershift-destroy-nested-management-cluster-chain.yaml"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/hypershift-dump-redaction.XXXXXX")"
cleanup() {
  if [[ "${KEEP_TEST_ARTIFACTS:-false}" == "true" ]]; then
    echo "Test artifacts kept at ${work_dir}" >&2
  else
    rm -rf -- "${work_dir}"
  fi
}
trap cleanup EXIT

assert_contains() {
  local file="$1"
  local expected="$2"
  if ! grep -Fq -- "${expected}" "${file}"; then
    echo "Expected to find [${expected}] in ${file}" >&2
    return 1
  fi
}

assert_not_contains() {
  local file="$1"
  local unexpected="$2"
  if grep -RFq -- "${unexpected}" "${file}"; then
    echo "Unexpectedly found [${unexpected}] in ${file}" >&2
    return 1
  fi
}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

command_file="${work_dir}/dump-command.sh"
awk '
  /^    commands: \|-$/ && !started { started = 1; next }
  started && /^    [^ ]/ { exit }
  started && /^      / { print substr($0, 7); next }
  started && /^[[:space:]]*$/ { print; next }
  started { exit }
' "${chain_file}" > "${command_file}"
[[ -s "${command_file}" ]] || fail "could not extract the dump step command block"
bash -n "${command_file}" || fail "extracted dump step has invalid shell syntax"

fixture_dir="${work_dir}/fixture"
mkdir -p "${fixture_dir}/cluster-scoped-resources/core"
opaque="A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6"
lower_path_secret="k9md2nqv-7rpx4twy-8zab3k6f-5jwh"
commit="0123456789abcdef0123456789abcdef01234567"
digest="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

cat > "${fixture_dir}/cluster-scoped-resources/core/nodes.yaml" <<EOF
apiVersion: v1
kind: Node
metadata:
  name: hypershift-operator-controller-manager-abcdef
  uid: 123e4567-e89b-12d3-a456-426614174000
  commit: ${commit}
  git_commit: "${commit} diagnostic=${opaque}"
  unlabelledOpaqueBase64: "QWxwaGFCZXRhR2FtbWFEZWx0YUVwc2lsb25L/XlXb3JkLzEyMzQ1Njc4OUFCQ0RFRg=="
  digest: sha256:${digest}
  digestWithOtherDiagnostic: "sha256:${digest} diagnostic=${opaque}"
  ordinaryPath: https://api.example.invalid/api/v1/namespaces/default/status
  opaquePath: https://api.example.invalid/api/v1/${opaque}/status
  opaqueLowerPath: https://api.example.invalid/api/v1/${lower_path_secret}/status
  userInfoURL: https://fake-user:fake-short@example.invalid/api/v1/status
  databaseURL: postgres://fake-user:fake-short@db.example.invalid/hypershift
  message: "prefix password=fake-short and keep-diagnostic"
  bearerDiagnostic: "bEaReR secret~+/="
  "password": |
    multiline-block-secret
  'client-secret': 'single-quoted-secret'
  multilinePassword: "multiline-quoted-secret
    continuation-secret"
  api-key:
    folded-plain-secret
    continuation-plain-secret
  afterMultiline: retained-diagnostic
spec:
  containers:
  - name: diagnostic-container
    env:
    - value: env-value-before-name-secret
      name: "API_TOKEN"
    - name: API_TOKEN_FROM
      valueFrom:
        secretKeyRef:
          name: retained-secret-reference
          key: api-token
    - {value: "flow-env-secret", name: "DB_PASSWORD"}
    - value: |
        multiline-env-secret
        continuation-env-secret
      name: BLOCK_TOKEN
EOF

cat > "${fixture_dir}/cluster-scoped-resources/core/status.json" <<EOF
{"message":"password=json-message-secret and keep-json-diagnostic","url":"https://fake-user:fake-short@example.invalid/api","commit":"${commit}","digest":"sha256:${digest}","password":"json-field-secret","env":[{"value":"json-env-secret","name":"API_TOKEN"},{"name":"TOKEN_FROM","valueFrom":{"secretKeyRef":{"name":"retained-json-reference"}}}]}
EOF

cat > "${fixture_dir}/cluster-scoped-resources/core/event-filter.html" <<EOF
<html><body><a href="https://fake-user:fake-short@example.invalid/events/${opaque}">Authorization: bEaReR html-bearer-secret</a><p>${opaque}</p></body></html>
EOF

cat > "${fixture_dir}/cluster-scoped-resources/core/events.log" <<EOF
Authorization: short-auth-secret
AWS key AKIA1234567890ABCDEF and ASIA1234567890ABCDEF
Run --password flag-secret-value --client-secret 'quoted flag secret' keep-after-flag
diagnostic URL https://api.example.invalid/normal/path/${opaque}/events
EOF

make_fake_runner() {
  local run_dir="$1"
  mkdir -p "${run_dir}/bin"
  cat > "${run_dir}/bin/hypershift" <<'HYPERSHIFT'
#!/usr/bin/env bash
set -euo pipefail
output_dir=""
for argument in "$@"; do
  case "${argument}" in
    --artifact-dir=*) output_dir="${argument#*=}" ;;
  esac
done
[[ -n "${output_dir}" ]]
mkdir -p "${output_dir}"
cp -R "${FIXTURE_DIR}/." "${output_dir}/"
HYPERSHIFT
  chmod +x "${run_dir}/bin/hypershift"
}

run_dir="${work_dir}/normal-run"
make_fake_runner "${run_dir}"
artifact_dir="${run_dir}/artifacts"
(
  cd "${run_dir}"
  FIXTURE_DIR="${fixture_dir}" ARTIFACT_DIR="${artifact_dir}" PROW_JOB_ID=redaction-test \
    HYPERSHIFT_NAMESPACE=clusters CLOUD_PROVIDER=AWS bash "${command_file}"
)

archive="${artifact_dir}/artifacts.tar.gz"
[[ -s "${archive}" ]] || fail "sanitized archive was not published"
tar -tzf "${archive}" > "${work_dir}/archive-list.txt" || fail "archive listing failed"
assert_contains "${work_dir}/archive-list.txt" "output/cluster-scoped-resources/core/nodes.yaml"
assert_not_contains "${work_dir}/archive-list.txt" "${work_dir}"

extract_dir="${work_dir}/extracted"
mkdir -p "${extract_dir}"
tar -xzf "${archive}" -C "${extract_dir}" || fail "archive extraction failed"
yaml_file="${extract_dir}/output/cluster-scoped-resources/core/nodes.yaml"
json_file="${extract_dir}/output/cluster-scoped-resources/core/status.json"
html_file="${extract_dir}/output/cluster-scoped-resources/core/event-filter.html"
log_file="${extract_dir}/output/cluster-scoped-resources/core/events.log"

yq '.' "${yaml_file}" > /dev/null || fail "sanitized YAML is invalid"
jq '.' "${json_file}" > /dev/null || fail "sanitized JSON is invalid"

assert_contains "${yaml_file}" "commit: ${commit}"
assert_contains "${yaml_file}" "git_commit: \"${commit} diagnostic=REDACTED_HIGH_ENTROPY\""
assert_contains "${yaml_file}" 'unlabelledOpaqueBase64: "REDACTED_BASE64"'
assert_contains "${yaml_file}" "digest: sha256:${digest}"
assert_not_contains "${yaml_file}" "diagnostic=${opaque}"
assert_contains "${yaml_file}" "digestWithOtherDiagnostic: \"sha256:${digest} diagnostic=REDACTED_HIGH_ENTROPY\""
assert_contains "${yaml_file}" "ordinaryPath: https://api.example.invalid/api/v1/namespaces/default/status"
assert_contains "${yaml_file}" "opaquePath: https://api.example.invalid/api/v1/REDACTED_HIGH_ENTROPY/status"
assert_contains "${yaml_file}" "opaqueLowerPath: https://api.example.invalid/api/v1/REDACTED_HIGH_ENTROPY/status"
assert_contains "${yaml_file}" "name: hypershift-operator-controller-manager-abcdef"
assert_contains "${yaml_file}" "userInfoURL: https://REDACTED@example.invalid/api/v1/status"
assert_contains "${yaml_file}" "databaseURL: postgres://REDACTED@db.example.invalid/hypershift"
assert_contains "${yaml_file}" 'message: "prefix password=REDACTED and keep-diagnostic"'
assert_contains "${yaml_file}" 'bearerDiagnostic: "Bearer REDACTED"'
assert_contains "${yaml_file}" '"password": "REDACTED"'
assert_contains "${yaml_file}" "'client-secret': 'REDACTED'"
assert_contains "${yaml_file}" "afterMultiline: retained-diagnostic"
assert_contains "${yaml_file}" 'api-key: "REDACTED"'
assert_contains "${yaml_file}" 'value: "REDACTED"'
assert_contains "${yaml_file}" "valueFrom:"
assert_contains "${yaml_file}" "retained-secret-reference"
assert_contains "${yaml_file}" 'value: "REDACTED", name: "DB_PASSWORD"'
assert_contains "${yaml_file}" 'value: "REDACTED"'

assert_contains "${json_file}" "password=REDACTED and keep-json-diagnostic"
assert_contains "${json_file}" "https://REDACTED@example.invalid/api"
assert_contains "${json_file}" "\"commit\":\"${commit}\""
assert_contains "${json_file}" "sha256:${digest}"
jq -e '.password == "REDACTED" and .env[0].value == "REDACTED" and .env[1].valueFrom.secretKeyRef.name == "retained-json-reference"' "${json_file}" > /dev/null || fail "JSON credential or environment sanitization failed"
assert_contains "${html_file}" "https://REDACTED@example.invalid/events/REDACTED_HIGH_ENTROPY"
assert_contains "${html_file}" "Authorization: REDACTED</a>"
assert_contains "${html_file}" "</body></html>"
assert_contains "${log_file}" "Authorization: REDACTED"
assert_contains "${log_file}" "Run --password REDACTED --client-secret 'REDACTED' keep-after-flag"
assert_not_contains "${log_file}" "AKIA1234567890ABCDEF"
assert_not_contains "${log_file}" "ASIA1234567890ABCDEF"
assert_not_contains "${extract_dir}" "fake-short"
assert_not_contains "${extract_dir}" "${opaque}"
assert_not_contains "${extract_dir}" "env-value-before-name-secret"
assert_not_contains "${extract_dir}" "flow-env-secret"
assert_not_contains "${extract_dir}" "multiline-env-secret"
assert_not_contains "${extract_dir}" "continuation-env-secret"
assert_not_contains "${extract_dir}" "multiline-block-secret"
assert_not_contains "${extract_dir}" "multiline-quoted-secret"
assert_not_contains "${extract_dir}" "continuation-secret"
assert_not_contains "${extract_dir}" "folded-plain-secret"
assert_not_contains "${extract_dir}" "continuation-plain-secret"
assert_not_contains "${extract_dir}" "flag-secret-value"
assert_not_contains "${extract_dir}" "quoted flag secret"

# Exercise the Azure branch too; sanitization and archive publication are shared.
azure_run_dir="${work_dir}/azure-run"
make_fake_runner "${azure_run_dir}"
azure_artifact_dir="${azure_run_dir}/artifacts"
(
  cd "${azure_run_dir}"
  FIXTURE_DIR="${fixture_dir}" ARTIFACT_DIR="${azure_artifact_dir}" PROW_JOB_ID=redaction-test \
    HYPERSHIFT_NAMESPACE=clusters CLOUD_PROVIDER=Azure bash "${command_file}"
)
azure_archive="${azure_artifact_dir}/artifacts.tar.gz"
[[ -s "${azure_archive}" ]] || fail "Azure sanitized archive was not published"
tar -tzf "${azure_archive}" > "${work_dir}/azure-archive-list.txt" || fail "Azure archive listing failed"
azure_extract_dir="${work_dir}/azure-extracted"
mkdir -p "${azure_extract_dir}"
tar -xzf "${azure_archive}" -C "${azure_extract_dir}" || fail "Azure archive extraction failed"
diff -r "${extract_dir}/output" "${azure_extract_dir}/output" > /dev/null || fail "AWS and Azure sanitized dump contents differ"

# Inject a find failure only for the synchronous -print0 discovery. The step
# must fail closed without publishing an archive or exposing raw dump files.
failure_dir="${work_dir}/find-failure-run"
make_fake_runner "${failure_dir}"
mkdir -p "${failure_dir}/bin-wrapper"
real_find="$(command -v find)"
cat > "${failure_dir}/bin-wrapper/find" <<'FIND'
#!/usr/bin/env bash
set -euo pipefail
for argument in "$@"; do
  if [[ "${argument}" == "-print0" ]]; then
    exit 23
  fi
done
exec "${REAL_FIND}" "$@"
FIND
chmod +x "${failure_dir}/bin-wrapper/find"
failure_artifact_dir="${failure_dir}/artifacts"
if (
  cd "${failure_dir}"
  PATH="${failure_dir}/bin-wrapper:${PATH}" REAL_FIND="${real_find}" FIXTURE_DIR="${fixture_dir}" \
    ARTIFACT_DIR="${failure_artifact_dir}" PROW_JOB_ID=redaction-test HYPERSHIFT_NAMESPACE=clusters \
    CLOUD_PROVIDER=AWS bash "${command_file}"
) > "${work_dir}/find-failure.log" 2>&1; then
  fail "step unexpectedly succeeded after file discovery failed"
fi
[[ ! -e "${failure_artifact_dir}/artifacts.tar.gz" ]] || fail "archive was published after find failed"
assert_contains "${work_dir}/find-failure.log" "Failed to enumerate diagnostic files"

echo "PASS: dump sanitization, archive round-trip, and fail-closed file discovery"
