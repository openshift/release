#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
setup_script="${repo_root}/ci-operator/step-registry/ipi/conf/nutanix/dns/ipi-conf-nutanix-dns-commands.sh"
cleanup_script="${repo_root}/ci-operator/step-registry/ipi/deprovision/nutanix/dns/ipi-deprovision-nutanix-dns-commands.sh"
test_root="$(mktemp -d)"
trap 'rm -rf "${test_root}"' EXIT

passed=0
run_output=""
run_status=0
aws_mock_error=$'synthetic AWS failure: SENTINEL_ENV_KEY_MUST_NOT_APPEAR\nmetacharacters: $(not-executed); [*] | SENTINEL_ENV_TOKEN_MUST_NOT_APPEAR\nprofile=SENTINEL_PROFILE_MUST_NOT_APPEAR'

fail() {
    echo "not ok - $*" >&2
    exit 1
}

pass() {
    echo "ok - $*"
    passed=$((passed + 1))
}

assert_status() {
    local expected="$1"
    [[ "${run_status}" -eq "${expected}" ]] || fail "expected status ${expected}, got ${run_status}; output: ${run_output}"
}

assert_contains() {
    local expected="$1"
    [[ "${run_output}" == *"${expected}"* ]] || fail "output did not contain: ${expected}; output: ${run_output}"
}

assert_not_contains() {
    local unexpected="$1"
    [[ "${run_output}" != *"${unexpected}"* ]] || fail "output contained redacted sentinel: ${unexpected}"
}

assert_no_aws_calls() {
    [[ ! -s "${aws_call_log}" ]] || fail "unexpected mocked AWS calls: $(<"${aws_call_log}")"
}

assert_aws_operations() {
    local expected="$1"
    local actual=""
    [[ ! -s "${aws_call_log}" ]] || actual="$(<"${aws_call_log}")"
    [[ "${actual}" == "${expected}" ]] || fail "unexpected mocked AWS operation order; expected: ${expected}; actual: ${actual}"
}

assert_aws_error_redacted() {
    assert_not_contains SENTINEL_ENV_KEY_MUST_NOT_APPEAR
    assert_not_contains SENTINEL_ENV_TOKEN_MUST_NOT_APPEAR
    assert_not_contains SENTINEL_PROFILE_MUST_NOT_APPEAR
    assert_not_contains '$(not-executed)'
    assert_not_contains 'metacharacters:'
}

reset_aws_calls() {
    : > "${aws_call_log}"
}

run_and_capture() {
    set +e
    run_output="$("$@" 2>&1)"
    run_status=$?
    set -e
}

new_case() {
    local name="$1"
    case_dir="${test_root}/${name}"
    shared_dir="${case_dir}/shared"
    mock_bin="${case_dir}/mock-bin"
    no_aws_bin="${case_dir}/no-aws-bin"
    aws_call_log="${case_dir}/aws-calls.log"
    credential_file="${case_dir}/.awscred"
    runtime_setup_script="${case_dir}/setup.sh"
    mkdir -p "${shared_dir}" "${mock_bin}" "${no_aws_bin}"
    : > "${aws_call_log}"
    ln -s "$(command -v date)" "${no_aws_bin}/date"

    while IFS= read -r line
    do
        printf '%s\n' "${line//\/var\/run\/vault\/nutanix\/.awscred/${credential_file}}"
    done < "${setup_script}" > "${runtime_setup_script}"
    chmod +x "${runtime_setup_script}"

    [[ "$(grep -Fxc "export AWS_SHARED_CREDENTIALS_FILE=${credential_file}" "${runtime_setup_script}")" -eq 1 ]] || fail "runtime setup did not contain exactly one transformed credential assignment"
    [[ "$(grep -Foc '/var/run/vault/nutanix/.awscred' "${runtime_setup_script}" || true)" -eq 0 ]] || fail "runtime setup retained the production credential path"

    cat > "${mock_bin}/aws" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

actual=("$@")
operation="${1:-} ${2:-}"

assert_exact_args() {
    local -a expected=("$@")
    local index

    [[ "${#actual[@]}" -eq "${#expected[@]}" ]] || {
        echo "unexpected argument count for ${operation}" >&2
        exit 46
    }
    for index in "${!expected[@]}"
    do
        [[ "${actual[${index}]}" == "${expected[${index}]}" ]] || {
            echo "unexpected argument ${index} for ${operation}" >&2
            exit 46
        }
    done
}

validate_change_batch() {
    local batch_file="$1"
    local action="$2"

    if ! python3 - "${batch_file}" "${action}" "${EXPECTED_CLUSTER_DOMAIN:?}" "${EXPECTED_API_VIP:?}" "${EXPECTED_INGRESS_VIP:?}" <<'PYTHON'
import json
import sys

path, action, cluster_domain, api_vip, ingress_vip = sys.argv[1:]
with open(path, encoding="utf-8") as stream:
    batch = json.load(stream)

expected = {
    f"api.{cluster_domain}.": api_vip,
    f"api-int.{cluster_domain}.": api_vip,
    f"*.apps.{cluster_domain}.": ingress_vip,
}
changes = batch.get("Changes")
if not isinstance(changes, list) or len(changes) != len(expected):
    raise SystemExit(1)
actual_records = {}
for change in changes:
    record = change.get("ResourceRecordSet", {})
    values = record.get("ResourceRecords")
    if (change.get("Action") != action or record.get("Type") != "A" or
            record.get("TTL") != 60 or not isinstance(values, list) or
            len(values) != 1):
        raise SystemExit(1)
    actual_records[record.get("Name")] = values[0].get("Value")
if actual_records != expected:
    raise SystemExit(1)
PYTHON
    then
        echo "unexpected Route53 change batch semantics" >&2
        exit 46
    fi
}

case "${operation}" in
    "route53 list-hosted-zones-by-name")
        assert_exact_args \
            route53 list-hosted-zones-by-name \
            --dns-name "${EXPECTED_BASE_DOMAIN:?}" \
            --query "HostedZones[? Config.PrivateZone != \`true\` && Name == \`${EXPECTED_BASE_DOMAIN}.\`].Id" \
            --output text
        printf '%s\n' "${operation}" >> "${AWS_CALL_LOG:?}"
        if [[ "${AWS_MOCK_SCENARIO:-}" == lookup-failure ]]
        then
            echo "${AWS_MOCK_ERROR:-mocked lookup failure}" >&2
            exit 41
        fi
        if [[ "${AWS_MOCK_SCENARIO:-}" == lookup-empty ]]
        then
            exit 0
        fi
        if [[ "${AWS_MOCK_SCENARIO:-}" == lookup-invalid ]]
        then
            echo "synthetic-invalid-zone"
            exit 0
        fi
        if [[ "${AWS_MOCK_SCENARIO:-}" == lookup-multiple ]]
        then
            printf '%s\t%s\n' "${EXPECTED_HOSTED_ZONE_ID:?}" /hostedzone/ZSECOND456
            exit 0
        fi
        echo "${EXPECTED_HOSTED_ZONE_ID:?}"
        ;;
    "route53 change-resource-record-sets")
        if [[ "${AWS_MOCK_PHASE:?}" == setup ]]
        then
            batch_file="${EXPECTED_SHARED_DIR:?}/dns-create.json"
            batch_uri="file:///${batch_file}"
            batch_action=UPSERT
            change_id="${EXPECTED_CREATE_CHANGE_ID:?}"
        else
            batch_file="${EXPECTED_SHARED_DIR:?}/dns-delete.json"
            batch_uri="file://${batch_file}"
            batch_action=DELETE
            change_id="${EXPECTED_DELETE_CHANGE_ID:?}"
        fi
        assert_exact_args \
            route53 change-resource-record-sets \
            --hosted-zone-id "${EXPECTED_HOSTED_ZONE_ID:?}" \
            --change-batch "${batch_uri}" \
            --query '"ChangeInfo"."Id"' \
            --output text
        validate_change_batch "${batch_file}" "${batch_action}"
        printf '%s\n' "${operation}" >> "${AWS_CALL_LOG:?}"
        if [[ "${AWS_MOCK_PHASE}" == setup && "${AWS_MOCK_SCENARIO:-}" == create-failure ]]
        then
            echo "${AWS_MOCK_ERROR:-mocked create failure}" >&2
            exit 42
        fi
        if [[ "${AWS_MOCK_PHASE}" == cleanup && "${AWS_MOCK_SCENARIO:-}" == delete-failure ]]
        then
            echo "${AWS_MOCK_ERROR:-mocked delete failure}" >&2
            exit 43
        fi
        echo "${change_id}"
        ;;
    "route53 wait")
        if [[ "${AWS_MOCK_PHASE:?}" == setup ]]
        then
            change_id="${EXPECTED_CREATE_CHANGE_ID:?}"
        else
            change_id="${EXPECTED_DELETE_CHANGE_ID:?}"
        fi
        assert_exact_args route53 wait resource-record-sets-changed --id "${change_id}"
        printf '%s\n' "${operation}" >> "${AWS_CALL_LOG:?}"
        if [[ "${AWS_MOCK_SCENARIO:-}" == wait-failure ]]
        then
            echo "${AWS_MOCK_ERROR:-mocked wait failure}" >&2
            echo "${AWS_MOCK_ERROR:-mocked wait failure}"
            exit 44
        fi
        ;;
    *)
        echo "unexpected mocked AWS operation" >&2
        exit 45
        ;;
esac
EOF
    chmod +x "${mock_bin}/aws"
}

write_credentials() {
    cat > "${credential_file}" <<'EOF'
SENTINEL_FILE_KEY_MUST_NOT_APPEAR
SENTINEL_FILE_SECRET_MUST_NOT_APPEAR
EOF
}

write_nutanix_context() {
    cat > "${shared_dir}/nutanix_context.sh" <<'EOF'
API_VIP=192.0.2.10
INGRESS_VIP=192.0.2.11
EOF
}

run_setup() {
    local scenario="$1"
    shift
    run_and_capture env -i \
        PATH="${mock_bin}:/usr/bin:/bin" \
        SHARED_DIR="${shared_dir}" \
        BASE_DOMAIN=example.test \
        NAMESPACE=synthetic \
        UNIQUE_HASH=case \
        AWS_CALL_LOG="${aws_call_log}" \
        AWS_MOCK_PHASE=setup \
        AWS_MOCK_SCENARIO="${scenario}" \
        AWS_MOCK_ERROR="${aws_mock_error}" \
        EXPECTED_SHARED_DIR="${shared_dir}" \
        EXPECTED_BASE_DOMAIN=example.test \
        EXPECTED_CLUSTER_DOMAIN=synthetic-case.example.test \
        EXPECTED_API_VIP=192.0.2.10 \
        EXPECTED_INGRESS_VIP=192.0.2.11 \
        EXPECTED_HOSTED_ZONE_ID=/hostedzone/ZTEST123 \
        EXPECTED_CREATE_CHANGE_ID=/change/CCREATE123 \
        EXPECTED_DELETE_CHANGE_ID=/change/CDELETE123 \
        "$@" \
        /bin/bash "${runtime_setup_script}"
}

run_setup_without_aws() {
    run_and_capture "$@" env -i \
        PATH="${no_aws_bin}" \
        SHARED_DIR="${shared_dir}" \
        BASE_DOMAIN=example.test \
        NAMESPACE=synthetic \
        UNIQUE_HASH=case \
        /bin/bash "${runtime_setup_script}"
}

run_cleanup_with_mock() {
    local scenario="$1"
    run_and_capture env -i \
        PATH="${mock_bin}:/usr/bin:/bin" \
        SHARED_DIR="${shared_dir}" \
        AWS_CALL_LOG="${aws_call_log}" \
        AWS_MOCK_PHASE=cleanup \
        AWS_MOCK_SCENARIO="${scenario}" \
        AWS_MOCK_ERROR="${aws_mock_error}" \
        EXPECTED_SHARED_DIR="${shared_dir}" \
        EXPECTED_BASE_DOMAIN=example.test \
        EXPECTED_CLUSTER_DOMAIN=synthetic-case.example.test \
        EXPECTED_API_VIP=192.0.2.10 \
        EXPECTED_INGRESS_VIP=192.0.2.11 \
        EXPECTED_HOSTED_ZONE_ID=/hostedzone/ZTEST123 \
        EXPECTED_CREATE_CHANGE_ID=/change/CCREATE123 \
        EXPECTED_DELETE_CHANGE_ID=/change/CDELETE123 \
        /bin/bash "${cleanup_script}"
}

[[ "$(grep -Fxc 'export AWS_SHARED_CREDENTIALS_FILE=/var/run/vault/nutanix/.awscred' "${setup_script}")" -eq 1 ]] || fail "production setup must contain exactly one intended credential assignment"
[[ "$(grep -Foc '/var/run/vault/nutanix/.awscred' "${setup_script}")" -eq 1 ]] || fail "production credential path must occur only in the intended assignment"

setup_operations=$'route53 list-hosted-zones-by-name\nroute53 change-resource-record-sets\nroute53 wait'
cleanup_operations=$'route53 change-resource-record-sets\nroute53 wait'

new_case missing-credential-file
run_setup_without_aws
assert_status 1
assert_contains "AWS credential file status: regular=false readable=false nonempty=false"
assert_contains "expected AWS credential file is not a readable, nonempty regular file"
assert_not_contains "Install AWS cli"
assert_no_aws_calls
pass "setup rejects a missing credential file before CLI installation"

new_case empty-credential-file
: > "${credential_file}"
run_setup_without_aws
assert_status 1
assert_contains "AWS credential file status: regular=true readable=true nonempty=false"
assert_not_contains "Install AWS cli"
assert_no_aws_calls
pass "setup rejects an empty credential file before CLI installation"

new_case directory-credential-path
mkdir "${credential_file}"
run_setup_without_aws
assert_status 1
assert_contains "AWS credential file status: regular=false"
assert_contains "expected AWS credential file is not a readable, nonempty regular file"
assert_not_contains "Install AWS cli"
assert_no_aws_calls
pass "setup rejects a credential directory before CLI installation"

new_case unreadable-credential-path
write_credentials
chmod 000 "${credential_file}"
[[ -f "${credential_file}" ]] || fail "unreadable credential fixture is not a regular file"
[[ -s "${credential_file}" ]] || fail "unreadable credential fixture is empty"
if [[ -r "${credential_file}" ]]
then
    [[ "${EUID}" -eq 0 ]] || fail "mode-000 credential fixture is unexpectedly readable by a non-root user"
    setpriv_path="$(command -v setpriv)" || fail "setpriv is required to test unreadable credentials as root"
    run_setup_without_aws \
        "${setpriv_path}" \
        --no-new-privs \
        --bounding-set=-dac_override,-dac_read_search
else
    run_setup_without_aws
fi
assert_status 1
assert_contains "AWS credential file status: regular=true readable=false nonempty=true"
assert_contains "expected AWS credential file is not a readable, nonempty regular file"
assert_not_contains "Install AWS cli"
assert_no_aws_calls
pass "setup rejects an unreadable credential path before CLI installation"

new_case redacted-diagnostics
write_credentials
write_nutanix_context
run_setup success \
    AWS_ACCESS_KEY_ID=SENTINEL_ENV_KEY_MUST_NOT_APPEAR \
    AWS_SECRET_ACCESS_KEY=SENTINEL_ENV_SECRET_MUST_NOT_APPEAR \
    AWS_SESSION_TOKEN=SENTINEL_ENV_TOKEN_MUST_NOT_APPEAR \
    AWS_PROFILE=SENTINEL_PROFILE_MUST_NOT_APPEAR
assert_status 0
assert_contains "AWS_ACCESS_KEY_ID=true"
assert_contains "AWS_SECRET_ACCESS_KEY=true"
assert_contains "AWS_SESSION_TOKEN=true"
assert_contains "AWS_PROFILE=true"
assert_contains "AWS effective credential provider: unavailable"
assert_not_contains SENTINEL_ENV_KEY_MUST_NOT_APPEAR
assert_not_contains SENTINEL_ENV_SECRET_MUST_NOT_APPEAR
assert_not_contains SENTINEL_ENV_TOKEN_MUST_NOT_APPEAR
assert_not_contains SENTINEL_PROFILE_MUST_NOT_APPEAR
assert_not_contains SENTINEL_FILE_KEY_MUST_NOT_APPEAR
assert_not_contains SENTINEL_FILE_SECRET_MUST_NOT_APPEAR
assert_aws_operations "${setup_operations}"
pass "setup diagnostics report booleans without credential or profile values"

new_case setup-to-cleanup
write_credentials
write_nutanix_context
run_setup success
assert_status 0
assert_contains "DNS records created."
[[ "$(<"${shared_dir}/hosted-zone.txt")" == /hostedzone/ZTEST123 ]] || fail "setup saved an unexpected hosted zone ID"
[[ -s "${shared_dir}/dns-create.json" ]] || fail "setup did not save dns-create.json"
[[ -s "${shared_dir}/dns-delete.json" ]] || fail "setup did not save dns-delete.json"
assert_aws_operations "${setup_operations}"
reset_aws_calls
run_cleanup_with_mock success
assert_status 0
assert_contains "Delete successful."
assert_aws_operations "${cleanup_operations}"
pass "cleanup consumes setup-generated hosted-zone and exact delete-batch state"

new_case lookup-failure
write_credentials
write_nutanix_context
run_setup lookup-failure
assert_status 1
assert_contains "Route53 hosted-zone lookup failed"
assert_aws_error_redacted
assert_aws_operations "route53 list-hosted-zones-by-name"
[[ ! -e "${shared_dir}/hosted-zone.txt" ]] || fail "failed lookup wrote hosted-zone state"
pass "setup keeps lookup failures fatal and sanitizes multiline AWS errors"

for lookup_scenario in lookup-empty lookup-invalid
do
    new_case "${lookup_scenario}"
    write_credentials
    write_nutanix_context
    run_setup "${lookup_scenario}"
    assert_status 1
    assert_contains "Route53 hosted-zone lookup returned no valid public hosted zone"
    assert_not_contains "synthetic-invalid-zone"
    assert_not_contains "Install AWS cli"
    assert_aws_operations "route53 list-hosted-zones-by-name"
    [[ ! -e "${shared_dir}/hosted-zone.txt" ]] || fail "invalid lookup output wrote hosted-zone state"
    pass "setup rejects successful ${lookup_scenario#lookup-} hosted-zone lookup output"
done

new_case lookup-multiple
write_credentials
write_nutanix_context
run_setup lookup-multiple
assert_status 1
assert_contains "Route53 hosted-zone lookup returned multiple matching public hosted zones"
assert_not_contains "/hostedzone/ZTEST123"
assert_not_contains "/hostedzone/ZSECOND456"
assert_not_contains "Install AWS cli"
assert_aws_operations "route53 list-hosted-zones-by-name"
[[ ! -e "${shared_dir}/hosted-zone.txt" ]] || fail "multiple lookup output wrote hosted-zone state"
pass "setup rejects multiple tab-separated hosted-zone lookup results without echoing them"

new_case create-failure-cleanup
write_credentials
write_nutanix_context
run_setup create-failure
assert_status 1
assert_contains "Route53 DNS record creation failed"
assert_aws_error_redacted
assert_aws_operations $'route53 list-hosted-zones-by-name\nroute53 change-resource-record-sets'
[[ -s "${shared_dir}/hosted-zone.txt" ]] || fail "create failure did not retain hosted-zone cleanup state"
[[ -s "${shared_dir}/dns-delete.json" ]] || fail "create failure did not retain delete cleanup state"
reset_aws_calls
run_cleanup_with_mock success
assert_status 0
assert_aws_operations "${cleanup_operations}"
pass "setup create failure retains exact state consumed by cleanup"

new_case setup-wait-failure-cleanup
write_credentials
write_nutanix_context
run_setup wait-failure
assert_status 1
assert_contains "waiting for Route53 DNS record creation failed"
assert_aws_error_redacted
assert_aws_operations "${setup_operations}"
[[ -s "${shared_dir}/hosted-zone.txt" ]] || fail "setup wait failure did not retain hosted-zone cleanup state"
[[ -s "${shared_dir}/dns-delete.json" ]] || fail "setup wait failure did not retain delete cleanup state"
reset_aws_calls
run_cleanup_with_mock success
assert_status 0
assert_aws_operations "${cleanup_operations}"
pass "setup wait failure retains exact state consumed by cleanup"

new_case absent-cleanup-state
run_and_capture env -i PATH="${no_aws_bin}" SHARED_DIR="${shared_dir}" /bin/bash "${cleanup_script}"
assert_status 0
assert_contains "No Nutanix DNS setup state found; nothing to delete."
assert_not_contains "Install AWS cli"
assert_no_aws_calls
pass "cleanup no-ops before CLI installation only when setup state is absent"

new_case empty-hosted-zone-state
: > "${shared_dir}/hosted-zone.txt"
run_and_capture env -i PATH="${no_aws_bin}" SHARED_DIR="${shared_dir}" /bin/bash "${cleanup_script}"
assert_status 1
assert_contains "hosted-zone.txt is not a readable, nonempty file"
assert_not_contains "Install AWS cli"
assert_no_aws_calls
pass "cleanup rejects empty hosted-zone state before CLI installation"

new_case invalid-hosted-zone-state
printf 'not-a-zone\n' > "${shared_dir}/hosted-zone.txt"
run_and_capture env -i PATH="${no_aws_bin}" SHARED_DIR="${shared_dir}" /bin/bash "${cleanup_script}"
assert_status 1
assert_contains "invalid hosted zone ID"
assert_not_contains "not-a-zone"
assert_not_contains "Install AWS cli"
assert_no_aws_calls
pass "cleanup rejects invalid hosted-zone state without echoing it"

new_case missing-delete-state
printf '/hostedzone/ZTEST123\n' > "${shared_dir}/hosted-zone.txt"
run_and_capture env -i PATH="${no_aws_bin}" SHARED_DIR="${shared_dir}" /bin/bash "${cleanup_script}"
assert_status 1
assert_contains "dns-delete.json is missing, unreadable, or empty"
assert_not_contains "Install AWS cli"
assert_no_aws_calls
pass "cleanup rejects missing delete state before CLI installation"

new_case empty-delete-state
printf '/hostedzone/ZTEST123\n' > "${shared_dir}/hosted-zone.txt"
: > "${shared_dir}/dns-delete.json"
run_and_capture env -i PATH="${no_aws_bin}" SHARED_DIR="${shared_dir}" /bin/bash "${cleanup_script}"
assert_status 1
assert_contains "dns-delete.json is missing, unreadable, or empty"
assert_not_contains "Install AWS cli"
assert_no_aws_calls
pass "cleanup rejects empty delete state before CLI installation"

new_case delete-failure
write_credentials
write_nutanix_context
run_setup success
assert_status 0
reset_aws_calls
run_cleanup_with_mock delete-failure
assert_status 1
assert_contains "Route53 DNS record deletion failed"
assert_aws_error_redacted
assert_aws_operations "route53 change-resource-record-sets"
pass "cleanup keeps deletion failures fatal and sanitizes multiline AWS errors"

new_case cleanup-wait-failure
write_credentials
write_nutanix_context
run_setup success
assert_status 0
reset_aws_calls
run_cleanup_with_mock wait-failure
assert_status 1
assert_contains "waiting for Route53 DNS record deletion failed"
assert_aws_error_redacted
assert_aws_operations "${cleanup_operations}"
pass "cleanup keeps wait failures fatal and sanitizes multiline AWS errors"

echo "PASS: ${passed} Nutanix DNS smoke tests"
