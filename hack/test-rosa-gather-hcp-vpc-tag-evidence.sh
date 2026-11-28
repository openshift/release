#!/bin/bash
# Offline tests for the ROSA HCP VPC tag evidence collector.
# Run locally with: bash hack/test-rosa-gather-hcp-vpc-tag-evidence.sh
#
# Every case runs the real step entrypoint with `aws` and `oc` stubbed on PATH,
# so no cloud call is ever made. Any other network-capable client the step might
# grow is stubbed to fail the case. The cases cover the valid tag combinations,
# missing and malformed handoff input, an unparseable API response, guest and
# AWS API failures, region selection, the call bounds, the scope of the single
# AWS call, and redaction of identifiers and command stderr.
set -euo pipefail

script="$(dirname "$0")/../ci-operator/step-registry/rosa/gather/hcp-vpc-tag-evidence/rosa-gather-hcp-vpc-tag-evidence-commands.sh"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

# Identifiers and API text that must never reach stdout, stderr or artifacts.
readonly GUEST_NAME="ci-op-guestinfra-7x2k"
readonly CI_INFRA_ID="rosa-ci-clustername-9d4m"
readonly VPC_ID="vpc-0123456789abcdef0"
readonly SECRET_MARKER="SHOULDNOTAPPEAR"
readonly DEFAULT_REGION="us-west-2"
readonly TAG_PREFIX="kubernetes.io/cluster/"

# Every field the step is contracted to emit.
readonly FIELDS=(
    guest_infrastructure_name
    ci_infrastructure_identifier
    vpc_identifier
    infrastructure_name_match
    guest_owned_cluster_tag
    ci_shared_cluster_tag
)

failures=0

fail_case() {
    printf 'FAIL: %s: ' "$1" >&2
    shift
    # shellcheck disable=SC2059
    printf "$@" >&2
    printf '\n' >&2
    case_ok=0
}

# Builds the AWS describe-tags fixture from a list of "key=value" tag pairs,
# always including an unrelated tag carrying the redaction marker.
write_tags_fixture() {
    local out="$1"
    shift
    {
        printf '{"Tags":['
        printf '{"Key":"Name","Value":"%s-vpcname"}' "$SECRET_MARKER"
        local pair
        for pair in "$@"; do
            printf ',{"Key":"%s","Value":"%s"}' "${pair%%=*}" "${pair#*=}"
        done
        printf ']}\n'
    } >"$out"
}

make_stubs() {
    local bin="$1"
    mkdir -p "$bin"

    cat >"$bin/oc" <<'STUB'
#!/bin/bash
printf 'oc %s\n' "$*" >>"$CASE_DIR/oc_calls"
if [[ "$OC_MODE" == fail ]]; then
    printf 'error: %s-ocstderr\n' "$SECRET_MARKER" >&2
    exit 1
fi
if [[ "$OC_MODE" == timeout ]]; then
    exit 124
fi
printf '%s' "$OC_GUEST_NAME"
STUB

    cat >"$bin/aws" <<'STUB'
#!/bin/bash
printf 'aws %s\n' "$*" >>"$CASE_DIR/aws_calls"
case "$AWS_MODE" in
fail)
    printf 'An error occurred: %s-awsstderr\n' "$SECRET_MARKER" >&2
    printf '%s-awsstdout\n' "$SECRET_MARKER"
    exit 255
    ;;
malformed)
    # Exits 0 but the body is truncated, so the response cannot be parsed.
    printf '{"Tags":[{"Key":"%s' "$SECRET_MARKER"
    ;;
timeout)
    # 124 is the status `timeout` reports when it expires the client.
    exit 124
    ;;
*)
    cat "$CASE_DIR/tags.json"
    ;;
esac
STUB

    # The step must reach the cloud only through `aws` and `oc`. Any other
    # network client appearing on the call path fails the case instead of
    # silently escaping to the real network.
    local denied
    for denied in curl wget ocm rosa; do
        cat >"$bin/$denied" <<STUB
#!/bin/bash
printf '%s %s\n' "$denied" "\$*" >>"\$CASE_DIR/denied_calls"
exit 127
STUB
    done

    chmod +x "$bin"/*
}

# run_case <name> <oc_mode> <aws_mode> <vpc_id|-> <infra_id|-> <kubeconfig:yes|no> \
#          <expected_aws_calls> <expected_oc_calls> [<json_field>=<state> ...]
#
# Optional per-case globals, unset after use: case_guest_name, case_region,
# case_leased_resource, case_expected_keys.
run_case() {
    local name="$1" oc_mode="$2" aws_mode="$3" vpc_content="$4" infra_content="$5" \
        kubeconfig="$6" expected_aws_calls="$7" expected_oc_calls="$8"
    shift 8

    local case_dir="$test_dir/$name"
    local shared_dir="$case_dir/shared" artifact_dir="$case_dir/artifacts" \
        profile_dir="$case_dir/profile" bin="$case_dir/bin"
    mkdir -p "$shared_dir" "$artifact_dir" "$profile_dir"
    : >"$case_dir/aws_calls"
    : >"$case_dir/oc_calls"
    : >"$case_dir/denied_calls"
    make_stubs "$bin"

    if [[ "$vpc_content" != "-" ]]; then
        printf '%s\n' "$vpc_content" >"$shared_dir/vpc_id"
    fi
    if [[ "$infra_content" != "-" ]]; then
        printf '%s\n' "$infra_content" >"$shared_dir/infra_id"
    fi
    if [[ "$kubeconfig" == yes ]]; then
        printf 'apiVersion: v1\n' >"$shared_dir/kubeconfig"
    fi
    printf '[default]\naws_access_key_id = %s-key\n' "$SECRET_MARKER" >"$profile_dir/.awscred"

    # The step is read-only: the handoff directory must be byte-identical after.
    local before after
    before="$(find "$shared_dir" -type f -exec sha256sum {} + | sort)"

    local status=0
    (
        export PATH="$bin:$PATH"
        export CASE_DIR="$case_dir" OC_MODE="$oc_mode" AWS_MODE="$aws_mode"
        export SECRET_MARKER
        export OC_GUEST_NAME="${case_guest_name:-$GUEST_NAME}"
        export SHARED_DIR="$shared_dir" ARTIFACT_DIR="$artifact_dir" \
            CLUSTER_PROFILE_DIR="$profile_dir"
        export LEASED_RESOURCE="${case_leased_resource-$DEFAULT_REGION}"
        if [[ -n "${case_region+set}" ]]; then
            export REGION="$case_region"
        fi
        bash "$script"
    ) >"$case_dir/stdout" 2>"$case_dir/stderr" || status=$?

    after="$(find "$shared_dir" -type f -exec sha256sum {} + | sort)"

    local case_ok=1

    # The step is best-effort: it must always succeed.
    if [[ "$status" -ne 0 ]]; then
        fail_case "$name" 'expected exit 0, got %s' "$status"
    fi

    if [[ "$before" != "$after" ]]; then
        fail_case "$name" 'the step modified %s' "\${SHARED_DIR}"
    fi

    if [[ -s "$case_dir/denied_calls" ]]; then
        fail_case "$name" 'the step invoked a disallowed network client'
    fi

    # Calls are bounded, and none are made when the inputs cannot support them.
    local aws_calls oc_calls
    aws_calls="$(wc -l <"$case_dir/aws_calls" | tr -d ' ')"
    oc_calls="$(wc -l <"$case_dir/oc_calls" | tr -d ' ')"
    if [[ "$aws_calls" -ne "$expected_aws_calls" ]]; then
        fail_case "$name" 'expected %s AWS calls, got %s' "$expected_aws_calls" "$aws_calls"
    fi
    if [[ "$oc_calls" -ne "$expected_oc_calls" ]]; then
        fail_case "$name" 'expected %s oc calls, got %s' "$expected_oc_calls" "$oc_calls"
    fi

    # The single AWS call must be a read scoped to this VPC and to the expected
    # tag keys, in the expected region: no account-wide or fallback lookup.
    if [[ "$expected_aws_calls" -eq 1 && "$aws_calls" -eq 1 ]]; then
        local call expected_region
        call="$(cat "$case_dir/aws_calls")"
        expected_region="${case_region-${case_leased_resource-$DEFAULT_REGION}}"
        if [[ "$call" != *"ec2 describe-tags"* ]]; then
            fail_case "$name" 'AWS call was not ec2 describe-tags'
        fi
        if [[ "$call" != *"Name=resource-id,Values=${VPC_ID}"* ]]; then
            fail_case "$name" 'AWS call was not scoped to the handed-off VPC'
        fi
        if [[ "$call" != *"--region ${expected_region}"* ]]; then
            fail_case "$name" 'AWS call did not use region %s' "$expected_region"
        fi
        # describe-tags is paginated; the bound is one request, not one walk.
        if [[ "$call" != *"--no-paginate"* ]]; then
            fail_case "$name" 'AWS call did not disable pagination'
        fi
        if [[ -n "${case_expected_keys:-}" &&
            "$call" != *"Name=key,Values=${case_expected_keys}"* ]]; then
            fail_case "$name" 'AWS call did not filter on the expected tag keys'
        fi
    fi

    local artifact="$artifact_dir/hcp-vpc-tag-evidence.json"
    if [[ ! -s "$artifact" ]]; then
        fail_case "$name" 'evidence artifact was not written'
    else
        if [[ "$(jq -r '.schema_version' "$artifact")" != "1" ]]; then
            fail_case "$name" 'artifact schema_version is not 1'
        fi

        local expectation field want got
        for expectation in "$@"; do
            field="${expectation%%=*}"
            want="${expectation#*=}"
            got="$(jq -r --arg f "$field" '.[$f]' "$artifact")"
            if [[ "$got" != "$want" ]]; then
                fail_case "$name" '%s expected %s, got %s' "$field" "$want" "$got"
            fi
        done

        # Every field is reported on stdout with the same state as the artifact.
        for field in "${FIELDS[@]}"; do
            got="$(jq -r --arg f "$field" '.[$f]' "$artifact")"
            if ! grep -Fqx -- "${field}: ${got}" "$case_dir/stdout"; then
                fail_case "$name" 'stdout is missing "%s: %s"' "$field" "$got"
            fi
        done
    fi

    # Redaction: no identifier, tag text from data, or command stderr escapes.
    if grep -Eq "$SECRET_MARKER|$GUEST_NAME|$CI_INFRA_ID|$VPC_ID|kubernetes\.io/cluster/" \
        "$case_dir/stdout" "$case_dir/stderr" "$artifact" 2>/dev/null; then
        fail_case "$name" 'sensitive content leaked into output or artifact'
    fi

    if [[ "$case_ok" -eq 1 ]]; then
        printf 'PASS: %s\n' "$name"
    else
        failures=$((failures + 1))
    fi
    unset case_guest_name case_region case_leased_resource case_expected_keys
}

prepare_fixture() {
    local name="$1"
    shift
    mkdir -p "$test_dir/$name"
    write_tags_fixture "$test_dir/$name/tags.json" "$@"
}

# Writes a verbatim response body, for shapes write_tags_fixture cannot express.
prepare_raw_fixture() {
    local name="$1" body="$2"
    mkdir -p "$test_dir/$name"
    printf '%s' "$body" >"$test_dir/$name/tags.json"
}

# Direct check of the closed-set guard that backs the redaction contract: it is
# unreachable with bad input through the entrypoint by design, so it is
# exercised on its own.
test_sanitize_state() {
    local case_ok=1 value got
    # shellcheck source=/dev/null
    source <(sed -n '/^sanitize_state() {$/,/^}$/p' "$script")

    for value in available unavailable match differ present absent; do
        got="$(sanitize_state "$value")"
        if [[ "$got" != "$value" ]]; then
            fail_case sanitize-state 'valid state %s was rewritten to %s' "$value" "$got"
        fi
    done

    for value in "" "$VPC_ID" "$GUEST_NAME" "$TAG_PREFIX$CI_INFRA_ID" "owned" "true"; do
        got="$(sanitize_state "$value")"
        if [[ "$got" != unavailable ]]; then
            fail_case sanitize-state 'unexpected value was not redacted (got %s)' "$got"
        fi
    done

    if [[ "$case_ok" -eq 1 ]]; then
        printf 'PASS: %s\n' sanitize-state
    else
        failures=$((failures + 1))
    fi
}

owned_tag="${TAG_PREFIX}${GUEST_NAME}=owned"
shared_tag="${TAG_PREFIX}${CI_INFRA_ID}=shared"
equal_owned_tag="${TAG_PREFIX}${CI_INFRA_ID}=owned"
both_keys="${TAG_PREFIX}${GUEST_NAME},${TAG_PREFIX}${CI_INFRA_ID}"
guest_key="${TAG_PREFIX}${GUEST_NAME}"
ci_key="${TAG_PREFIX}${CI_INFRA_ID}"

# Valid tag combinations.
prepare_fixture both-tags-present "$owned_tag" "$shared_tag"
case_expected_keys="$both_keys"
run_case both-tags-present ok ok "$VPC_ID" "$CI_INFRA_ID" yes 1 1 \
    guest_infrastructure_name=available ci_infrastructure_identifier=available \
    vpc_identifier=available infrastructure_name_match=differ \
    guest_owned_cluster_tag=present ci_shared_cluster_tag=present

prepare_fixture guest-owned-tag-absent "$shared_tag"
case_expected_keys="$both_keys"
run_case guest-owned-tag-absent ok ok "$VPC_ID" "$CI_INFRA_ID" yes 1 1 \
    infrastructure_name_match=differ \
    guest_owned_cluster_tag=absent ci_shared_cluster_tag=present

prepare_fixture no-cluster-tags
case_expected_keys="$both_keys"
run_case no-cluster-tags ok ok "$VPC_ID" "$CI_INFRA_ID" yes 1 1 \
    guest_owned_cluster_tag=absent ci_shared_cluster_tag=absent

# Both handoffs name the same string: one key, "owned" present, "shared" absent.
prepare_fixture names-equal "$equal_owned_tag"
case_guest_name="$CI_INFRA_ID"
case_expected_keys="$ci_key"
run_case names-equal ok ok "$VPC_ID" "$CI_INFRA_ID" yes 1 1 \
    infrastructure_name_match=match \
    guest_owned_cluster_tag=present ci_shared_cluster_tag=absent

# Missing input.
prepare_fixture missing-vpc-id "$owned_tag" "$shared_tag"
run_case missing-vpc-id ok ok - "$CI_INFRA_ID" yes 0 1 \
    vpc_identifier=unavailable guest_owned_cluster_tag=unavailable \
    ci_shared_cluster_tag=unavailable infrastructure_name_match=differ

prepare_fixture missing-kubeconfig "$shared_tag"
case_expected_keys="$ci_key"
run_case missing-kubeconfig ok ok "$VPC_ID" "$CI_INFRA_ID" no 1 0 \
    guest_infrastructure_name=unavailable infrastructure_name_match=unavailable \
    guest_owned_cluster_tag=unavailable ci_shared_cluster_tag=present

prepare_fixture missing-infra-id "$owned_tag"
case_expected_keys="$guest_key"
run_case missing-infra-id ok ok "$VPC_ID" - yes 1 1 \
    ci_infrastructure_identifier=unavailable infrastructure_name_match=unavailable \
    guest_owned_cluster_tag=present ci_shared_cluster_tag=unavailable

prepare_fixture missing-everything
run_case missing-everything ok ok - - no 0 0 \
    guest_infrastructure_name=unavailable ci_infrastructure_identifier=unavailable \
    vpc_identifier=unavailable infrastructure_name_match=unavailable \
    guest_owned_cluster_tag=unavailable ci_shared_cluster_tag=unavailable

# Malformed input must be rejected before it reaches the API.
prepare_fixture malformed-vpc-id "$owned_tag" "$shared_tag"
# The single quotes are deliberate: the handoff file must contain the literal
# substitution text so the collector is shown rejecting it unexpanded.
# shellcheck disable=SC2016
run_case malformed-vpc-id ok ok 'not-a-vpc$(id)' "$CI_INFRA_ID" yes 0 1 \
    vpc_identifier=unavailable guest_owned_cluster_tag=unavailable \
    ci_shared_cluster_tag=unavailable

prepare_fixture malformed-infra-id "$owned_tag"
case_expected_keys="$guest_key"
run_case malformed-infra-id ok ok "$VPC_ID" 'bad id/with,separators' yes 1 1 \
    ci_infrastructure_identifier=unavailable infrastructure_name_match=unavailable \
    ci_shared_cluster_tag=unavailable guest_owned_cluster_tag=present

# Region selection.
prepare_fixture region-override "$owned_tag" "$shared_tag"
case_region="eu-central-1"
case_expected_keys="$both_keys"
run_case region-override ok ok "$VPC_ID" "$CI_INFRA_ID" yes 1 1 \
    guest_owned_cluster_tag=present ci_shared_cluster_tag=present

# With no region at all there is nothing to query, so no call is attempted.
prepare_fixture region-unavailable "$owned_tag" "$shared_tag"
case_region=""
case_leased_resource=""
run_case region-unavailable ok ok "$VPC_ID" "$CI_INFRA_ID" yes 0 1 \
    vpc_identifier=available guest_owned_cluster_tag=unavailable \
    ci_shared_cluster_tag=unavailable

# API failures degrade to unavailable without failing the step.
prepare_fixture aws-failure "$owned_tag" "$shared_tag"
case_expected_keys="$both_keys"
run_case aws-failure ok fail "$VPC_ID" "$CI_INFRA_ID" yes 1 1 \
    guest_infrastructure_name=available ci_infrastructure_identifier=available \
    vpc_identifier=available infrastructure_name_match=differ \
    guest_owned_cluster_tag=unavailable ci_shared_cluster_tag=unavailable

# A successful call whose body cannot be parsed determined nothing, so the tag
# states must stay "unavailable" and must never be reported as "absent".
prepare_fixture malformed-api-response
case_expected_keys="$both_keys"
run_case malformed-api-response ok malformed "$VPC_ID" "$CI_INFRA_ID" yes 1 1 \
    guest_infrastructure_name=available ci_infrastructure_identifier=available \
    vpc_identifier=available infrastructure_name_match=differ \
    guest_owned_cluster_tag=unavailable ci_shared_cluster_tag=unavailable

prepare_fixture oc-failure "$shared_tag"
case_expected_keys="$ci_key"
run_case oc-failure fail ok "$VPC_ID" "$CI_INFRA_ID" yes 1 1 \
    guest_infrastructure_name=unavailable infrastructure_name_match=unavailable \
    guest_owned_cluster_tag=unavailable ci_shared_cluster_tag=present

prepare_fixture both-apis-failing
run_case both-apis-failing fail fail "$VPC_ID" "$CI_INFRA_ID" yes 1 1 \
    guest_infrastructure_name=unavailable guest_owned_cluster_tag=unavailable \
    ci_shared_cluster_tag=unavailable

# The expected key is present but carries the other value: the step compares
# key AND value, so this must read as absent rather than present.
prepare_fixture wrong-tag-value "${TAG_PREFIX}${GUEST_NAME}=shared" "${TAG_PREFIX}${CI_INFRA_ID}=owned"
case_expected_keys="$both_keys"
run_case wrong-tag-value ok ok "$VPC_ID" "$CI_INFRA_ID" yes 1 1 \
    guest_owned_cluster_tag=absent ci_shared_cluster_tag=absent \
    infrastructure_name_match=differ

# A client killed by the call bound is "unavailable", never "absent".
prepare_fixture api-timeout
case_expected_keys="$both_keys"
run_case api-timeout ok timeout "$VPC_ID" "$CI_INFRA_ID" yes 1 1 \
    guest_infrastructure_name=available vpc_identifier=available \
    guest_owned_cluster_tag=unavailable ci_shared_cluster_tag=unavailable

prepare_fixture guest-api-timeout "$shared_tag"
case_expected_keys="$ci_key"
run_case guest-api-timeout timeout ok "$VPC_ID" "$CI_INFRA_ID" yes 1 1 \
    guest_infrastructure_name=unavailable infrastructure_name_match=unavailable \
    guest_owned_cluster_tag=unavailable ci_shared_cluster_tag=present

# A response that parses as JSON but is not the documented shape determined
# nothing. Reporting it as "absent" would be a false negative, because the
# match below cannot tell a wrong shape from a genuine miss.
prepare_raw_fixture valid-json-no-tags-key '{}'
case_expected_keys="$both_keys"
run_case valid-json-no-tags-key ok ok "$VPC_ID" "$CI_INFRA_ID" yes 1 1 \
    guest_infrastructure_name=available vpc_identifier=available \
    guest_owned_cluster_tag=unavailable ci_shared_cluster_tag=unavailable

prepare_raw_fixture valid-json-tags-null '{"Tags":null}'
case_expected_keys="$both_keys"
run_case valid-json-tags-null ok ok "$VPC_ID" "$CI_INFRA_ID" yes 1 1 \
    guest_infrastructure_name=available vpc_identifier=available \
    guest_owned_cluster_tag=unavailable ci_shared_cluster_tag=unavailable

prepare_raw_fixture valid-json-tags-not-array '{"Tags":"oops"}'
case_expected_keys="$both_keys"
run_case valid-json-tags-not-array ok ok "$VPC_ID" "$CI_INFRA_ID" yes 1 1 \
    guest_infrastructure_name=available vpc_identifier=available \
    guest_owned_cluster_tag=unavailable ci_shared_cluster_tag=unavailable

prepare_raw_fixture valid-json-entry-not-object '{"Tags":[1,2,3]}'
case_expected_keys="$both_keys"
run_case valid-json-entry-not-object ok ok "$VPC_ID" "$CI_INFRA_ID" yes 1 1 \
    guest_infrastructure_name=available vpc_identifier=available \
    guest_owned_cluster_tag=unavailable ci_shared_cluster_tag=unavailable

prepare_raw_fixture valid-json-entry-no-value \
    "{\"Tags\":[{\"Key\":\"${TAG_PREFIX}${GUEST_NAME}\"}]}"
case_expected_keys="$both_keys"
run_case valid-json-entry-no-value ok ok "$VPC_ID" "$CI_INFRA_ID" yes 1 1 \
    guest_infrastructure_name=available vpc_identifier=available \
    guest_owned_cluster_tag=unavailable ci_shared_cluster_tag=unavailable

prepare_raw_fixture valid-json-value-not-string \
    "{\"Tags\":[{\"Key\":\"${TAG_PREFIX}${GUEST_NAME}\",\"Value\":5}]}"
case_expected_keys="$both_keys"
run_case valid-json-value-not-string ok ok "$VPC_ID" "$CI_INFRA_ID" yes 1 1 \
    guest_infrastructure_name=available vpc_identifier=available \
    guest_owned_cluster_tag=unavailable ci_shared_cluster_tag=unavailable

prepare_raw_fixture multiple-json-documents '{"Tags":[]} {"Tags":[]}'
case_expected_keys="$both_keys"
run_case multiple-json-documents ok ok "$VPC_ID" "$CI_INFRA_ID" yes 1 1 \
    guest_infrastructure_name=available vpc_identifier=available \
    guest_owned_cluster_tag=unavailable ci_shared_cluster_tag=unavailable

# A non-object top-level document is not a response at all.
prepare_raw_fixture top-level-not-object '[]'
case_expected_keys="$both_keys"
run_case top-level-not-object ok ok "$VPC_ID" "$CI_INFRA_ID" yes 1 1 \
    guest_owned_cluster_tag=unavailable ci_shared_cluster_tag=unavailable

prepare_raw_fixture key-not-string \
    "{\"Tags\":[{\"Key\":5,\"Value\":\"owned\"}]}"
case_expected_keys="$both_keys"
run_case key-not-string ok ok "$VPC_ID" "$CI_INFRA_ID" yes 1 1 \
    guest_owned_cluster_tag=unavailable ci_shared_cluster_tag=unavailable

# A truncated page has not shown that a missing tag is really missing.
prepare_raw_fixture truncated-response \
    "{\"Tags\":[{\"Key\":\"${TAG_PREFIX}${CI_INFRA_ID}\",\"ResourceId\":\"${VPC_ID}\",\"ResourceType\":\"vpc\",\"Value\":\"shared\"}],\"NextToken\":\"eyJ2IjoiMiJ9\"}"
case_expected_keys="$both_keys"
run_case truncated-response ok ok "$VPC_ID" "$CI_INFRA_ID" yes 1 1 \
    guest_owned_cluster_tag=unavailable ci_shared_cluster_tag=unavailable

# The shape gate must not over-reject: an empty Tags array is well formed and
# is exactly what a VPC carrying neither tag returns, so it is a real absence.
prepare_raw_fixture empty-tags-array '{"Tags":[]}'
case_expected_keys="$both_keys"
run_case empty-tags-array ok ok "$VPC_ID" "$CI_INFRA_ID" yes 1 1 \
    guest_owned_cluster_tag=absent ci_shared_cluster_tag=absent

# A response shaped the way EC2 actually returns one -- entries carrying
# ResourceId/ResourceType -- must be classified, not rejected by the gate.
prepare_raw_fixture realistic-aws-response \
    "{\"Tags\":[{\"Key\":\"${TAG_PREFIX}${GUEST_NAME}\",\"ResourceId\":\"${VPC_ID}\",\"ResourceType\":\"vpc\",\"Value\":\"owned\"},{\"Key\":\"${TAG_PREFIX}${CI_INFRA_ID}\",\"ResourceId\":\"${VPC_ID}\",\"ResourceType\":\"vpc\",\"Value\":\"shared\"}]}"
case_expected_keys="$both_keys"
run_case realistic-aws-response ok ok "$VPC_ID" "$CI_INFRA_ID" yes 1 1 \
    infrastructure_name_match=differ \
    guest_owned_cluster_tag=present ci_shared_cluster_tag=present

test_sanitize_state

if [[ "$failures" -ne 0 ]]; then
    printf '\n%s case(s) failed\n' "$failures" >&2
    exit 1
fi
printf '\nAll cases passed\n'
