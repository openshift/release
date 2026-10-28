#!/usr/bin/env bash
# Fixture-driven regression test for the dump sanitization step.
set -euo pipefail
unset FAKE_DUMP_EXIT_STATUS

# Fail with a clear message before setup or fixture assertions if a dependency
# is missing.
for required_tool in awk base64 bash cat chmod cmp cp cut dirname find gitleaks grep jq mkdir mktemp od rm sed sha256sum tar tr yq; do
  if ! command -v "${required_tool}" > /dev/null 2>&1; then
    printf 'required test tool is unavailable: %s\n' "${required_tool}" >&2
    exit 1
  fi
done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
step_dir="${repo_root}/ci-operator/step-registry/hypershift/destroy-nested-management-cluster/dump-management-cluster"
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
    echo "Expected fixture output was not found in ${file}" >&2
    return 1
  fi
}

assert_not_contains() {
  local file="$1"
  local unexpected="$2"
  if grep -RFq -- "${unexpected}" "${file}"; then
    echo "Unexpected sensitive fixture content found in ${file}" >&2
    return 1
  else
    local grep_status=$?
    if [[ "${grep_status}" -ne 1 ]]; then
      echo "Could not scan fixture output at ${file}" >&2
      return 1
    fi
  fi
}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_gitleaks_status() {
  local input="$1"
  local expected_status="$2"
  local log_file="$3"
  local actual_status=0

  if gitleaks dir --no-banner --redact=100 --exit-code=2 "${input}" > "${log_file}" 2>&1; then
    actual_status=0
  else
    actual_status=$?
  fi
  [[ "${actual_status}" -eq "${expected_status}" ]] || fail "Gitleaks scan returned an unexpected status"
}

step_ref="${step_dir}/hypershift-destroy-nested-management-cluster-dump-management-cluster-ref.yaml"
[[ -s "${step_ref}" ]] || fail "dump step reference is missing"
step_name="$(yq -r '.ref.as' "${step_ref}")" || fail "dump step name could not be read"
command_name="$(yq -r '.ref.commands' "${step_ref}")" || fail "dump step command could not be read"
[[ "${command_name}" == "${step_name}-commands.sh" ]] || fail "dump step command name does not match its ref name"
command_file="${step_dir}/${command_name}"
[[ -s "${command_file}" ]] || fail "dump step command script is missing"
step_metadata="${step_dir}/${step_name}-ref.metadata.json"
[[ -s "${step_metadata}" ]] || fail "dump step metadata is missing"
metadata_path="${step_ref#${repo_root}/ci-operator/step-registry/}"
jq -e --arg path "${metadata_path}" '.path == $path' "${step_metadata}" > /dev/null || fail "dump step metadata path does not match its ref path"
chain_file="${repo_root}/ci-operator/step-registry/hypershift/destroy-nested-management-cluster/hypershift-destroy-nested-management-cluster-chain.yaml"
assert_contains "${chain_file}" "ref: ${step_name}"
bash -n "${command_file}" || fail "dump step command script has invalid shell syntax"
assert_gitleaks_status "${command_file}" 0 "${work_dir}/gitleaks-command-source.log"
assert_gitleaks_status "${BASH_SOURCE[0]}" 0 "${work_dir}/gitleaks-test-source.log"

fixture_dir="${work_dir}/fixture"
mkdir -p "${fixture_dir}/cluster-scoped-resources/core"
new_fixture_token() {
  od -An -N32 -tx1 /dev/urandom | tr -d '[:space:]'
}
has_high_entropy() {
  printf '%s\n' "$1" | awk '{
    for (i = 1; i <= length($0); i++) counts[substr($0, i, 1)]++
    for (character in counts) {
      probability = counts[character] / length($0)
      entropy -= probability * log(probability) / log(2)
    }
    exit !(entropy >= 3.5)
  }'
}
new_high_entropy_fixture_token() {
  local token attempt
  for ((attempt = 0; attempt < 10; attempt++)); do
    token="$(new_fixture_token)"
    if has_high_entropy "${token}"; then
      printf '%s' "${token}"
      return
    fi
  done
  fail "could not generate a high-entropy test fixture"
}
new_condition_identifier() {
  local raw token attempt
  for ((attempt = 0; attempt < 10; attempt++)); do
    raw="$(new_fixture_token | tr '0123456789abcdef' 'abcdefghijklmnop' | cut -c1-56)"
    token="$(printf '%s\n' "${raw}" | awk '{
      for (i = 1; i <= length($0); i++) {
        character = substr($0, i, 1)
        if ((i - 1) % 8 == 0) character = toupper(character)
        printf "%s", character
      }
    }')"
    if has_high_entropy "${token}"; then
      printf '%s' "${token}"
      return
    fi
  done
  fail "could not generate a high-entropy condition identifier fixture"
}
opaque_fixture_token="$(new_high_entropy_fixture_token)"
lower_path_fixture_seed="$(new_high_entropy_fixture_token)"
opaque_base64_fixture="$(new_fixture_token | base64 | tr -d '[:space:]')"
aws_access_key_fixture="AKIA$(new_fixture_token | tr '[:lower:]' '[:upper:]' | cut -c1-16)"
aws_session_key_fixture="ASIA$(new_fixture_token | tr '[:lower:]' '[:upper:]' | cut -c1-16)"
gitleaks_probe_fixture_token="$(new_high_entropy_fixture_token)"
basic_auth_fixture="$(printf 'fixture-user:%s' "$(new_fixture_token | cut -c1-12)" | base64 | tr -d '[:space:]')"
digest_auth_fixture="$(new_fixture_token | cut -c1-12)"
secret_reference_credential_fixture="$(new_fixture_token | cut -c1-12)"
[[ "${#opaque_fixture_token}" -eq 64 && "${#lower_path_fixture_seed}" -eq 64 && "${#opaque_base64_fixture}" -ge 32 ]] || fail "could not generate redaction fixtures"
lower_path_fixture_token=""
for ((offset = 0; offset < ${#lower_path_fixture_seed}; offset += 8)); do
  [[ -n "${lower_path_fixture_token}" ]] && lower_path_fixture_token+="-"
  lower_path_fixture_token+="${lower_path_fixture_seed:offset:8}"
done
unset lower_path_fixture_seed
commit="$(new_fixture_token | cut -c1-40)"
digest="$(new_fixture_token)"
unrelated_hash_fixture_token="$(new_high_entropy_fixture_token)"
condition_type_fixture="$(new_condition_identifier)"
condition_reason_seed="$(new_condition_identifier)"
condition_reason_fixture="${condition_reason_seed:0:32}_${condition_reason_seed:32}"
condition_outside_fixture="$(new_condition_identifier)"
condition_message_fixture="$(new_condition_identifier)"
condition_map_fixture="$(new_condition_identifier)"
condition_qualified_type_fixture="network.operator.openshift.io/${condition_type_fixture:0:32}-${condition_type_fixture:32}"
unset condition_reason_seed
[[ "${#digest}" -eq 64 ]] || fail "could not generate a SHA-256 image fixture"
short_fixture_token="${opaque_fixture_token:0:12}"
pem_private_type="PRIVATE$(printf '%s' ' KEY')"
pem_private_begin_marker="-----BEGIN ${pem_private_type}-----"
pem_private_end_marker="-----END ${pem_private_type}-----"

# Shapes observed in published dumps. Keep these separate so parser failures
# cannot hide which preservation contract broke. Sensitive values are generated
# at runtime, including short values that cannot rely on entropy redaction.
cat > "${fixture_dir}/cluster-scoped-resources/core/certificate-descriptions.yaml" <<EOF
apiVersion: v1
kind: Example
spec:
  literal: |
    Begin with -----BEGIN CERTIFICATE-----
    and finish with -----END CERTIFICATE----- before the trailing diagnostic.
  folded: >
    Begin with -----BEGIN CERTIFICATE-----
    and finish with -----END CERTIFICATE----- before the trailing diagnostic.
  plain: Begin with -----BEGIN CERTIFICATE-----
    and finish with -----END CERTIFICATE----- before the trailing diagnostic.
  quoted: "Begin with -----BEGIN CERTIFICATE-----
    and finish with -----END CERTIFICATE----- before the trailing diagnostic."
  repeated: |
    -----BEGIN CERTIFICATE-----
    description -----END CERTIFICATE----- between -----BEGIN CERTIFICATE-----
    description -----END CERTIFICATE----- before the trailing diagnostic.
  material: |
    ${pem_private_begin_marker}
    ${short_fixture_token}
    ${pem_private_end_marker}
  following: retained
EOF

cat > "${fixture_dir}/cluster-scoped-resources/core/field-ownership.yaml" <<EOF
apiVersion: v1
kind: Example
metadata:
  managedFields:
  - manager: fixture
    fieldsType: FieldsV1
    fieldsV1:
      f:spec:
# Ownership note: comments do not change the surrounding YAML ancestry.
        f:token:
          .: {}
          f:server: {}
        'f:password': {}
        "f:client-secret":
          f:name: {}
        f:diagnosticToken: ${short_fixture_token}
        f:inlineToken: {password: ${short_fixture_token}, keep: retained}
  - manager: another
    fieldsType: FieldsV1
    fieldsV1:
      f:spec:
        f:api-key: {}
spec:
  token: ${short_fixture_token}
  f:token: ${short_fixture_token}
  following: retained
EOF

cat > "${fixture_dir}/cluster-scoped-resources/core/resource-kinds.yaml" <<EOF
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: examples.example.invalid
spec:
  names:
    kind: DiagnosticResourceDefinition
  items:
  - - "kind": "CustomResourceDefinition" # CustomResourceDefinition ${opaque_fixture_token}
  notkind: CustomResourceDefinition
  multilineKind:
    kind:
      CustomResourceDefinition
    notkind: ${opaque_fixture_token}
    unrelated: ${opaque_fixture_token}
  message: "kind: CustomResourceDefinition"
  doubleQuoted: "Diagnostic detail:
    kind: Z${opaque_fixture_token}
    password: ${short_fixture_token}
    done"
  singleQuoted: 'Diagnostic detail:
    kind: Z${opaque_fixture_token}
    token: ${short_fixture_token}
    done'
  unrelated: ${opaque_fixture_token}
EOF
printf '{"kind":"CustomResourceDefinition","notkind":"CustomResourceDefinition","message":"kind: CustomResourceDefinition","unrelated":"%s"}\n' \
  "${opaque_fixture_token}" > "${fixture_dir}/cluster-scoped-resources/core/resource-kinds.json"
cp "${fixture_dir}/cluster-scoped-resources/core/resource-kinds.json" "${fixture_dir}/cluster-scoped-resources/core/resource-kinds.jsonl"
cat > "${fixture_dir}/cluster-scoped-resources/core/resource-kinds-pretty.json" <<EOF
{
  "kind":
    "CustomResourceDefinition",
  "notkind": "${opaque_fixture_token}",
  "message": "kind: ${opaque_fixture_token}",
  "unrelated": "${opaque_fixture_token}"
}
EOF
jq -n --arg opaque "${opaque_fixture_token}" '{kind: "CustomResourceDefinition", "prefix\"kind": ("Z" + $opaque), diagnostics: [{kind: ("diagnostic \"Z" + $opaque)}, {kind: "diagnostic \"CustomResourceDefinition"}]}' > "${fixture_dir}/cluster-scoped-resources/core/kind-boundaries.json"
jq -c '.' "${fixture_dir}/cluster-scoped-resources/core/kind-boundaries.json" > "${fixture_dir}/cluster-scoped-resources/core/kind-boundaries.jsonl"
cat > "${fixture_dir}/cluster-scoped-resources/core/plain-quoted-continuations.yaml" <<EOF
double:
  message: normal diagnostic
    "quoted fragment
  kind: CustomResourceDefinition
  token: |
    ${short_fixture_token}
  following: retained
single:
  message: normal diagnostic
    'quoted fragment
  kind: CustomResourceDefinition
  token: |
    ${short_fixture_token}
  following: retained
listLike:
  message: normal diagnostic
    - "quoted fragment
  kind: CustomResourceDefinition
  token: |
    ${short_fixture_token}
  following: retained
deferred:
  message:
    normal diagnostic
    - "quoted fragment
  kind: CustomResourceDefinition
  token: |
    ${short_fixture_token}
  following: retained
EOF
cat > "${fixture_dir}/cluster-scoped-resources/core/quoted-scalar-starts.yaml" <<EOF
deferred:
  "diagnostic
  kind: Z${opaque_fixture_token}
  done"
anchored: &detail "diagnostic
  kind: Z${opaque_fixture_token}
  done"
items:
- "diagnostic
  kind: Z${opaque_fixture_token}
  done"
kind: CustomResourceDefinition
password: ${short_fixture_token}
following: retained
EOF

cat > "${fixture_dir}/cluster-scoped-resources/core/nodes.yaml" <<EOF
apiVersion: v1
kind: Node
metadata:
  name: hypershift-operator-controller-manager-abcdef
  uid: 123e4567-e89b-12d3-a456-426614174000
  commit: ${commit}
  notcommit: ${unrelated_hash_fixture_token}
  git_commit: "${commit} diagnostic=${opaque_fixture_token}"
  unlabelledOpaqueBase64: "${opaque_base64_fixture}"
  digest: sha256:${digest}
  quotedDigest: "sha256:${digest}"
  digestWithOtherDiagnostic: "sha256:${digest} diagnostic=${opaque_fixture_token}"
  hashes:
    "commit": ${commit}
    "sha256": ${digest}
    "digest": sha256:${digest}
    notcommit: ${unrelated_hash_fixture_token}
  quotedHashFlow: {"commit": ${commit}, "sha256": ${digest}, "digest": sha256:${digest}, "notcommit": ${unrelated_hash_fixture_token}}
  quotedHashValues:
    "commit": "${commit}"
    "sha256": "${digest}"
    "digest": "sha256:${digest}"
    notcommit: "${unrelated_hash_fixture_token}"
  sourceFile: kubernetes/kubernetes/pkg/controller/deployment/sync.go
  image: quay.io/openshift/origin-hypershift-operator
  diagnosticFlow: {password: ${short_fixture_token}, keep: retained}
  shellDiagnostic: |
    opaque="${opaque_fixture_token}"
    lower_path_secret="${lower_path_fixture_token}"
    echo keep-after-script-secrets
  anchoredPassword: &diagnosticSecret ${short_fixture_token}
  anchorAlias: *diagnosticSecret
  ordinaryPath: https://api.example.invalid/api/v1/namespaces/default/status
  opaquePath: https://api.example.invalid/api/v1/${opaque_fixture_token}/status
  opaqueLowerPath: https://api.example.invalid/api/v1/${lower_path_fixture_token}/status
  userInfoURL: https://fixture:${short_fixture_token}@example.invalid/api/v1/status
  databaseURL: postgres://fixture:${short_fixture_token}@db.example.invalid/hypershift
  message: "prefix password=${short_fixture_token} and keep-diagnostic"
  bearerDiagnostic: "bEaReR ${short_fixture_token}"
  "password": |
    ${short_fixture_token}
  'client-secret': '${short_fixture_token}'
  multilinePassword: ${short_fixture_token}
    continuation-secret"
  api-key:
    folded-plain-secret
    continuation-plain-secret
  afterMultiline: retained-diagnostic
  pemMessage: "before ${pem_private_begin_marker}
    multiline-private-key-material
    ${pem_private_end_marker} after-field"
  pemPassword: ${short_fixture_token} ${pem_private_begin_marker}
    quoted-password-pem-secret
    ${pem_private_end_marker} after-password-pem"
  pemMessages: "before ${pem_private_begin_marker}
    repeated-yaml-pem-one
    ${pem_private_end_marker} between -----BEGIN CERTIFICATE-----
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
        args: ["--password", "${short_fixture_token}", "--namespace", "default"]
      - name: script-diagnostic-container
        image: "quay.io/demo/controller@sha256:${digest}"
        not-image: "quay.io/demo/controller@sha256:${opaque_fixture_token}"
        command:
        - /bin/sh
        - -c
        - |
          cat <<'SCRIPT'
          env: [
          args: [
          password=${short_fixture_token}
          SCRIPT
        env:
        - name: API_TOKEN
          value: ${short_fixture_token}
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
    - {value: "${short_fixture_token}", name: "DB_PASSWORD"}
    - {name: DB_PASSWORD,
       value: wrapped-flow-env-secret}
    - value: |
        multiline-env-secret
        continuation-env-secret
      name: BLOCK_TOKEN
    - name: API_TOKEN
      value: ${short_fixture_token} -----BEGIN CERTIFICATE-----
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

cat > "${fixture_dir}/cluster-scoped-resources/core/events.yaml" <<EOF
apiVersion: events.k8s.io/v1
kind: Event
message: |
  cannot load script fragment:
  env: [
  password: ${short_fixture_token}
  unexpected end of input
reason: Failed
EOF

cat > "${fixture_dir}/cluster-scoped-resources/core/root-flow.yaml" <<EOF
{password: ${short_fixture_token}, keep: retained-root-flow-field}
EOF

cat > "${fixture_dir}/cluster-scoped-resources/core/quoted-hashes.yaml" <<EOF
"commit": "${commit}"
"sha256": "${digest}"
"digest": "sha256:${digest}"
notcommit: "${unrelated_hash_fixture_token}"
EOF

cat > "${fixture_dir}/cluster-scoped-resources/core/condition-identifiers.yaml" <<EOF
apiVersion: example.invalid/v1
kind: Example
status:
  conditions:
  - type: ${condition_type_fixture}
    reason: ${condition_reason_fixture}
    message: ${condition_message_fixture}
    token: ${condition_reason_fixture}
  - type: ${condition_qualified_type_fixture}
    reason: ${condition_reason_fixture}
  reason: ${condition_outside_fixture}
diagnosticMap:
  conditions:
    type: ${condition_map_fixture}
    reason: ${condition_map_fixture}
spec:
  conditions:
  - type: ${opaque_fixture_token}
    reason: ${opaque_fixture_token}
EOF
cat > "${fixture_dir}/cluster-scoped-resources/core/condition-identifiers-pretty.json" <<EOF
{
  "status": {
    "conditions": [
      {
        "type":
          "${condition_type_fixture}",
        "reason":
          "${condition_reason_fixture}",
        "message": "${condition_message_fixture}",
        "token": "${condition_reason_fixture}"
      },
      {
        "type": "${condition_qualified_type_fixture}",
        "reason": "${condition_reason_fixture}"
      }
    ],
    "reason": "${condition_outside_fixture}"
  },
  "diagnosticMap": {
    "conditions": {
      "type": "${condition_map_fixture}",
      "reason": "${condition_map_fixture}"
    }
  },
  "spec": {
    "conditions": [
      {"type": "${opaque_fixture_token}", "reason": "${opaque_fixture_token}"}
    ]
  }
}
EOF
printf '{"status":{"conditions":[{"type":"%s","reason":"%s","message":"%s","token":"%s"},{"type":"%s","reason":"%s"}],"reason":"%s"},"diagnosticMap":{"conditions":{"type":"%s","reason":"%s"}},"spec":{"conditions":[{"type":"%s","reason":"%s"}]}}\n' \
  "${condition_type_fixture}" "${condition_reason_fixture}" "${condition_message_fixture}" \
  "${condition_reason_fixture}" "${condition_qualified_type_fixture}" "${condition_reason_fixture}" \
  "${condition_outside_fixture}" "${condition_map_fixture}" "${condition_map_fixture}" \
  "${opaque_fixture_token}" "${opaque_fixture_token}" > \
  "${fixture_dir}/cluster-scoped-resources/core/condition-identifiers.json"
cp "${fixture_dir}/cluster-scoped-resources/core/condition-identifiers.json" \
  "${fixture_dir}/cluster-scoped-resources/core/condition-identifiers.jsonl"

cat > "${fixture_dir}/cluster-scoped-resources/core/status.json" <<EOF
{
  "message":"password=${short_fixture_token} and keep-json-diagnostic",
  "url":"https://fixture:${short_fixture_token}@example.invalid/api",
  "commit":"${commit}",
  "hashDiagnostic":{"commit":"${commit} diagnostic=${opaque_fixture_token}"},
  "escapedEnv":{"env":[{"name":"API_TO\u004bEN","value":"${opaque_fixture_token}"}]},
  "escapedArgv":{"args":["--to\u006ben","${opaque_fixture_token}","--namespace","default"]},
  "escapedEnvKey":{"e\u006ev":[{"name":"API_TOKEN","value":"${opaque_fixture_token}"}]},
  "escapedArgvKey":{"a\u0072gs":["--password","${opaque_fixture_token}","--namespace","default"]},
  "notcommit":"${unrelated_hash_fixture_token}",
  "digest":"sha256:${digest}",
  "password":"${short_fixture_token}",
  "serviceAccountToken":{"audience":"api","expirationSeconds":3607,"path":"token"},
  "automountServiceAccountToken":false,
  "client\u005fsecret":"${short_fixture_token}",
  "volumes":[
    {"projected":{"sources":[
      {"serviceAccountToken":{"audience":"api","expirationSeconds":3607,"path":"token"}},
      {"secret":{"name":"retained-projected-secret","items":[{"key":"username","path":"username"}]}}
    ]}},
    {"secret":{"secretName":"retained-volume-secret","items":[{"key":"password","path":"password"}]}}
  ],
  "token":null,
  "items":[{"spec":{"containers":[
    {"name":"first","image":"quay.io/demo/controller@sha256:${digest}","env":[{"name":"API_TOKEN","value":"${short_fixture_token}"}]},
    {"name":"second","env":[{"value":"${short_fixture_token}","name":"DB_PASSWORD"}]}
  ]}}],
  "compactContainers":[{"env":[{"name":"API_TOKEN","value":"${short_fixture_token}"}]},{"env":[{"value":"${short_fixture_token}","name":"DB_PASSWORD"}]}],
  "args":["--password","${short_fixture_token}","--namespace","default"],
  "env":[{"value":"${short_fixture_token}","name":"API_TOKEN"},{"name":"TOKEN_FROM","valueFrom":{"secretKeyRef":{"name":"retained-json-reference"}}}],
  "pem":"pre ${pem_private_begin_marker}inline-key-one${pem_private_end_marker} middle -----BEGIN CERTIFICATE-----inline-key-two-----END CERTIFICATE----- post",
  "pemBefore":"${pem_private_begin_marker}sibling-key-one${pem_private_end_marker}","keepBetweenPem":"retained-between-pem","pemAfter":"-----BEGIN CERTIFICATE-----sibling-key-two-----END CERTIFICATE-----",
  "keep":"retained-json-field"
}
EOF

printf '{"commit":"%s","unrelated":"%s","hashDiagnostic":"%s diagnostic=%s"}\n' \
  "${commit}" "${opaque_fixture_token}" "${commit}" "${opaque_fixture_token}" > \
  "${fixture_dir}/cluster-scoped-resources/core/compact-hash.json"

printf '{"kind":"Pod","apiVersion":"v1","metadata":{"name":"image-context"},"spec":{"containers":[{"name":"app","image":"quay.io/demo/controller@sha256:%s"}]},"unrelated":"%s","diagnostic":{"commit":"note=%s"}}\n' \
  "${digest}" "${opaque_fixture_token}" "${opaque_fixture_token}" > \
  "${fixture_dir}/cluster-scoped-resources/core/compact-image-context.json"
printf '{"kind":"Pod","spec":{"containers":[{"name":"app","image":"quay.io/openshift/origin-hypershift-operator"}]},"unrelated":"%s"}\n' \
  "${opaque_fixture_token}" > "${fixture_dir}/cluster-scoped-resources/core/ordinary-image-context.json"
printf '{"kind":"Pod","spec":{"containers":[{"name":"app","image":"quay.io/openshift/origin-hypershift-operator"}]},"unrelated":"%s"}\n' \
  "${opaque_fixture_token}" > "${fixture_dir}/cluster-scoped-resources/core/ordinary-image-context.jsonl"
cat > "${fixture_dir}/cluster-scoped-resources/core/nested-list-images.yaml" <<EOF
items:
- - image: quay.io/openshift/origin-hypershift-operator
  - diagnostic: ${opaque_fixture_token}
- - image: quay.io/demo/controller@sha256:${digest}
EOF

cat > "${fixture_dir}/cluster-scoped-resources/core/timestamp" <<EOF
password=${short_fixture_token}
EOF
printf 'binary\000%s' "$(new_fixture_token)" > "${fixture_dir}/cluster-scoped-resources/core/binary-data"

cat > "${fixture_dir}/cluster-scoped-resources/core/event-filter.html" <<EOF
<html><body><a href="https://fixture:${short_fixture_token}@example.invalid/events/${opaque_fixture_token}">Authorization: bEaReR ${short_fixture_token}</a><p>Authorization: Basic ${basic_auth_fixture} request-id=retained-html</p><p>Authorization: Digest ${digest_auth_fixture}</p><p>${opaque_fixture_token}</p></body></html>
EOF

cat > "${fixture_dir}/cluster-scoped-resources/core/events.log" <<EOF
Authorization: ${short_fixture_token}
message Authorization: Basic ${basic_auth_fixture}
AWS key ${aws_access_key_fixture} and ${aws_session_key_fixture}
Run --password ${short_fixture_token} --client-secret '${short_fixture_token}' keep-after-flag
Run argv --token ${short_fixture_token} --namespace default
message image: ${opaque_fixture_token}
diagnostic URL https://api.example.invalid/normal/path/${opaque_fixture_token}/events
{"message":"commit: ${opaque_fixture_token}","commit":"${commit}","unrelated":"${opaque_fixture_token}"}
{"message":"diagnostic commit: ${opaque_fixture_token}","commit":"${commit}","unrelated":"${opaque_fixture_token}"}
{"kind":"Pod","apiVersion":"v1","metadata":{"name":"image-context"},"spec":{"containers":[{"name":"app","image":"quay.io/demo/controller@sha256:${digest}"}]},"unrelated":"${opaque_fixture_token}","diagnostic":{"commit":"note=${opaque_fixture_token}"}}
EOF

cat > "${fixture_dir}/authorization-headers.yaml" <<EOF
message: "Authorization: Basic ${basic_auth_fixture} request-id=retained"
reason: "Authorization: Digest ${digest_auth_fixture}"
httpHeaders:
  - name: Authorization
    value: Basic ${basic_auth_fixture}
  - value: Digest ${digest_auth_fixture}
    name: authorization
  - name: X-Diagnostic
    value: retained
EOF

cat > "${fixture_dir}/authorization-headers-flow.yaml" <<EOF
httpHeaders: [
  {name: Authorization, value: Basic ${basic_auth_fixture}},
  {name: authorization, value: Digest ${digest_auth_fixture}},
  {name: X-Diagnostic, value: retained}
]
EOF

cat > "${fixture_dir}/authorization-headers.json" <<EOF
{
  "message": "Authorization: Basic ${basic_auth_fixture} request-id=retained-json",
  "reason": "Authorization: Digest ${digest_auth_fixture}",
  "requestId": "retained",
  "httpHeaders": [
    {"name": "Authorization", "value": "Basic ${basic_auth_fixture}"},
    {"name": "authorization", "value": "Digest ${digest_auth_fixture}"},
    {"name": "X-Diagnostic", "value": "retained"}
  ]
}
EOF

cat > "${fixture_dir}/secret-references.yaml" <<EOF
apiVersion: hypershift.openshift.io/v1beta1
kind: HostedCluster
metadata:
  name: secret-reference-preservation
spec:
  pullSecret:
    name: diagnostic-pull-reference
    password: ${secret_reference_credential_fixture}
  configuration:
    oauth:
      identityProviders:
        - name: diagnostic-identity-provider
          type: OpenID
          openID:
            clientSecret: {name: diagnostic-oauth-reference, password: "${secret_reference_credential_fixture}"}
status:
  kubeadminPassword:
    name: diagnostic-admin-reference
    token: ${secret_reference_credential_fixture}
referenceVariants:
  flow:
    pullSecret: {name: diagnostic-flow-reference, password: "${secret_reference_credential_fixture}"}
  sequence:
    clientSecret: [{name: diagnostic-sequence-reference}]
  scalars:
    pullSecret: "diagnostic-pull-scalar"
    kubeadminPassword: diagnostic-password-scalar
    clientSecret: "diagnostic-client-scalar"
unrelatedDiagnostic:
  kubeconfig:
    clusters: []
EOF

cat > "${fixture_dir}/secret-references.json" <<EOF
{
  "apiVersion": "hypershift.openshift.io/v1beta1",
  "kind": "HostedCluster",
  "spec": {
    "pullSecret": {"name": "diagnostic-pull-reference", "password": "${secret_reference_credential_fixture}"},
    "configuration": {"oauth": {"identityProviders": [{"name": "diagnostic-identity-provider", "type": "OpenID", "openID": {"clientSecret": {"name": "diagnostic-oauth-reference", "password": "${secret_reference_credential_fixture}"}}}]}}
  },
  "status": {"kubeadminPassword": {"name": "diagnostic-admin-reference", "token": "${secret_reference_credential_fixture}"}},
  "referenceVariants": {
    "sequence": {"clientSecret": [{"name": "diagnostic-sequence-reference"}]},
    "scalars": {"pullSecret": "diagnostic-pull-scalar", "kubeadminPassword": "diagnostic-password-scalar", "clientSecret": "diagnostic-client-scalar"}
  },
  "unrelatedDiagnostic": {"kubeconfig": {"clusters": []}}
}
EOF

# Keep high-entropy fixture values generated at runtime so no credential-like
# samples are committed or echoed by this test.
flow_fixture_token="$(new_fixture_token)"
nested_json_fixture_token="$(new_fixture_token)"
batch_fixture_token="$(new_fixture_token)"
container_fixture_id="containerd://$(new_fixture_token)"
machine_fixture_id="$(new_fixture_token)"
image_fixture_id="docker-pullable://quay.io/demo/controller@sha256:${digest}"
slack_fixture_source="$(new_fixture_token)"
slack_webhook_fixture="https://hooks.slack.com/services/T${slack_fixture_source:0:8}/B${slack_fixture_source:8:12}/${slack_fixture_source:20:24}"

cat > "${fixture_dir}/cluster-scoped-resources/core/multiline-credential-flow.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: multiline-credential-flow
spec:
  password: [
    "${flow_fixture_token}",
    {nested: retained}
  ]
  keep: retained-flow-sibling
EOF

cat > "${fixture_dir}/cluster-scoped-resources/core/nested-json.log" <<EOF
diagnostic event payload: {
  "kind": "Pod",
  "metadata": {"name": "embedded-json-diagnostic"},
  "spec": {"containers": [{"name": "controller", "image": "quay.io/demo/controller@sha256:${digest}", "env": [{"name": "API_TOKEN", "value": "${nested_json_fixture_token}"}]}]}
}
EOF
printf 'webhook diagnostic: %s\n' "${slack_webhook_fixture}" >> "${fixture_dir}/cluster-scoped-resources/core/events.log"

cat > "${fixture_dir}/cluster-scoped-resources/core/diagnostic-identifiers.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: diagnostic-identifiers
  generateName: diagnostic-workload-
spec:
  serviceAccountName: diagnostic-account
  priorityClassName: system-cluster-critical
  containers:
  - name: diagnostic
    image: quay.io/demo/controller
    workingDir: /var/lib/hypershift/diagnostics
status:
  containerStatuses:
  - name: diagnostic
    containerID: ${container_fixture_id}
    imageID: ${image_fixture_id}
  diagnosticOpaque: ${opaque_fixture_token}
EOF
cat > "${fixture_dir}/cluster-scoped-resources/core/diagnostic-identifiers.json" <<EOF
{"containerID":"${container_fixture_id}","imageID":"${image_fixture_id}","machineID":"${machine_fixture_id}","serviceAccountName":"diagnostic-account","priorityClassName":"system-cluster-critical","generateName":"diagnostic-workload-","workingDir":"/var/lib/hypershift/diagnostics","unrelated":"${opaque_fixture_token}"}
EOF

# More than one batch forces AWK to reset parser state across input files.
for ((batch_index = 1; batch_index <= 70; batch_index++)); do
  printf -v batch_name '%03d' "${batch_index}"
  cat > "${fixture_dir}/cluster-scoped-resources/core/batch-state-${batch_name}.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: batch-state-${batch_name}
spec:
  password: ${batch_fixture_token}
EOF
done

for provider_name in AWS Azure; do
  mkdir -p "${fixture_dir}.providers/${provider_name}/cluster-scoped-resources/core"
  printf 'apiVersion: v1\nkind: Pod\nmetadata:\n  name: provider-marker\n  labels:\n    provider: %s\n' \
    "${provider_name}" > "${fixture_dir}.providers/${provider_name}/cluster-scoped-resources/core/provider-${provider_name}.yaml"
done

gitleaks_probe_file="${fixture_dir}/cluster-scoped-resources/core/gitleaks-probe.yaml"
cat > "${gitleaks_probe_file}" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: gitleaks-probe
  annotations:
    password: ${gitleaks_probe_fixture_token}
EOF
assert_gitleaks_status "${gitleaks_probe_file}" 2 "${work_dir}/gitleaks-raw.log"

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
provider_fixture_dir="${FIXTURE_DIR}.providers/${CLOUD_PROVIDER:-}"
if [[ -d "${provider_fixture_dir}" ]]; then
  cp -R "${provider_fixture_dir}/." "${output_dir}/"
fi
if [[ -n "${FAKE_DUMP_EXIT_STATUS:-}" ]]; then
  exit "${FAKE_DUMP_EXIT_STATUS}"
fi
HYPERSHIFT
  chmod +x "${run_dir}/bin/hypershift"
}

validate_structured_files() {
  local root="$1"
  local provider="$2"
  local file_list="${work_dir}/${provider}-structured-files.list"
  local file json_line
  local authorization_yaml="${root}/authorization-headers.yaml"
  local authorization_flow_yaml="${root}/authorization-headers-flow.yaml"
  local authorization_json="${root}/authorization-headers.json"
  local secret_references_yaml="${root}/secret-references.yaml"
  local secret_references_json="${root}/secret-references.json"

  if ! find "${root}" -type f \( -name '*.yaml' -o -name '*.yml' \) -print0 > "${file_list}"; then
    fail "could not enumerate YAML fixture files"
  fi
  while IFS= read -r -d '' file; do
    yq -e '.' "${file}" > /dev/null 2>&1 || fail "sanitized YAML fixture is invalid"
  done < "${file_list}"

  if ! find "${root}" -type f -name '*.json' -print0 > "${file_list}"; then
    fail "could not enumerate JSON fixture files"
  fi
  while IFS= read -r -d '' file; do
    jq -e '.' "${file}" > /dev/null 2>&1 || fail "sanitized JSON fixture is invalid"
  done < "${file_list}"

  if ! find "${root}" -type f -name '*.jsonl' -print0 > "${file_list}"; then
    fail "could not enumerate JSONL fixture files"
  fi
  while IFS= read -r -d '' file; do
    while IFS= read -r json_line || [[ -n "${json_line}" ]]; do
      [[ -z "${json_line}" ]] && continue
      printf '%s\n' "${json_line}" | jq -e '.' > /dev/null 2>&1 || fail "sanitized JSONL fixture is invalid"
    done < "${file}"
  done < "${file_list}"

  [[ -f "${authorization_yaml}" && -f "${authorization_flow_yaml}" && -f "${authorization_json}" ]] || fail "${provider} archive is missing authorization-header fixtures"
  [[ -f "${secret_references_yaml}" && -f "${secret_references_json}" ]] || fail "${provider} archive is missing Secret-reference fixtures"
  assert_not_contains "${root}" "${basic_auth_fixture}"
  assert_not_contains "${root}" "${digest_auth_fixture}"
  assert_not_contains "${root}" "${secret_reference_credential_fixture}"
  yq -e '.message == "Authorization: REDACTED request-id=retained" and .reason == "Authorization: REDACTED" and .httpHeaders[0].name == "Authorization" and .httpHeaders[0].value == "REDACTED" and .httpHeaders[1].value == "REDACTED" and .httpHeaders[2].value == "retained"' "${authorization_yaml}" > /dev/null || fail "${provider} YAML authorization values leaked or lost sibling diagnostics"
  yq -e '.httpHeaders[0].value == "REDACTED" and .httpHeaders[1].value == "REDACTED" and .httpHeaders[2].value == "retained"' "${authorization_flow_yaml}" > /dev/null || fail "${provider} flow-style YAML authorization values leaked or lost sibling diagnostics"
  jq -e '.message == "Authorization: REDACTED request-id=retained-json" and .reason == "Authorization: REDACTED" and .requestId == "retained" and .httpHeaders[0].value == "REDACTED" and .httpHeaders[1].value == "REDACTED" and .httpHeaders[2].value == "retained"' "${authorization_json}" > /dev/null || fail "${provider} JSON authorization values leaked or lost sibling diagnostics"
  yq -e '.spec.pullSecret.name == "diagnostic-pull-reference" and .spec.pullSecret.password == "REDACTED" and .spec.configuration.oauth.identityProviders[0].openID.clientSecret.name == "diagnostic-oauth-reference" and .spec.configuration.oauth.identityProviders[0].openID.clientSecret.password == "REDACTED" and .status.kubeadminPassword.name == "diagnostic-admin-reference" and .status.kubeadminPassword.token == "REDACTED" and .referenceVariants.flow.pullSecret.name == "diagnostic-flow-reference" and .referenceVariants.flow.pullSecret.password == "REDACTED" and .referenceVariants.sequence.clientSecret[0].name == "diagnostic-sequence-reference" and .referenceVariants.scalars.pullSecret == "REDACTED" and .referenceVariants.scalars.kubeadminPassword == "REDACTED" and .referenceVariants.scalars.clientSecret == "REDACTED" and .unrelatedDiagnostic.kubeconfig == "REDACTED"' "${secret_references_yaml}" > /dev/null || fail "${provider} YAML Secret references were lost or credential values preserved"
  jq -e '.spec.pullSecret.name == "diagnostic-pull-reference" and .spec.pullSecret.password == "REDACTED" and .spec.configuration.oauth.identityProviders[0].openID.clientSecret.name == "diagnostic-oauth-reference" and .spec.configuration.oauth.identityProviders[0].openID.clientSecret.password == "REDACTED" and .status.kubeadminPassword.name == "diagnostic-admin-reference" and .status.kubeadminPassword.token == "REDACTED" and .referenceVariants.sequence.clientSecret[0].name == "diagnostic-sequence-reference" and .referenceVariants.scalars.pullSecret == "REDACTED" and .referenceVariants.scalars.kubeadminPassword == "REDACTED" and .referenceVariants.scalars.clientSecret == "REDACTED" and .unrelatedDiagnostic.kubeconfig == "REDACTED"' "${secret_references_json}" > /dev/null || fail "${provider} JSON Secret references were lost or credential values preserved"
}

run_dir="${work_dir}/normal-run"
make_fake_runner "${run_dir}"
artifact_dir="${run_dir}/artifacts"
if ! (
  cd "${run_dir}"
  FIXTURE_DIR="${fixture_dir}" ARTIFACT_DIR="${artifact_dir}" PROW_JOB_ID=redaction-test \
    HYPERSHIFT_NAMESPACE=clusters CLOUD_PROVIDER=AWS bash "${command_file}"
) 2> "${run_dir}/stderr.log"; then
  cat "${run_dir}/stderr.log" >&2
  fail "AWS dump step failed"
fi
# GNU awk can exit zero while warning about nonportable regex escapes once
# per file. Check its diagnostics while allowing BSD tar's verbose stderr.
if grep -Fq 'awk:' "${run_dir}/stderr.log"; then
  fail "AWS sanitizer emitted awk diagnostics"
fi

archive="${artifact_dir}/artifacts.tar.gz"
[[ -s "${archive}" ]] || fail "sanitized archive was not published"
tar -tzf "${archive}" > "${work_dir}/archive-list.txt" || fail "archive listing failed"
assert_contains "${work_dir}/archive-list.txt" "output/cluster-scoped-resources/core/nodes.yaml"
assert_not_contains "${work_dir}/archive-list.txt" "${work_dir}"

extract_dir="${work_dir}/extracted"
mkdir -p "${extract_dir}"
tar -xzf "${archive}" -C "${extract_dir}" || fail "archive extraction failed"
validate_structured_files "${extract_dir}/output" AWS
assert_not_contains "${extract_dir}" "${short_fixture_token}"
assert_not_contains "${extract_dir}" "${aws_access_key_fixture}"
assert_not_contains "${extract_dir}" "${aws_session_key_fixture}"
assert_not_contains "${extract_dir}" "${basic_auth_fixture}"
assert_not_contains "${extract_dir}" "${gitleaks_probe_fixture_token}"
assert_gitleaks_status "${extract_dir}" 0 "${work_dir}/gitleaks-aws-clean.log"
[[ -f "${extract_dir}/output/cluster-scoped-resources/core/provider-AWS.yaml" && ! -e "${extract_dir}/output/cluster-scoped-resources/core/provider-Azure.yaml" ]] || fail "AWS provider-specific fixture selection failed"
yq -e '.metadata.labels.provider == "AWS"' "${extract_dir}/output/cluster-scoped-resources/core/provider-AWS.yaml" > /dev/null || fail "AWS provider fixture was not retained"
yaml_file="${extract_dir}/output/cluster-scoped-resources/core/nodes.yaml"
root_flow_file="${extract_dir}/output/cluster-scoped-resources/core/root-flow.yaml"
quoted_hash_file="${extract_dir}/output/cluster-scoped-resources/core/quoted-hashes.yaml"
json_file="${extract_dir}/output/cluster-scoped-resources/core/status.json"
compact_hash_file="${extract_dir}/output/cluster-scoped-resources/core/compact-hash.json"
compact_image_context_file="${extract_dir}/output/cluster-scoped-resources/core/compact-image-context.json"
ordinary_image_json_file="${extract_dir}/output/cluster-scoped-resources/core/ordinary-image-context.json"
ordinary_image_jsonl_file="${extract_dir}/output/cluster-scoped-resources/core/ordinary-image-context.jsonl"
nested_list_image_file="${extract_dir}/output/cluster-scoped-resources/core/nested-list-images.yaml"
html_file="${extract_dir}/output/cluster-scoped-resources/core/event-filter.html"
log_file="${extract_dir}/output/cluster-scoped-resources/core/events.log"
events_file="${extract_dir}/output/cluster-scoped-resources/core/events.yaml"
timestamp_file="${extract_dir}/output/cluster-scoped-resources/core/timestamp"
multiline_flow_file="${extract_dir}/output/cluster-scoped-resources/core/multiline-credential-flow.yaml"
nested_json_log_file="${extract_dir}/output/cluster-scoped-resources/core/nested-json.log"
diagnostic_identifiers_yaml="${extract_dir}/output/cluster-scoped-resources/core/diagnostic-identifiers.yaml"
diagnostic_identifiers_json="${extract_dir}/output/cluster-scoped-resources/core/diagnostic-identifiers.json"

yq '.' "${yaml_file}" > /dev/null || fail "sanitized YAML is invalid"
yq '.' "${events_file}" > /dev/null || fail "sanitized Event YAML is invalid"
yq '.' "${root_flow_file}" > /dev/null || fail "sanitized root flow YAML is invalid"
yq '.' "${quoted_hash_file}" > /dev/null || fail "sanitized quoted-hash YAML is invalid"
jq '.' "${json_file}" > /dev/null || fail "sanitized JSON is invalid"
yq '.' "${multiline_flow_file}" > /dev/null || fail "multiline credential-flow YAML is invalid"
yq -e '.spec.password == "REDACTED" and .spec.keep == "retained-flow-sibling"' "${multiline_flow_file}" > /dev/null || fail "multiline credential flow damaged a sibling or retained its value"
assert_not_contains "${multiline_flow_file}" "${flow_fixture_token}"
sed '1s/^[^{]*//' "${nested_json_log_file}" > "${work_dir}/nested-json-extracted.json"
if ! jq -e --arg digest "${digest}" '.kind == "Pod" and .metadata.name == "embedded-json-diagnostic" and .spec.containers[0].env[0].value == "REDACTED" and .spec.containers[0].image == ("quay.io/demo/controller@sha256:" + $digest)' "${work_dir}/nested-json-extracted.json" > /dev/null 2>&1; then
  jq -r --arg digest "${digest}" '[["kind", .kind == "Pod"], ["metadata", .metadata.name == "embedded-json-diagnostic"], ["env-value-redacted", .spec.containers[0].env[0].value == "REDACTED"], ["image-digest-preserved", .spec.containers[0].image == ("quay.io/demo/controller@sha256:" + $digest)]][] | select(.[1] != true) | "nested-json-failed=" + .[0]' "${work_dir}/nested-json-extracted.json" >&2
  fail "nested JSON log was corrupted or its credential escaped redaction"
fi
assert_not_contains "${nested_json_log_file}" "${nested_json_fixture_token}"
if ! yq -o=json '.' "${diagnostic_identifiers_yaml}" | jq -e --arg container "${container_fixture_id}" --arg image "${image_fixture_id}" '.metadata.generateName == "diagnostic-workload-" and .spec.serviceAccountName == "diagnostic-account" and .spec.priorityClassName == "system-cluster-critical" and .spec.containers[0].workingDir == "/var/lib/hypershift/diagnostics" and .status.containerStatuses[0].containerID == $container and .status.containerStatuses[0].imageID == $image and .status.diagnosticOpaque == "REDACTED_HIGH_ENTROPY"' > /dev/null 2>&1; then
  yq -o=json '.' "${diagnostic_identifiers_yaml}" | jq -r --arg container "${container_fixture_id}" --arg image "${image_fixture_id}" '[["generateName", .metadata.generateName == "diagnostic-workload-"], ["serviceAccountName", .spec.serviceAccountName == "diagnostic-account"], ["priorityClassName", .spec.priorityClassName == "system-cluster-critical"], ["workingDir", .spec.containers[0].workingDir == "/var/lib/hypershift/diagnostics"], ["containerID", .status.containerStatuses[0].containerID == $container], ["imageID", .status.containerStatuses[0].imageID == $image], ["unrelated", .status.diagnosticOpaque == "REDACTED_HIGH_ENTROPY"]][] | select(.[1] != true) | "yaml-identifier-failed=" + .[0]' >&2
  fail "YAML diagnostic identifiers were damaged or unrelated opaque content was preserved"
fi
jq -e --arg container "${container_fixture_id}" --arg image "${image_fixture_id}" --arg machine "${machine_fixture_id}" '.containerID == $container and .imageID == $image and .machineID == $machine and .serviceAccountName == "diagnostic-account" and .priorityClassName == "system-cluster-critical" and .generateName == "diagnostic-workload-" and .workingDir == "/var/lib/hypershift/diagnostics" and .unrelated == "REDACTED_HIGH_ENTROPY"' "${diagnostic_identifiers_json}" > /dev/null 2>&1 || fail "JSON diagnostic identifiers were damaged or unrelated opaque content was preserved"
for batch_index in 1 70; do
  printf -v batch_name '%03d' "${batch_index}"
  yq -e '.spec.password == "REDACTED"' "${extract_dir}/output/cluster-scoped-resources/core/batch-state-${batch_name}.yaml" > /dev/null || fail "batched sanitizer state leaked across files"
done

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
assert_contains "${yaml_file}" "image: quay.io/openshift/origin-hypershift-operator"
yq -e ".items[0][0].image == \"quay.io/openshift/origin-hypershift-operator\" and .items[0][1].diagnostic == \"REDACTED_HIGH_ENTROPY\" and .items[1][0].image == \"quay.io/demo/controller@sha256:${digest}\"" "${nested_list_image_file}" > /dev/null || fail "nested YAML list images were damaged or exempted a later token"
assert_contains "${yaml_file}" 'diagnosticFlow: {password: REDACTED, keep: retained}'
assert_contains "${yaml_file}" 'opaque="REDACTED_HIGH_ENTROPY"'
assert_contains "${yaml_file}" 'lower_path_secret="REDACTED"'
assert_contains "${yaml_file}" 'echo keep-after-script-secrets'
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
assert_not_contains "${yaml_file}" "diagnostic=${opaque_fixture_token}"
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

assert_contains "${json_file}" "password=REDACTED and keep-json-diagnostic"
assert_contains "${json_file}" "https://REDACTED@example.invalid/api"
assert_contains "${json_file}" "\"commit\":\"${commit}\""
assert_contains "${json_file}" '"notcommit":"REDACTED_HIGH_ENTROPY"'
assert_contains "${json_file}" "sha256:${digest}"
jq --arg digest "${digest}" --arg commit "${commit}" -e '.password == "REDACTED" and .client_secret == "REDACTED" and .hashDiagnostic.commit == ($commit + " diagnostic=REDACTED_HIGH_ENTROPY") and .serviceAccountToken == {"audience":"api","expirationSeconds":3607,"path":"token"} and .automountServiceAccountToken == false and .volumes[0].projected.sources[0].serviceAccountToken.audience == "api" and .volumes[0].projected.sources[1].secret.name == "retained-projected-secret" and .volumes[1].secret.secretName == "retained-volume-secret" and .token == "REDACTED" and .items[0].spec.containers[0].image == ("quay.io/demo/controller@sha256:" + $digest) and .items[0].spec.containers[0].env[0].value == "REDACTED" and .items[0].spec.containers[1].env[0].value == "REDACTED" and .compactContainers[0].env[0].value == "REDACTED" and .compactContainers[1].env[0].value == "REDACTED" and .args == ["--password", "REDACTED", "--namespace", "default"] and .env[0].value == "REDACTED" and .env[1].valueFrom.secretKeyRef.name == "retained-json-reference" and .keep == "retained-json-field" and .keepBetweenPem == "retained-between-pem" and .pemBefore == "REDACTED_PEM" and .pemAfter == "REDACTED_PEM" and (.pem | contains("REDACTED_PEM") and contains("middle") and contains("post"))' "${json_file}" > /dev/null || fail "JSON credential, argument, PEM, or diagnostic preservation failed"
jq -e '.escapedEnv.env[0].value == "REDACTED" and .escapedArgv.args == ["--token", "REDACTED", "--namespace", "default"] and .escapedEnvKey.env[0].value == "REDACTED" and .escapedArgvKey.args == ["--password", "REDACTED", "--namespace", "default"]' "${json_file}" > /dev/null || fail "Unicode-escaped JSON credential identifiers were not redacted"
assert_contains "${compact_hash_file}" '"unrelated":"REDACTED_HIGH_ENTROPY"'
assert_contains "${compact_hash_file}" 'diagnostic=REDACTED_HIGH_ENTROPY'
assert_not_contains "${compact_hash_file}" "${opaque_fixture_token}"
jq --arg digest "${digest}" -e '.kind == "Pod" and .spec.containers[0].image == ("quay.io/demo/controller@sha256:" + $digest) and .unrelated == "REDACTED_HIGH_ENTROPY" and .diagnostic.commit == "note=REDACTED_HIGH_ENTROPY"' "${compact_image_context_file}" > /dev/null || fail "compact JSON image context leaked a later token or damaged the image digest"
jq -e '.spec.containers[0].image == "quay.io/openshift/origin-hypershift-operator" and .unrelated == "REDACTED_HIGH_ENTROPY"' "${ordinary_image_json_file}" > /dev/null || fail "ordinary JSON image context was damaged or exempted a later token"
jq -R -s -e '[split("\n")[] | select(length > 0) | try fromjson catch empty | select(.kind == "Pod")] | length == 1 and .[0].spec.containers[0].image == "quay.io/openshift/origin-hypershift-operator" and .[0].unrelated == "REDACTED_HIGH_ENTROPY"' "${ordinary_image_jsonl_file}" > /dev/null || fail "ordinary JSONL image context was damaged or exempted a later token"
assert_contains "${yaml_file}" 'not-image: "quay.io/demo/controller@sha256:REDACTED_HIGH_ENTROPY"'
assert_contains "${html_file}" "https://REDACTED@example.invalid/events/REDACTED_HIGH_ENTROPY"
assert_contains "${html_file}" "Authorization: REDACTED</a>"
assert_contains "${html_file}" "Authorization: REDACTED request-id=retained-html"
assert_contains "${html_file}" "</body></html>"
assert_contains "${log_file}" "Authorization: REDACTED"
assert_contains "${log_file}" "message Authorization: REDACTED"
assert_contains "${log_file}" "Run --password REDACTED --client-secret 'REDACTED' keep-after-flag"
assert_contains "${log_file}" "https://hooks.slack.com/services/REDACTED"
assert_not_contains "${log_file}" "${slack_webhook_fixture}"
assert_contains "${timestamp_file}" "password=REDACTED"
assert_not_contains "${log_file}" "${aws_access_key_fixture}"
assert_not_contains "${log_file}" "${aws_session_key_fixture}"
assert_contains "${log_file}" "{\"message\":\"commit: REDACTED_HIGH_ENTROPY\",\"commit\":\"${commit}\",\"unrelated\":\"REDACTED_HIGH_ENTROPY\"}"
assert_contains "${log_file}" "{\"message\":\"diagnostic commit: REDACTED_HIGH_ENTROPY\",\"commit\":\"${commit}\",\"unrelated\":\"REDACTED_HIGH_ENTROPY\"}"
jq -R -s --arg digest "${digest}" -e '[split("\n")[] | try fromjson catch empty | select(.kind == "Pod") | select(.spec.containers[0].image == ("quay.io/demo/controller@sha256:" + $digest))] | length == 1 and .[0].unrelated == "REDACTED_HIGH_ENTROPY" and .[0].diagnostic.commit == "note=REDACTED_HIGH_ENTROPY"' "${log_file}" > /dev/null || fail "JSONL image context leaked a later token or damaged the image digest"
assert_not_contains "${extract_dir}" "${opaque_fixture_token}"
assert_not_contains "${extract_dir}" "${lower_path_fixture_token}"
assert_not_contains "${extract_dir}" "${opaque_base64_fixture}"
assert_not_contains "${extract_dir}" "env-value-before-name-secret"
assert_not_contains "${extract_dir}" "flow-env-secret"
assert_not_contains "${extract_dir}" "multiline-env-secret"
assert_not_contains "${extract_dir}" "continuation-env-secret"
assert_not_contains "${extract_dir}" "continuation-secret"
assert_not_contains "${extract_dir}" "folded-plain-secret"
assert_not_contains "${extract_dir}" "continuation-plain-secret"
assert_not_contains "${extract_dir}" "yaml-argument-secret"
assert_not_contains "${extract_dir}" "multiline-private-key-material"
assert_not_contains "${extract_dir}" "quoted-password-pem-secret"
assert_not_contains "${extract_dir}" "forced-env-pem-secret"
assert_not_contains "${extract_dir}" "wrapped-flow-env-secret"
assert_not_contains "${extract_dir}" "inline-flow-env-fake"
assert_not_contains "${extract_dir}" "value-before-name-fake"
assert_not_contains "${extract_dir}" "repeated-yaml-pem-one"
assert_not_contains "${extract_dir}" "repeated-yaml-pem-two"
assert_not_contains "${extract_dir}" "after-scalar-arg-secret"
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
if ! (
  cd "${azure_run_dir}"
  FIXTURE_DIR="${fixture_dir}" ARTIFACT_DIR="${azure_artifact_dir}" PROW_JOB_ID=redaction-test \
    HYPERSHIFT_NAMESPACE=clusters CLOUD_PROVIDER=Azure bash "${command_file}"
) 2> "${azure_run_dir}/stderr.log"; then
  cat "${azure_run_dir}/stderr.log" >&2
  fail "Azure dump step failed"
fi
if grep -Fq 'awk:' "${azure_run_dir}/stderr.log"; then
  fail "Azure sanitizer emitted awk diagnostics"
fi
azure_archive="${azure_artifact_dir}/artifacts.tar.gz"
[[ -s "${azure_archive}" ]] || fail "Azure sanitized archive was not published"
tar -tzf "${azure_archive}" > "${work_dir}/azure-archive-list.txt" || fail "Azure archive listing failed"
azure_extract_dir="${work_dir}/azure-extracted"
mkdir -p "${azure_extract_dir}"
tar -xzf "${azure_archive}" -C "${azure_extract_dir}" || fail "Azure archive extraction failed"
validate_structured_files "${azure_extract_dir}/output" Azure
assert_gitleaks_status "${azure_extract_dir}" 0 "${work_dir}/gitleaks-azure-clean.log"
[[ -f "${azure_extract_dir}/output/cluster-scoped-resources/core/provider-Azure.yaml" && ! -e "${azure_extract_dir}/output/cluster-scoped-resources/core/provider-AWS.yaml" ]] || fail "Azure provider-specific fixture selection failed"
yq -e '.metadata.labels.provider == "Azure"' "${azure_extract_dir}/output/cluster-scoped-resources/core/provider-Azure.yaml" > /dev/null || fail "Azure provider fixture was not retained"
cmp -s "${extract_dir}/output/cluster-scoped-resources/core/nodes.yaml" "${azure_extract_dir}/output/cluster-scoped-resources/core/nodes.yaml" || fail "shared sanitization differs between provider runs"

# Verify semantic content on BOTH extracted archives, not just tar readability.
# Collect all three findings so one parser failure cannot mask the others.
content_failures=0
condition_identifier_query='.status.conditions[0].type == $conditionType and .status.conditions[0].reason == $conditionReason and .status.conditions[0].message == "REDACTED_HIGH_ENTROPY" and .status.conditions[0].token == "REDACTED" and .status.conditions[1].type == $conditionQualifiedType and .status.conditions[1].reason == $conditionReason and .status.reason == "REDACTED_HIGH_ENTROPY" and .diagnosticMap.conditions.type == "REDACTED_HIGH_ENTROPY" and .diagnosticMap.conditions.reason == "REDACTED_HIGH_ENTROPY" and .spec.conditions[0].type == "REDACTED_HIGH_ENTROPY" and .spec.conditions[0].reason == "REDACTED_HIGH_ENTROPY"'
condition_identifier_jsonl_query="length == 1 and (.[0] | ${condition_identifier_query})"
for provider_output in "${extract_dir}/output" "${azure_extract_dir}/output"; do
  content_dir="${provider_output}/cluster-scoped-resources/core"
  if ! yq -e '.spec.literal | contains("before the trailing diagnostic.")' "${content_dir}/certificate-descriptions.yaml" > /dev/null 2>&1 ||
     ! yq -e '.spec.folded | contains("before the trailing diagnostic.")' "${content_dir}/certificate-descriptions.yaml" > /dev/null 2>&1 ||
     ! yq -e '.spec.plain | contains("before the trailing diagnostic.")' "${content_dir}/certificate-descriptions.yaml" > /dev/null 2>&1 ||
     ! yq -e '.spec.quoted | contains("before the trailing diagnostic.")' "${content_dir}/certificate-descriptions.yaml" > /dev/null 2>&1 ||
     ! yq -e '.spec.repeated | (contains("between") and contains("before the trailing diagnostic."))' "${content_dir}/certificate-descriptions.yaml" > /dev/null 2>&1 ||
     ! yq -e '.spec.following == "retained" and (.spec.material | contains("REDACTED_PEM"))' "${content_dir}/certificate-descriptions.yaml" > /dev/null 2>&1; then
    echo "FAIL: certificate-description YAML structure or siblings were damaged" >&2
    content_failures=$((content_failures + 1))
  fi
  if ! yq -o=json '.' "${content_dir}/field-ownership.yaml" 2> /dev/null | jq -e '.metadata.managedFields[0].fieldsV1."f:spec"."f:token" == {".": {}, "f:server": {}} and .metadata.managedFields[0].fieldsV1."f:spec"."f:password" == {} and .metadata.managedFields[0].fieldsV1."f:spec"."f:client-secret" == {"f:name": {}} and .metadata.managedFields[0].fieldsV1."f:spec"."f:diagnosticToken" == "REDACTED" and .metadata.managedFields[0].fieldsV1."f:spec"."f:inlineToken" == {"password": "REDACTED", "keep": "retained"} and .metadata.managedFields[1].fieldsV1."f:spec"."f:api-key" == {} and .spec.token == "REDACTED" and .spec."f:token" == "REDACTED" and .spec.following == "retained"' > /dev/null 2>&1; then
    echo "FAIL: field-ownership keys were damaged or credential values escaped redaction" >&2
    content_failures=$((content_failures + 1))
  fi
  if ! yq -e '.kind == "CustomResourceDefinition" and .spec.names.kind == "DiagnosticResourceDefinition" and .spec.items[0][0].kind == "CustomResourceDefinition" and .spec.multilineKind.kind == "CustomResourceDefinition" and .spec.multilineKind.notkind == "REDACTED_HIGH_ENTROPY" and .spec.multilineKind.unrelated == "REDACTED_HIGH_ENTROPY" and .spec.notkind == "REDACTED_HIGH_ENTROPY" and .spec.message == "kind: REDACTED_HIGH_ENTROPY" and .spec.unrelated == "REDACTED_HIGH_ENTROPY"' "${content_dir}/resource-kinds.yaml" > /dev/null 2>&1 ||
     ! jq -e '.kind == "CustomResourceDefinition" and .notkind == "REDACTED_HIGH_ENTROPY" and .message == "kind: REDACTED_HIGH_ENTROPY" and .unrelated == "REDACTED_HIGH_ENTROPY"' "${content_dir}/resource-kinds.json" > /dev/null 2>&1 ||
     ! jq -e '.kind == "CustomResourceDefinition" and .notkind == "REDACTED_HIGH_ENTROPY" and .message == "kind: REDACTED_HIGH_ENTROPY" and .unrelated == "REDACTED_HIGH_ENTROPY"' "${content_dir}/resource-kinds.jsonl" > /dev/null 2>&1 ||
     ! jq -e '.kind == "CustomResourceDefinition" and .notkind == "REDACTED_HIGH_ENTROPY" and .message == "kind: REDACTED_HIGH_ENTROPY" and .unrelated == "REDACTED_HIGH_ENTROPY"' "${content_dir}/resource-kinds-pretty.json" > /dev/null 2>&1; then
    echo "FAIL: resource kinds were damaged or exempted unrelated tokens" >&2
    content_failures=$((content_failures + 1))
  fi
  if ! yq -o=json '.' "${content_dir}/condition-identifiers.yaml" 2>/dev/null | jq -e \
      --arg conditionType "${condition_type_fixture}" \
      --arg conditionReason "${condition_reason_fixture}" \
      --arg conditionQualifiedType "${condition_qualified_type_fixture}" \
      "${condition_identifier_query}" > /dev/null 2>&1 ||
     ! jq -e \
      --arg conditionType "${condition_type_fixture}" \
      --arg conditionReason "${condition_reason_fixture}" \
      --arg conditionQualifiedType "${condition_qualified_type_fixture}" \
      "${condition_identifier_query}" "${content_dir}/condition-identifiers-pretty.json" > /dev/null 2>&1 ||
     ! jq -e \
      --arg conditionType "${condition_type_fixture}" \
      --arg conditionReason "${condition_reason_fixture}" \
      --arg conditionQualifiedType "${condition_qualified_type_fixture}" \
      "${condition_identifier_query}" "${content_dir}/condition-identifiers.json" > /dev/null 2>&1 ||
     ! jq -s -e \
      --arg conditionType "${condition_type_fixture}" \
      --arg conditionReason "${condition_reason_fixture}" \
      --arg conditionQualifiedType "${condition_qualified_type_fixture}" \
      "${condition_identifier_jsonl_query}" "${content_dir}/condition-identifiers.jsonl" > /dev/null 2>&1; then
    echo "FAIL: condition identifiers were damaged or nearby opaque values were exempted" >&2
    content_failures=$((content_failures + 1))
  fi
  assert_not_contains "${provider_output}" "${condition_message_fixture}"
  assert_not_contains "${provider_output}" "${condition_outside_fixture}"
  assert_not_contains "${provider_output}" "${condition_map_fixture}"
  assert_contains "${content_dir}/resource-kinds.yaml" '# REDACTED_HIGH_ENTROPY REDACTED_HIGH_ENTROPY'
  yq -e '.spec.doubleQuoted | (contains("kind: REDACTED_HIGH_ENTROPY") and contains("password: REDACTED") and contains("done"))' "${content_dir}/resource-kinds.yaml" > /dev/null || fail "double-quoted diagnostic text acquired a structural exemption"
  yq -e '.spec.singleQuoted | (contains("kind: REDACTED_HIGH_ENTROPY") and contains("token: REDACTED") and contains("done"))' "${content_dir}/resource-kinds.yaml" > /dev/null || fail "single-quoted diagnostic text acquired a structural exemption"
  for kind_format in json jsonl; do
    jq -e '.kind == "CustomResourceDefinition" and ."prefix\"kind" == "REDACTED_HIGH_ENTROPY" and (.diagnostics | all(.kind == "diagnostic \"REDACTED_HIGH_ENTROPY"))' "${content_dir}/kind-boundaries.${kind_format}" > /dev/null || fail "escaped JSON quote was mistaken for a kind key/value boundary"
  done
  yq -o=json '.' "${content_dir}/plain-quoted-continuations.yaml" | jq -e 'all(.[]; .kind == "CustomResourceDefinition" and .token == "REDACTED" and .following == "retained" and (.message | contains("quoted fragment")))' > /dev/null || fail "plain scalar text disabled subsequent credential redaction"
  yq -o=json '.' "${content_dir}/quoted-scalar-starts.yaml" | jq -e '.kind == "CustomResourceDefinition" and .password == "REDACTED" and .following == "retained" and ([.deferred, .anchored, .items[0]] | all(contains("kind: REDACTED_HIGH_ENTROPY") and contains("done")))' > /dev/null || fail "quoted scalar lifecycle damaged diagnostics or exempted a token"
  assert_not_contains "${provider_output}" "${short_fixture_token}"
done
[[ "${content_failures}" -eq 0 ]] || fail "${content_failures} archive content-integrity checks failed"

# A nonzero dump command may still leave useful resources. Sanitize and publish
# those partial diagnostics when the existing resource-presence gate succeeds.
partial_dump_dir="${work_dir}/partial-dump-run"
partial_fixture_dir="${work_dir}/partial-dump-fixtures"
partial_artifact_dir="${partial_dump_dir}/artifacts"
partial_secret_fixture="$(new_fixture_token)"
mkdir -p "${partial_fixture_dir}/cluster-scoped-resources/core"
cat > "${partial_fixture_dir}/cluster-scoped-resources/core/partial.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: partial-dump
  annotations:
    password: ${partial_secret_fixture}
    diagnostic: retained
EOF
make_fake_runner "${partial_dump_dir}"
if (
  cd "${partial_dump_dir}"
  PATH="${partial_dump_dir}/bin:${PATH}" FIXTURE_DIR="${partial_fixture_dir}" \
    ARTIFACT_DIR="${partial_artifact_dir}" FAKE_DUMP_EXIT_STATUS=17 \
    PROW_JOB_ID=redaction-test HYPERSHIFT_NAMESPACE=clusters CLOUD_PROVIDER=AWS \
    bash "${command_file}"
) > "${partial_dump_dir}/run.log" 2>&1; then
  :
else
  fail "a dump command failure discarded sanitizable partial diagnostics"
fi
assert_contains "${partial_dump_dir}/run.log" "sanitizing collected diagnostics"
partial_archive="${partial_artifact_dir}/artifacts.tar.gz"
[[ -s "${partial_archive}" ]] || fail "partial diagnostics were not archived"
tar -tzf "${partial_archive}" > /dev/null || fail "partial archive is invalid"
partial_extract_dir="${work_dir}/partial-dump-extracted"
mkdir -p "${partial_extract_dir}"
tar -xzf "${partial_archive}" -C "${partial_extract_dir}" || fail "partial archive extraction failed"
partial_yaml="${partial_extract_dir}/output/cluster-scoped-resources/core/partial.yaml"
yq -e '.kind == "Pod" and .metadata.annotations.diagnostic == "retained"' \
  "${partial_yaml}" > /dev/null || fail "partial diagnostic content was not preserved"
assert_not_contains "${partial_extract_dir}" "${partial_secret_fixture}"
assert_gitleaks_status "${partial_extract_dir}" 0 "${partial_dump_dir}/gitleaks.log"

# Unterminated embedded JSON is isolated to its file. The surrounding dump
# remains publishable, and oversized captures are bounded.
json_failure_dir="${work_dir}/truncated-json-run"
json_fixture_dir="${work_dir}/truncated-json-fixtures"
json_artifact_dir="${json_failure_dir}/artifacts"
truncated_json_fixture="$(new_fixture_token)"
oversized_json_fixture="$(new_fixture_token)"
truncated_html_fixture="$(new_fixture_token)"
fragmented_json_fixture="$(new_fixture_token)"
mkdir -p "${json_fixture_dir}/cluster-scoped-resources/core"
cat > "${json_fixture_dir}/cluster-scoped-resources/core/pod.yaml" <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: json-capture-diagnostic
EOF
printf 'log {"password":"%s",\n' "${truncated_json_fixture}" \
  > "${json_fixture_dir}/cluster-scoped-resources/core/truncated.log"
printf 'log {"password":"%s","padding":"\n' "${oversized_json_fixture}" \
  > "${json_fixture_dir}/cluster-scoped-resources/core/oversized.log"
printf '<html><body>event: {"password":"%s",\n' "${truncated_html_fixture}" \
  > "${json_fixture_dir}/cluster-scoped-resources/core/truncated.html"
{
  printf 'event: {"password":\n'
  for ((fragment = 0; fragment < 4; fragment++)); do
    printf '%64s\n' ' '
  done
  printf '  "%s"}\n' "${fragmented_json_fixture}"
} > "${json_fixture_dir}/cluster-scoped-resources/core/fragmented.log"
awk 'BEGIN { for (i = 0; i < 1100; i++) printf "%1024s\n", "x" }' \
  >> "${json_fixture_dir}/cluster-scoped-resources/core/oversized.log"
make_fake_runner "${json_failure_dir}"
if ! (
  cd "${json_failure_dir}"
  PATH="${json_failure_dir}/bin:${PATH}" FIXTURE_DIR="${json_fixture_dir}" \
    ARTIFACT_DIR="${json_artifact_dir}" PROW_JOB_ID=redaction-test \
    HYPERSHIFT_NAMESPACE=clusters CLOUD_PROVIDER=AWS bash "${command_file}"
) > "${json_failure_dir}/run.log" 2>&1; then
  cat "${json_failure_dir}/run.log" >&2
  fail "an unterminated embedded JSON file blocked the dump archive"
fi
assert_contains "${json_failure_dir}/run.log" "Sanitizer omitted a text diagnostic file"
json_failure_archive="${json_artifact_dir}/artifacts.tar.gz"
[[ -s "${json_failure_archive}" ]] || fail "archive was not published after omitting malformed JSON logs"
tar -tzf "${json_failure_archive}" > /dev/null || fail "truncated-JSON archive is invalid"
json_extract_dir="${work_dir}/truncated-json-extracted"
mkdir -p "${json_extract_dir}"
tar -xzf "${json_failure_archive}" -C "${json_extract_dir}" || fail "truncated-JSON archive extraction failed"
json_output_dir="${json_extract_dir}/output/cluster-scoped-resources/core"
yq -e '.kind == "Pod" and .metadata.name == "json-capture-diagnostic"' \
  "${json_output_dir}/pod.yaml" > /dev/null || fail "valid diagnostics were lost with malformed JSON logs"
printf '%s\n' 'Sanitizer omitted this file because embedded JSON was incomplete or too large.' \
  > "${json_failure_dir}/expected-omission.log"
cmp -s "${json_failure_dir}/expected-omission.log" "${json_output_dir}/truncated.log" || \
  fail "unterminated JSON file was not replaced with a data-free notice"
cmp -s "${json_failure_dir}/expected-omission.log" "${json_output_dir}/oversized.log" || \
  fail "oversized JSON file was not replaced with a data-free notice"
printf '%s\n' '<!-- Sanitizer omitted this file because embedded JSON was incomplete or too large. -->' \
  > "${json_failure_dir}/expected-html-omission.log"
cmp -s "${json_failure_dir}/expected-html-omission.log" "${json_output_dir}/truncated.html" || \
  fail "unterminated embedded JSON HTML was not replaced with a data-free comment"
assert_not_contains "${json_extract_dir}" "${truncated_json_fixture}"
assert_not_contains "${json_extract_dir}" "${oversized_json_fixture}"
assert_not_contains "${json_extract_dir}" "${truncated_html_fixture}"
assert_not_contains "${json_extract_dir}" "${fragmented_json_fixture}"
if ! sed '1s/^event: //' "${json_output_dir}/fragmented.log" | \
  jq -e '.password == "REDACTED"' > /dev/null 2> "${json_failure_dir}/fragmented-json-jq.log"; then
  fail "multiline embedded JSON was malformed or not redacted"
fi
assert_gitleaks_status "${json_extract_dir}" 0 "${json_failure_dir}/gitleaks.log"

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

# A truncated PEM is already redacted; it must not block the archive or
# consume the YAML sibling that follows its block scalar.
pem_failure_dir="${work_dir}/pem-failure-run"
make_fake_runner "${pem_failure_dir}"
cp -R "${fixture_dir}/." "${pem_failure_dir}/fixture-copy"
mkdir -p "${pem_failure_dir}/fixture-copy/cluster-scoped-resources/core"
truncated_pem_fixture="$(new_fixture_token)"
cat > "${pem_failure_dir}/fixture-copy/cluster-scoped-resources/core/truncated-pem.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: truncated-pem
  annotations:
    description: |
      ${pem_private_begin_marker}
      ${truncated_pem_fixture}
  labels:
    retained: yes
  message: "prefix -----BEGIN CERTIFICATE-----${truncated_pem_fixture}"
EOF
pem_failure_artifact_dir="${pem_failure_dir}/artifacts"
if (
  cd "${pem_failure_dir}"
  FIXTURE_DIR="${pem_failure_dir}/fixture-copy" ARTIFACT_DIR="${pem_failure_artifact_dir}" \
    PROW_JOB_ID=redaction-test HYPERSHIFT_NAMESPACE=clusters CLOUD_PROVIDER=AWS bash "${command_file}"
) > "${work_dir}/pem-failure.log" 2>&1; then
  :
else
  fail "step failed to publish a sanitized archive for a truncated PEM"
fi
pem_archive="${pem_failure_artifact_dir}/artifacts.tar.gz"
[[ -s "${pem_archive}" ]] || fail "sanitized archive was not published for a truncated PEM"
pem_extract_dir="${pem_failure_dir}/extracted"
mkdir -p "${pem_extract_dir}"
tar -xzf "${pem_archive}" -C "${pem_extract_dir}" || fail "truncated-PEM archive extraction failed"
pem_yaml="${pem_extract_dir}/output/cluster-scoped-resources/core/truncated-pem.yaml"
yq '.' "${pem_yaml}" > /dev/null || fail "truncated-PEM YAML is invalid"
yq -e '.metadata.labels.retained == "yes" and (.metadata.annotations.description | contains("REDACTED_PEM")) and (.metadata.message | contains("REDACTED_PEM"))' "${pem_yaml}" > /dev/null || fail "truncated-PEM sanitization damaged diagnostics"
assert_not_contains "${pem_yaml}" "${truncated_pem_fixture}"

# An unterminated flow collection must also fail closed rather than publishing
# a file that has not reached credential sanitization.
flow_failure_dir="${work_dir}/flow-failure-run"
make_fake_runner "${flow_failure_dir}"
cp -R "${fixture_dir}/." "${flow_failure_dir}/fixture-copy"
flow_failure_fixture="$(new_fixture_token)"
printf '%s\n' 'env: [{name: API_TOKEN,' "       value: ${flow_failure_fixture}" > \
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
assert_contains "${work_dir}/flow-failure.log" "Sanitizer rejected malformed structured diagnostic input"

# A mismatched close can end flow tracking before a matching delimiter exists;
# this remains fatal even though the parser has cleared its capture state.
malformed_flow_failure_dir="${work_dir}/malformed-flow-failure-run"
make_fake_runner "${malformed_flow_failure_dir}"
cp -R "${fixture_dir}/." "${malformed_flow_failure_dir}/fixture-copy"
malformed_flow_fixture="$(new_fixture_token)"
printf '%s\n' 'password: [{name: value,' "       value: ${malformed_flow_fixture}}}" > \
  "${malformed_flow_failure_dir}/fixture-copy/cluster-scoped-resources/core/malformed-flow.yaml"
malformed_flow_artifact_dir="${malformed_flow_failure_dir}/artifacts"
if (
  cd "${malformed_flow_failure_dir}"
  FIXTURE_DIR="${malformed_flow_failure_dir}/fixture-copy" ARTIFACT_DIR="${malformed_flow_artifact_dir}" \
    PROW_JOB_ID=redaction-test HYPERSHIFT_NAMESPACE=clusters CLOUD_PROVIDER=AWS bash "${command_file}"
) > "${work_dir}/malformed-flow-failure.log" 2>&1; then
  fail "step unexpectedly succeeded after a malformed YAML flow collection"
fi
[[ ! -e "${malformed_flow_artifact_dir}/artifacts.tar.gz" ]] || fail "archive was published with a malformed YAML flow collection"
assert_contains "${work_dir}/malformed-flow-failure.log" "Sanitizer rejected malformed structured diagnostic input"
assert_not_contains "${work_dir}/malformed-flow-failure.log" "${malformed_flow_fixture}"

echo "PASS: dump sanitization, archive round-trip, diagnostic preservation, and fail-closed handling"
