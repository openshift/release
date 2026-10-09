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
  notcommit: ${commit}
  git_commit: "${commit} diagnostic=${opaque}"
  unlabelledOpaqueBase64: "QWxwaGFCZXRhR2FtbWFEZWx0YUVwc2lsb25L/XlXb3JkLzEyMzQ1Njc4OUFCQ0RFRg=="
  digest: sha256:${digest}
  quotedDigest: "sha256:${digest}"
  digestWithOtherDiagnostic: "sha256:${digest} diagnostic=${opaque}"
  hashes:
    "commit": ${commit}
    "sha256": ${digest}
    "digest": sha256:${digest}
    notcommit: ${commit}
  quotedHashFlow: {"commit": ${commit}, "sha256": ${digest}, "digest": sha256:${digest}, "notcommit": ${commit}}
  quotedHashValues:
    "commit": "${commit}"
    "sha256": "${digest}"
    "digest": "sha256:${digest}"
    notcommit: "${commit}"
  sourceFile: kubernetes/kubernetes/pkg/controller/deployment/sync.go
  image: quay.io/openshift/hypershift-controller:v2.0
  diagnosticFlow: {password: fake-flow-root, keep: retained}
  anchoredPassword: &diagnosticSecret anchored-yaml-secret
  anchorAlias: *diagnosticSecret
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
  pemMessage: "before -----BEGIN PRIVATE KEY-----
    multiline-private-key-material
    -----END PRIVATE KEY----- after-field"
  pemPassword: "before -----BEGIN PRIVATE KEY-----
    quoted-password-pem-secret
    -----END PRIVATE KEY----- after-password-pem"
  pemMessages: "before -----BEGIN PRIVATE KEY-----
    repeated-yaml-pem-one
    -----END PRIVATE KEY----- between -----BEGIN CERTIFICATE-----
    repeated-yaml-pem-two
    -----END CERTIFICATE----- after-repeated-pem"
  afterDiagnosticPem: retained-after-pem
spec:
  template:
    spec:
      automountServiceAccountToken: false
      volumes:
      - name: projected-diagnostics
        projected:
          sources:
          - serviceAccountToken:
              audience: api
              expirationSeconds: 3607
              path: token
          - secret:
              name: projected-secret-reference
              items:
              - key: username
                path: username
      - name: secret-diagnostics
        secret:
          secretName: volume-secret-reference
          items:
          - key: password
            path: password
      containers:
      - name: argument-container
        args:
        - --password
        - yaml-argument-secret
        - --namespace
        - default
      - name: inline-argument-container
        args: ["--password", "inline-args-fake", "--namespace", "default"]
      - name: script-diagnostic-container
        image: "quay.io/demo/controller@sha256:${digest}"
        command:
        - /bin/sh
        - -c
        - |
          cat <<'SCRIPT'
          env: [
          args: [
          password=block-script-secret
          SCRIPT
        env:
        - name: API_TOKEN
          value: after-scalar-env-secret
        args:
        - --password
        - after-scalar-arg-secret
      - name: args-script-diagnostic-container
        args:
        - |
          cat <<'SCRIPT'
          env: [
          args: [
          SCRIPT
        - --token
        - after-args-script-secret
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
    - {name: DB_PASSWORD,
       value: wrapped-flow-env-secret}
    - value: |
        multiline-env-secret
        continuation-env-secret
      name: BLOCK_TOKEN
    - name: API_TOKEN
      value: "before -----BEGIN CERTIFICATE-----
        forced-env-pem-secret
        -----END CERTIFICATE-----"
    - name: AFTER_DIAGNOSTIC
      value: retained-after-forced-pem
  - name: flow-environment-container
    env: [{name: DB_PASSWORD,
           value: inline-flow-env-fake},
          {value: value-before-name-fake,
           name: API_TOKEN},
          {value: don't-break-flow,
           name: APP_MODE},
          {name: QUOTE_DIAGNOSTIC,
           value: keep " diagnostic}]
EOF

cat > "${fixture_dir}/cluster-scoped-resources/core/events.yaml" <<'EOF'
apiVersion: events.k8s.io/v1
kind: Event
message: |
  cannot load script fragment:
  env: [
  password: event-block-scalar-secret
  unexpected end of input
reason: Failed
EOF

cat > "${fixture_dir}/cluster-scoped-resources/core/root-flow.yaml" <<'EOF'
{password: fake-flow-root-secret, keep: retained-root-flow-field}
EOF

cat > "${fixture_dir}/cluster-scoped-resources/core/quoted-hashes.yaml" <<EOF
"commit": "${commit}"
"sha256": "${digest}"
"digest": "sha256:${digest}"
notcommit: "${commit}"
EOF

cat > "${fixture_dir}/cluster-scoped-resources/core/status.json" <<EOF
{
  "message":"password=json-message-secret and keep-json-diagnostic",
  "url":"https://fake-user:fake-short@example.invalid/api",
  "commit":"${commit}",
  "notcommit":"${commit}",
  "digest":"sha256:${digest}",
  "password":"json-field-secret",
  "serviceAccountToken":{"audience":"api","expirationSeconds":3607,"path":"token"},
  "automountServiceAccountToken":false,
  "client\u005fsecret":"unicode-escaped-json-secret",
  "volumes":[
    {"projected":{"sources":[
      {"serviceAccountToken":{"audience":"api","expirationSeconds":3607,"path":"token"}},
      {"secret":{"name":"retained-projected-secret","items":[{"key":"username","path":"username"}]}}
    ]}},
    {"secret":{"secretName":"retained-volume-secret","items":[{"key":"password","path":"password"}]}}
  ],
  "token":null,
  "items":[{"spec":{"containers":[
    {"name":"first","image":"quay.io/demo/controller@sha256:${digest}","env":[{"name":"API_TOKEN","value":"pretty-json-env-secret"}]},
    {"name":"second","env":[{"value":"second-container-secret","name":"DB_PASSWORD"}]}
  ]}}],
  "compactContainers":[{"env":[{"name":"API_TOKEN","value":"compact-first-secret"}]},{"env":[{"value":"compact-second-secret","name":"DB_PASSWORD"}]}],
  "args":["--password","json-argument-secret","--namespace","default"],
  "env":[{"value":"json-env-secret","name":"API_TOKEN"},{"name":"TOKEN_FROM","valueFrom":{"secretKeyRef":{"name":"retained-json-reference"}}}],
  "pem":"pre -----BEGIN PRIVATE KEY-----inline-key-one-----END PRIVATE KEY----- middle -----BEGIN CERTIFICATE-----inline-key-two-----END CERTIFICATE----- post",
  "pemBefore":"-----BEGIN PRIVATE KEY-----sibling-key-one-----END PRIVATE KEY-----","keepBetweenPem":"retained-between-pem","pemAfter":"-----BEGIN CERTIFICATE-----sibling-key-two-----END CERTIFICATE-----",
  "keep":"retained-json-field"
}
EOF

cat > "${fixture_dir}/cluster-scoped-resources/core/timestamp" <<EOF
password=fake-extensionless-secret
EOF
printf 'binary\000fake-binary-secret' > "${fixture_dir}/cluster-scoped-resources/core/binary-data"

cat > "${fixture_dir}/cluster-scoped-resources/core/event-filter.html" <<EOF
<html><body><a href="https://fake-user:fake-short@example.invalid/events/${opaque}">Authorization: bEaReR html-bearer-secret</a><p>${opaque}</p></body></html>
EOF

cat > "${fixture_dir}/cluster-scoped-resources/core/events.log" <<EOF
Authorization: short-auth-secret
message Authorization: Basic ZmFrZTpmYWtl
AWS key AKIA1234567890ABCDEF and ASIA1234567890ABCDEF
Run --password flag-secret-value --client-secret 'quoted flag secret' keep-after-flag
Run argv --token separate-log-argument --namespace default
message image: ${opaque}
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
root_flow_file="${extract_dir}/output/cluster-scoped-resources/core/root-flow.yaml"
quoted_hash_file="${extract_dir}/output/cluster-scoped-resources/core/quoted-hashes.yaml"
json_file="${extract_dir}/output/cluster-scoped-resources/core/status.json"
html_file="${extract_dir}/output/cluster-scoped-resources/core/event-filter.html"
log_file="${extract_dir}/output/cluster-scoped-resources/core/events.log"
events_file="${extract_dir}/output/cluster-scoped-resources/core/events.yaml"
timestamp_file="${extract_dir}/output/cluster-scoped-resources/core/timestamp"

yq '.' "${yaml_file}" > /dev/null || fail "sanitized YAML is invalid"
yq '.' "${events_file}" > /dev/null || fail "sanitized Event YAML is invalid"
yq '.' "${root_flow_file}" > /dev/null || fail "sanitized root flow YAML is invalid"
yq '.' "${quoted_hash_file}" > /dev/null || fail "sanitized quoted-hash YAML is invalid"
jq '.' "${json_file}" > /dev/null || fail "sanitized JSON is invalid"

yq -e ".metadata.hashes.\"commit\" == \"${commit}\" and .metadata.hashes.\"sha256\" == \"${digest}\" and .metadata.hashes.\"digest\" == \"sha256:${digest}\" and .metadata.hashes.notcommit == \"REDACTED_HIGH_ENTROPY\" and .metadata.quotedHashFlow.\"commit\" == \"${commit}\" and .metadata.quotedHashFlow.\"sha256\" == \"${digest}\" and .metadata.quotedHashFlow.\"digest\" == \"sha256:${digest}\" and .metadata.quotedHashFlow.notcommit == \"REDACTED_HIGH_ENTROPY\"" "${yaml_file}" > /dev/null || fail "quoted hash keys were redacted or unrelated tokens were preserved"
yq -e ".metadata.quotedHashValues.\"commit\" == \"${commit}\" and .metadata.quotedHashValues.\"sha256\" == \"${digest}\" and .metadata.quotedHashValues.\"digest\" == \"sha256:${digest}\" and .metadata.quotedHashValues.notcommit == \"REDACTED_HIGH_ENTROPY\" and .spec.template.spec.containers[2].image == \"quay.io/demo/controller@sha256:${digest}\"" "${yaml_file}" > /dev/null || fail "quoted YAML hash values or image digest were not preserved exactly"
yq -e '.spec.template.spec.containers[2].env[0].value == "REDACTED" and .spec.template.spec.containers[2].args[1] == "REDACTED" and (.spec.template.spec.containers[2].command[2] | (contains("env: [") and contains("args: ["))) and (.spec.template.spec.containers[3].args[0] | (contains("env: [") and contains("args: ["))) and .spec.template.spec.containers[3].args[2] == "REDACTED"' "${yaml_file}" > /dev/null || fail "block-scalar command content was misparsed or following credentials were not redacted"
yq -e '.message | (contains("env: [") and contains("password: REDACTED") and contains("unexpected end of input"))' "${events_file}" > /dev/null || fail "Event block-scalar diagnostics were not preserved and sanitized"
yq -e '.metadata.pemMessages | contains("between")' "${yaml_file}" > /dev/null || fail "repeated PEM redaction lost the intervening diagnostic"
yq -e '.metadata.pemMessages | contains("after-repeated-pem")' "${yaml_file}" > /dev/null || fail "repeated PEM redaction lost trailing diagnostic content"
yq -e '.spec.template.spec.automountServiceAccountToken == false and .spec.template.spec.volumes[0].projected.sources[0].serviceAccountToken.audience == "api" and .spec.template.spec.volumes[0].projected.sources[0].serviceAccountToken.expirationSeconds == 3607 and .spec.template.spec.volumes[0].projected.sources[0].serviceAccountToken.path == "token" and .spec.template.spec.volumes[0].projected.sources[1].secret.name == "projected-secret-reference" and .spec.template.spec.volumes[1].secret.secretName == "volume-secret-reference"' "${yaml_file}" > /dev/null || fail "sanitization damaged Pod configuration diagnostics"
yq -e ".spec.template.spec.containers[1].args[0] == \"--password\" and .spec.template.spec.containers[1].args[1] == \"REDACTED\" and .spec.template.spec.containers[1].args[2] == \"--namespace\" and .spec.template.spec.containers[1].args[3] == \"default\" and .spec.containers[0].env[3].value == \"REDACTED\" and .spec.containers[0].env[5].value == \"REDACTED\" and .spec.containers[0].env[6].value == \"retained-after-forced-pem\" and .spec.containers[1].env[0].value == \"REDACTED\" and .spec.containers[1].env[1].value == \"REDACTED\" and .spec.containers[1].env[2].value == \"don't-break-flow\"" "${yaml_file}" > /dev/null || fail "flow-style arguments or environment values were not safely handled"
yq -e '.password == "REDACTED" and .keep == "retained-root-flow-field"' "${root_flow_file}" > /dev/null || fail "root flow YAML redaction damaged sibling fields"
yq -e ".commit == \"${commit}\" and .sha256 == \"${digest}\" and .digest == \"sha256:${digest}\" and .notcommit == \"REDACTED_HIGH_ENTROPY\"" "${quoted_hash_file}" > /dev/null || fail "quoted YAML hash keys were redacted or unrelated tokens were preserved"

assert_contains "${yaml_file}" "commit: ${commit}"
assert_contains "${yaml_file}" "notcommit: REDACTED_HIGH_ENTROPY"
assert_contains "${yaml_file}" "git_commit: \"${commit} diagnostic=REDACTED_HIGH_ENTROPY\""
assert_contains "${yaml_file}" 'unlabelledOpaqueBase64: "REDACTED_BASE64"'
assert_contains "${yaml_file}" "digest: sha256:${digest}"
assert_contains "${yaml_file}" "quotedDigest: \"sha256:${digest}\""
assert_contains "${yaml_file}" "sourceFile: kubernetes/kubernetes/pkg/controller/deployment/sync.go"
assert_contains "${yaml_file}" "image: quay.io/openshift/hypershift-controller:v2.0"
assert_contains "${yaml_file}" 'diagnosticFlow: {password: REDACTED, keep: retained}'
assert_contains "${yaml_file}" 'anchoredPassword: &diagnosticSecret "REDACTED"'
assert_contains "${yaml_file}" 'anchorAlias: *diagnosticSecret'
assert_contains "${yaml_file}" 'pemMessage: "before REDACTED_PEM'
assert_contains "${yaml_file}" 'after-field"'
assert_contains "${yaml_file}" 'pemPassword: "REDACTED"'
assert_contains "${yaml_file}" 'afterDiagnosticPem: retained-after-pem'
assert_contains "${yaml_file}" 'args: ["--password", "REDACTED", "--namespace", "default"]'
assert_contains "${yaml_file}" 'value: "REDACTED", name: "DB_PASSWORD"'
assert_contains "${yaml_file}" 'value: retained-after-forced-pem'
assert_contains "${yaml_file}" "value: don't-break-flow"
assert_contains "${yaml_file}" 'value: keep " diagnostic'
assert_contains "${yaml_file}" 'password=REDACTED'
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
assert_contains "${json_file}" '"notcommit":"REDACTED_HIGH_ENTROPY"'
assert_contains "${json_file}" "sha256:${digest}"
jq --arg digest "${digest}" -e '.password == "REDACTED" and .client_secret == "REDACTED" and .serviceAccountToken == {"audience":"api","expirationSeconds":3607,"path":"token"} and .automountServiceAccountToken == false and .volumes[0].projected.sources[0].serviceAccountToken.audience == "api" and .volumes[0].projected.sources[1].secret.name == "retained-projected-secret" and .volumes[1].secret.secretName == "retained-volume-secret" and .token == "REDACTED" and .items[0].spec.containers[0].image == ("quay.io/demo/controller@sha256:" + $digest) and .items[0].spec.containers[0].env[0].value == "REDACTED" and .items[0].spec.containers[1].env[0].value == "REDACTED" and .compactContainers[0].env[0].value == "REDACTED" and .compactContainers[1].env[0].value == "REDACTED" and .args == ["--password", "REDACTED", "--namespace", "default"] and .env[0].value == "REDACTED" and .env[1].valueFrom.secretKeyRef.name == "retained-json-reference" and .keep == "retained-json-field" and .keepBetweenPem == "retained-between-pem" and .pemBefore == "REDACTED_PEM" and .pemAfter == "REDACTED_PEM" and (.pem | contains("REDACTED_PEM") and contains("middle") and contains("post"))' "${json_file}" > /dev/null || fail "JSON credential, argument, PEM, or diagnostic preservation failed"
assert_contains "${html_file}" "https://REDACTED@example.invalid/events/REDACTED_HIGH_ENTROPY"
assert_contains "${html_file}" "Authorization: REDACTED</a>"
assert_contains "${html_file}" "</body></html>"
assert_contains "${log_file}" "Authorization: REDACTED"
assert_contains "${log_file}" "message Authorization: REDACTED"
assert_contains "${log_file}" "Run --password REDACTED --client-secret 'REDACTED' keep-after-flag"
assert_contains "${timestamp_file}" "password=REDACTED"
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
assert_not_contains "${extract_dir}" "yaml-argument-secret"
assert_not_contains "${extract_dir}" "json-argument-secret"
assert_not_contains "${extract_dir}" "separate-log-argument"
assert_not_contains "${extract_dir}" "ZmFrZTpmYWtl"
assert_not_contains "${extract_dir}" "fake-extensionless-secret"
assert_not_contains "${extract_dir}" "anchored-yaml-secret"
assert_not_contains "${extract_dir}" "multiline-private-key-material"
assert_not_contains "${extract_dir}" "quoted-password-pem-secret"
assert_not_contains "${extract_dir}" "forced-env-pem-secret"
assert_not_contains "${extract_dir}" "wrapped-flow-env-secret"
assert_not_contains "${extract_dir}" "inline-flow-env-fake"
assert_not_contains "${extract_dir}" "value-before-name-fake"
assert_not_contains "${extract_dir}" "unicode-escaped-json-secret"
assert_not_contains "${extract_dir}" "inline-args-fake"
assert_not_contains "${extract_dir}" "repeated-yaml-pem-one"
assert_not_contains "${extract_dir}" "repeated-yaml-pem-two"
assert_not_contains "${extract_dir}" "after-scalar-env-secret"
assert_not_contains "${extract_dir}" "after-scalar-arg-secret"
assert_not_contains "${extract_dir}" "block-script-secret"
assert_not_contains "${extract_dir}" "event-block-scalar-secret"
assert_not_contains "${extract_dir}" "after-args-script-secret"
assert_not_contains "${extract_dir}" "inline-key-one"
assert_not_contains "${extract_dir}" "inline-key-two"
assert_not_contains "${extract_dir}" "sibling-key-one"
assert_not_contains "${extract_dir}" "sibling-key-two"
[[ ! -e "${extract_dir}/output/cluster-scoped-resources/core/binary-data" ]] || fail "binary diagnostic file was archived"

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
assert_contains "${work_dir}/find-failure.log" "Failed to enumerate dump files"

# A PEM begin marker without a matching end marker must fail closed rather than
# archive a partially rewritten structured diagnostic.
pem_failure_dir="${work_dir}/pem-failure-run"
make_fake_runner "${pem_failure_dir}"
cp -R "${fixture_dir}/." "${pem_failure_dir}/fixture-copy"
mkdir -p "${pem_failure_dir}/fixture-copy/cluster-scoped-resources/core"
printf '%s\n' '-----BEGIN PRIVATE KEY-----unclosed-private-key' > \
  "${pem_failure_dir}/fixture-copy/cluster-scoped-resources/core/unclosed"
pem_failure_artifact_dir="${pem_failure_dir}/artifacts"
if (
  cd "${pem_failure_dir}"
  FIXTURE_DIR="${pem_failure_dir}/fixture-copy" ARTIFACT_DIR="${pem_failure_artifact_dir}" \
    PROW_JOB_ID=redaction-test HYPERSHIFT_NAMESPACE=clusters CLOUD_PROVIDER=AWS bash "${command_file}"
) > "${work_dir}/pem-failure.log" 2>&1; then
  fail "step unexpectedly succeeded after an unterminated PEM block"
fi
[[ ! -e "${pem_failure_artifact_dir}/artifacts.tar.gz" ]] || fail "archive was published with an unterminated PEM block"
assert_contains "${work_dir}/pem-failure.log" "Unterminated PEM block"

# An unterminated flow collection must also fail closed rather than publishing
# a file that has not reached credential sanitization.
flow_failure_dir="${work_dir}/flow-failure-run"
make_fake_runner "${flow_failure_dir}"
cp -R "${fixture_dir}/." "${flow_failure_dir}/fixture-copy"
printf '%s\n' 'env: [{name: API_TOKEN,' '       value: unclosed-flow-secret' > \
  "${flow_failure_dir}/fixture-copy/cluster-scoped-resources/core/unclosed-flow.yaml"
flow_failure_artifact_dir="${flow_failure_dir}/artifacts"
if (
  cd "${flow_failure_dir}"
  FIXTURE_DIR="${flow_failure_dir}/fixture-copy" ARTIFACT_DIR="${flow_failure_artifact_dir}" \
    PROW_JOB_ID=redaction-test HYPERSHIFT_NAMESPACE=clusters CLOUD_PROVIDER=AWS bash "${command_file}"
) > "${work_dir}/flow-failure.log" 2>&1; then
  fail "step unexpectedly succeeded after an unterminated YAML flow collection"
fi
[[ ! -e "${flow_failure_artifact_dir}/artifacts.tar.gz" ]] || fail "archive was published with an unterminated YAML flow collection"
assert_contains "${work_dir}/flow-failure.log" "Unterminated YAML flow collection"

echo "PASS: dump sanitization, archive round-trip, diagnostic preservation, and fail-closed handling"
