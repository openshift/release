#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
commands="${repo_root}/ci-operator/step-registry/aks/provision/aks-provision-commands.sh"
workdir="$(mktemp -d)"
trap 'rm -rf -- "${workdir}"' EXIT
real_jq="$(command -v jq)"

awk '
    /# BEGIN NAP FAILURE ARTIFACT COLLECTOR/ { copy = 1; next }
    /# END NAP FAILURE ARTIFACT COLLECTOR/ { copy = 0 }
    copy
' "${commands}" > "${workdir}/collector.sh"
# shellcheck source=/dev/null
source "${workdir}/collector.sh"

mkdir -p "${workdir}/bin" "${workdir}/fixtures"
mkdir -p "${workdir}/private-tmp"
export TMPDIR="${workdir}/private-tmp"
cat > "${workdir}/bin/oc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${MOCK_FAIL_ALL:-}" == "true" ]]; then
    printf 'SENSITIVE_MARKER\n' >&2
    exit 1
fi
case " $* " in
    *" get nodeclaims.karpenter.sh "*) file=nodeclaims.json ;;
    *" get events -A "*) file=karpenter-events.json ;;
    *" get events -n default "*) file=scheduler-events.json ;;
    *" get pods -n default "*) file=placeholder-pods.json ;;
    *" get nodes "*) file=nodes.json ;;
    *) exit 2 ;;
esac
if [[ "${MOCK_HANG_FILE:-}" == "${file}" ]] \
    || [[ ",${MOCK_HANG_FILES:-}," == *",${file},"* ]]; then
    trap '' TERM
    while true; do
        sleep 1
    done
fi
if [[ "${MOCK_EMIT_STDERR:-}" == "true" ]]; then
    printf 'SENSITIVE_MARKER private@example.com token-secret-value\n' >&2
fi
cp "${FIXTURE_DIR}/${file}" /dev/stdout
EOF
chmod +x "${workdir}/bin/oc"
cat > "${workdir}/bin/jq" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${MOCK_HANG_JQ:-}" == "true" ]]; then
    trap '' TERM
    while true; do
        sleep 1
    done
fi
exec "${REAL_JQ}" "$@"
EOF
chmod +x "${workdir}/bin/jq"
export REAL_JQ="${real_jq}"
export PATH="${workdir}/bin:${PATH}"
export FIXTURE_DIR="${workdir}/fixtures"

write_empty_fixtures() {
    local file
    for file in nodeclaims karpenter-events scheduler-events placeholder-pods nodes; do
        printf '{"items":[]}\n' > "${FIXTURE_DIR}/${file}.json"
    done
}

run_collector() {
    local log="$2"
    local with_xtrace="${3:-false}"
    ARTIFACT_DIR="$1"
    mkdir -p "${ARTIFACT_DIR}"
    if [[ "${with_xtrace}" == "true" ]]; then
        : >"${log}"
        exec 9>>"${log}"
        BASH_XTRACEFD=9
        set -x
        collect_nap_failure_artifacts >>"${log}" 2>&1
        [[ $- == *x* ]]
        set +x
        unset BASH_XTRACEFD
        exec 9>&-
    else
        collect_nap_failure_artifacts >"${log}" 2>&1
        [[ $- != *x* ]]
    fi
}

assert_sanitized() {
    local artifacts="$1"
    local log="$2"
    local marker
    for marker in SENSITIVE_MARKER private@example.com tenant-deadbeef token-secret-value "${TMPDIR}"; do
        if grep -R -F -q -- "${marker}" "${artifacts}" "${log}"; then
            echo "private input or capture path escaped into diagnostics: ${marker}" >&2
            return 1
        fi
    done
}

assert_jq() {
    local expression="$1"
    local file="$2"
    jq -e "${expression}" "${file}" >/dev/null
}

assert_summary_value() {
    local key="$1"
    local expected="$2"
    local file="$3"
    grep -F -x -q -- "${key}=${expected}" "${file}"
}

test_expected_rejection_and_resource_state() {
    local artifacts="${workdir}/expected"
    local log="${workdir}/expected.log"
    write_empty_fixtures
    cat > "${FIXTURE_DIR}/nodeclaims.json" <<'EOF'
{"items":[{"metadata":{"name":"SENSITIVE_MARKER","annotations":{"email":"private@example.com","token":"token-secret-value"}},"status":{"conditions":[{"type":"Ready","status":"False","reason":"NoCompatibleInstanceTypes","message":"no instance type satisfied resources and requirements karpenter.azure.com/sku-name In [Standard_D16s_v5, Standard_E16s_v5, Standard_SENSITIVE_MARKER], karpenter.azure.com/sku-family In [D, tenant-deadbeef], karpenter.azure.com/sku-cpu In [16, 1234SENSITIVE_MARKER], karpenter.azure.com/sku-version In [5, 6SENSITIVE_MARKER], kubernetes.io/arch In [amd64, arm64SENSITIVE_MARKER], kubernetes.io/os In [linux, private@example.com], karpenter.sh/capacity-type In [on-demand, token-secret-value]; SENSITIVE_MARKER"}]}}]}
EOF
    cat > "${FIXTURE_DIR}/scheduler-events.json" <<'EOF'
{"items":[{"type":"Warning","reason":"FailedScheduling","source":{"component":"default-scheduler"},"involvedObject":{"kind":"Pod","name":"nap-placeholder-SENSITIVE_MARKER"},"message":"0/3 nodes are available: 3 Insufficient cpu, 1 Insufficient memory, 1 Too many pods, 2 node(s) didn't match Pod's node affinity/selector, 1 node(s) had untolerated taint SENSITIVE_MARKER"},{"type":"Normal","reason":"Scheduled","source":{"component":"default-scheduler"},"involvedObject":{"kind":"Pod","name":"nap-placeholder-decoy"},"message":"Successfully assigned private@example.com"},{"type":"Warning","reason":"FailedScheduling","source":{"component":"default-scheduler"},"involvedObject":{"kind":"Pod","name":"unrelated-pod"},"message":"Insufficient cpu token-secret-value"},{"type":"Warning","reason":"SchedulerNoise","reportingController":"custom-scheduler","involvedObject":{"kind":"Pod","name":"nap-placeholder-decoy"},"message":"Insufficient memory tenant-deadbeef"}]}
EOF
    cat > "${FIXTURE_DIR}/placeholder-pods.json" <<'EOF'
{"items":[{"metadata":{"name":"nap-placeholder-SENSITIVE_MARKER","annotations":{"arbitrary":"SENSITIVE_MARKER"}},"spec":{"containers":[{"resources":{"requests":{"cpu":"14","memory":"56Gi"}}}]},"status":{"phase":"Pending"}},{"metadata":{"name":"nap-placeholder-other"},"spec":{"nodeName":"SENSITIVE_MARKER","containers":[{"resources":{"requests":{"cpu":"14","memory":"56Gi"}}}]},"status":{"phase":"Running"}},{"metadata":{"name":"nap-placeholder-invalid"},"spec":{"containers":[{"resources":{"requests":{"cpu":"14SENSITIVE_MARKER","memory":"private@example.com"}}}]},"status":{"phase":"Pending"}}]}
EOF
    cat > "${FIXTURE_DIR}/nodes.json" <<'EOF'
{"items":[{"metadata":{"name":"SENSITIVE_MARKER","labels":{"arbitrary":"SENSITIVE_MARKER"}},"spec":{},"status":{"allocatable":{"cpu":"15850m","memory":"60Gi","pods":"250"},"conditions":[{"type":"Ready","status":"True"}]}},{"metadata":{"name":"other"},"spec":{"unschedulable":true},"status":{"allocatable":{"cpu":"15850m","memory":"60Gi","pods":"250"},"conditions":[{"type":"Ready","status":"False"}]}}]}
EOF

    MOCK_EMIT_STDERR=true run_collector "${artifacts}" "${log}" true
    local details="${artifacts}/nap-failure-details.json"
    local summary="${artifacts}/nap-failure-summary.txt"
    assert_jq '.schema_version == 2 and .collection_limits.max_collector_seconds == 15 and .no_instance_type_rejections.observed_message_total == 1 and .no_instance_type_rejections.messages_truncated == false' "${details}"
    assert_jq '.no_instance_type_rejections.requirements.sku_name == {values:["Standard_D16s_v5","Standard_E16s_v5"],total:2,truncated:false}' "${details}"
    assert_jq '.no_instance_type_rejections.requirements.sku_family.values == ["D"] and .no_instance_type_rejections.requirements.sku_cpu.values == ["16"] and .no_instance_type_rejections.requirements.sku_version.values == ["5"]' "${details}"
    assert_jq '.no_instance_type_rejections.requirements.architecture.values == ["amd64"] and .no_instance_type_rejections.requirements.operating_system.values == ["linux"] and .no_instance_type_rejections.requirements.capacity_type.values == ["on-demand"]' "${details}"
    assert_jq '.scheduler_rejections.failed_scheduling_event_total == 1 and .scheduler_rejections.insufficient_cpu_event_count == 1 and .scheduler_rejections.insufficient_memory_event_count == 1 and .scheduler_rejections.too_many_pods_event_count == 1 and .scheduler_rejections.node_affinity_mismatch_event_count == 1 and .scheduler_rejections.untolerated_taint_event_count == 1' "${details}"
    assert_jq '.placeholder_pods.total == 3 and .placeholder_pods.request_profile_total == 1 and .placeholder_pods.request_profiles == [{cpu:"14",memory:"56Gi",container_count:2}]' "${details}"
    assert_jq '.nodes.total == 2 and .nodes.ready == 1 and .nodes.schedulable == 1 and (.nodes.allocatable_profiles | length == 2) and any(.nodes.allocatable_profiles[]; .ready == true and .schedulable == true and .node_count == 1) and any(.nodes.allocatable_profiles[]; .ready == false and .schedulable == false and .node_count == 1)' "${details}"
    assert_summary_value metrics_available true "${summary}"
    assert_summary_value nodeclaims_available true "${summary}"
    assert_summary_value karpenter_events_available true "${summary}"
    assert_summary_value scheduler_events_available true "${summary}"
    assert_summary_value placeholder_pods_available true "${summary}"
    assert_summary_value nodes_available true "${summary}"
    assert_summary_value details_available true "${summary}"
    assert_summary_value scheduler_event_count 1 "${summary}"
    assert_summary_value scheduler_event_type_Warning_count 1 "${summary}"
    assert_summary_value scheduler_event_type_Normal_count 0 "${summary}"
    assert_summary_value condition_Ready_False_count 1 "${summary}"
    assert_summary_value category_no_instance_type 1 "${summary}"
    assert_summary_value category_scheduling_constraint 1 "${summary}"
    assert_sanitized "${artifacts}" "${log}"
}

test_karpenter_event_only_constraints() {
    local artifacts="${workdir}/karpenter-only"
    local log="${workdir}/karpenter-only.log"
    write_empty_fixtures
    cat > "${FIXTURE_DIR}/karpenter-events.json" <<'EOF'
{"items":[{"type":"Warning","reason":"Failed","metadata":{"annotations":{"private":"SENSITIVE_MARKER"}},"message":"no available instance type satisfies karpenter.azure.com/sku-name In [Standard_D16s_v6], karpenter.azure.com/sku-family In [E], kubernetes.io/arch In [arm64], kubernetes.io/os In [windows], karpenter.sh/capacity-type In [spot] token-secret-value"}]}
EOF
    run_collector "${artifacts}" "${log}"
    assert_jq '.no_instance_type_rejections.observed_message_total == 1 and .no_instance_type_rejections.requirements.sku_name.values == ["Standard_D16s_v6"] and .no_instance_type_rejections.requirements.sku_family.values == ["E"] and .no_instance_type_rejections.requirements.architecture.values == ["arm64"] and .no_instance_type_rejections.requirements.operating_system.values == ["windows"] and .no_instance_type_rejections.requirements.capacity_type.values == ["spot"]' "${artifacts}/nap-failure-details.json"
    assert_sanitized "${artifacts}" "${log}"
}

test_malformed_and_unavailable_inputs() {
    local malformed_artifacts="${workdir}/malformed"
    local nested_artifacts="${workdir}/malformed-nested"
    local unavailable_artifacts="${workdir}/unavailable"
    local malformed_log="${workdir}/malformed.log"
    local nested_log="${workdir}/malformed-nested.log"
    local unavailable_log="${workdir}/unavailable.log"
    write_empty_fixtures
    printf 'not-json SENSITIVE_MARKER\n' > "${FIXTURE_DIR}/scheduler-events.json"
    printf '{"items":["SENSITIVE_MARKER",{"status":{"conditions":"private@example.com"}}]}\n' > "${FIXTURE_DIR}/nodeclaims.json"
    run_collector "${malformed_artifacts}" "${malformed_log}"
    assert_jq '.source_availability.scheduler_events == false and .source_availability.nodeclaims == false and .scheduler_rejections.failed_scheduling_event_total == 0' "${malformed_artifacts}/nap-failure-details.json"
    assert_sanitized "${malformed_artifacts}" "${malformed_log}"

    write_empty_fixtures
    cat > "${FIXTURE_DIR}/nodeclaims.json" <<'EOF'
{"items":[{"status":"SENSITIVE_MARKER"},{"status":{"conditions":"token-secret-value"}},{"status":{"conditions":["private@example.com",{"type":"Ready","status":"False","message":"no instance type satisfied karpenter.azure.com/sku-name In [Standard_D16s_v5] SENSITIVE_MARKER"}]}}]}
EOF
    cat > "${FIXTURE_DIR}/scheduler-events.json" <<'EOF'
{"items":[{"type":"Warning","reason":"FailedScheduling","involvedObject":"token-secret-value","message":"Insufficient memory private@example.com"},{"type":"Warning","reason":"FailedScheduling","involvedObject":{"kind":"Pod","name":"nap-placeholder-SENSITIVE_MARKER"},"message":"Insufficient cpu tenant-deadbeef"}]}
EOF
    cat > "${FIXTURE_DIR}/placeholder-pods.json" <<'EOF'
{"items":[{"metadata":"SENSITIVE_MARKER","spec":{},"status":{}},{"metadata":{"name":"nap-placeholder-malformed-spec"},"spec":"private@example.com","status":{"phase":"Pending"}},{"metadata":{"name":"nap-placeholder-malformed-containers"},"spec":{"containers":"tenant-deadbeef"},"status":{}},{"metadata":{"name":"nap-placeholder-valid-profile"},"spec":{"containers":["SENSITIVE_MARKER",{"resources":"token-secret-value"},{"resources":{"requests":"tenant-deadbeef"}},{"resources":{"requests":{"cpu":"14","memory":"56Gi"}}}]},"status":"private@example.com"}]}
EOF
    cat > "${FIXTURE_DIR}/nodes.json" <<'EOF'
{"items":[{"spec":"token-secret-value","status":"SENSITIVE_MARKER"},{"spec":{},"status":{"conditions":"private@example.com","allocatable":"tenant-deadbeef"}},{"spec":{},"status":{"conditions":["SENSITIVE_MARKER",{"type":"Ready","status":"True"}]}},{"spec":{"unschedulable":false},"status":{"conditions":[{"type":"Ready","status":"True"}],"allocatable":{"cpu":"15850m","memory":"60Gi","pods":"250"}}}]}
EOF
    run_collector "${nested_artifacts}" "${nested_log}"
    local nested_details="${nested_artifacts}/nap-failure-details.json"
    local nested_summary="${nested_artifacts}/nap-failure-summary.txt"
    assert_jq '[.source_availability[]] | all' "${nested_details}"
    assert_jq '.no_instance_type_rejections.observed_message_total == 1 and .no_instance_type_rejections.requirements.sku_name.values == ["Standard_D16s_v5"]' "${nested_details}"
    assert_jq '.scheduler_rejections.failed_scheduling_event_total == 1 and .scheduler_rejections.insufficient_cpu_event_count == 1 and .scheduler_rejections.insufficient_memory_event_count == 0' "${nested_details}"
    assert_jq '.placeholder_pods.total == 3 and .placeholder_pods.pending == 1 and .placeholder_pods.request_profile_total == 1 and .placeholder_pods.request_profiles == [{cpu:"14",memory:"56Gi",container_count:1}]' "${nested_details}"
    assert_jq '.nodes.total == 4 and .nodes.ready == 2 and .nodes.schedulable == 4 and .nodes.allocatable_profile_total == 1 and .nodes.allocatable_profiles == [{ready:true,schedulable:true,cpu:"15850m",memory:"60Gi",pods:"250",node_count:1}]' "${nested_details}"
    assert_summary_value metrics_available true "${nested_summary}"
    assert_summary_value details_available true "${nested_summary}"
    assert_summary_value scheduler_event_count 1 "${nested_summary}"
    assert_summary_value condition_Ready_False_count 1 "${nested_summary}"
    assert_summary_value category_no_instance_type 1 "${nested_summary}"
    assert_sanitized "${nested_artifacts}" "${nested_log}"

    write_empty_fixtures
    MOCK_FAIL_ALL=true run_collector "${unavailable_artifacts}" "${unavailable_log}"
    assert_jq '[.source_availability[]] | all(. == false)' "${unavailable_artifacts}/nap-failure-details.json"
    assert_jq '.placeholder_pods.total == 0 and .nodes.total == 0' "${unavailable_artifacts}/nap-failure-details.json"
    assert_summary_value metrics_available true "${unavailable_artifacts}/nap-failure-summary.txt"
    assert_summary_value nodeclaims_available false "${unavailable_artifacts}/nap-failure-summary.txt"
    assert_summary_value karpenter_events_available false "${unavailable_artifacts}/nap-failure-summary.txt"
    assert_summary_value scheduler_events_available false "${unavailable_artifacts}/nap-failure-summary.txt"
    assert_summary_value placeholder_pods_available false "${unavailable_artifacts}/nap-failure-summary.txt"
    assert_summary_value nodes_available false "${unavailable_artifacts}/nap-failure-summary.txt"
    assert_summary_value details_available true "${unavailable_artifacts}/nap-failure-summary.txt"
    assert_summary_value scheduler_event_count 0 "${unavailable_artifacts}/nap-failure-summary.txt"
    assert_sanitized "${unavailable_artifacts}" "${unavailable_log}"
}

test_output_bounds_and_best_effort_status() {
    local artifacts="${workdir}/bounded"
    local log="${workdir}/bounded.log"
    local oversized_artifacts="${workdir}/oversized"
    local oversized_log="${workdir}/oversized.log"
    write_empty_fixtures
    jq -cn '{items: [range(0; 100) as $i | {status:{conditions:[{message:(if $i < 64 then "no instance type satisfied karpenter.azure.com/sku-name In [Standard_D16s_v5, Standard_D16s_v6, Standard_D16s_v7, Standard_SENSITIVE_MARKER] SENSITIVE_MARKER" else "no instance type satisfied karpenter.azure.com/sku-name In [Standard_E16s_v5] token-secret-value" end)}]}}]}' > "${FIXTURE_DIR}/nodeclaims.json"
    jq -cn '{items: [range(0; 100) | {type:"Warning",reason:"FailedScheduling",involvedObject:{kind:"Pod",name:("nap-placeholder-" + (.|tostring))},message:"Insufficient cpu SENSITIVE_MARKER"}]}' > "${FIXTURE_DIR}/scheduler-events.json"
    jq -cn '{items: [range(0; 20) as $i | {metadata:{name:("nap-placeholder-" + ($i | tostring))},spec:{containers:[{resources:{requests:{cpu:(($i + 1) | tostring),memory:((($i + 1) | tostring) + "Gi")}}}]},status:{phase:"Pending"}}]}' > "${FIXTURE_DIR}/placeholder-pods.json"
    jq -cn '{items: [range(0; 20) as $i | {spec:{},status:{allocatable:{cpu:(($i + 1) | tostring),memory:((($i + 1) | tostring) + "Gi"),pods:"250"},conditions:[]}}]}' > "${FIXTURE_DIR}/nodes.json"

    run_collector "${artifacts}" "${log}"
    local details="${artifacts}/nap-failure-details.json"
    assert_jq '.no_instance_type_rejections.observed_message_total == 100 and .no_instance_type_rejections.sampled_message_count == 64 and .no_instance_type_rejections.messages_truncated == true' "${details}"
    assert_jq '.no_instance_type_rejections.requirements.sku_name == {values:["Standard_D16s_v5","Standard_D16s_v6","Standard_D16s_v7","Standard_E16s_v5"],total:4,truncated:false}' "${details}"
    assert_jq '.scheduler_rejections.failed_scheduling_event_total == 100 and .scheduler_rejections.sampled_event_count == 64 and .scheduler_rejections.events_truncated == true and .scheduler_rejections.insufficient_cpu_event_count == 100' "${details}"
    assert_jq '.placeholder_pods.request_profile_total == 20 and .placeholder_pods.request_profiles_truncated == true and (.placeholder_pods.request_profiles | length == 8)' "${details}"
    assert_jq '.nodes.allocatable_profile_total == 20 and .nodes.allocatable_profiles_truncated == true and (.nodes.allocatable_profiles | length == 8)' "${details}"
    (( $(wc -c < "${details}") <= 32769 ))
    assert_sanitized "${artifacts}" "${log}"

    write_empty_fixtures
    head -c 300000 /dev/zero | tr '\0' X | jq -Rs '{items:[{message:.}]}' > "${FIXTURE_DIR}/nodeclaims.json"
    jq -cn '{items:[range(0;257) | {}]}' > "${FIXTURE_DIR}/karpenter-events.json"
    run_collector "${oversized_artifacts}" "${oversized_log}"
    assert_jq '.source_availability.nodeclaims == false and .source_availability.karpenter_events == false and .no_instance_type_rejections.observed_message_total == 0' "${oversized_artifacts}/nap-failure-details.json"
    assert_sanitized "${oversized_artifacts}" "${oversized_log}"
}

test_hard_deadline_and_unwritable_artifacts() {
    local early_artifacts="${workdir}/early-deadline"
    local artifacts="${workdir}/deadline"
    local parser_artifacts="${workdir}/parser-deadline"
    local early_log="${workdir}/early-deadline.log"
    local log="${workdir}/deadline.log"
    local parser_log="${workdir}/parser-deadline.log"
    local unwritable_log="${workdir}/unwritable.log"
    local started early_elapsed_ms elapsed_ms parser_elapsed_ms
    write_empty_fixtures
    started="$(date +%s%3N)"
    MOCK_HANG_FILE=nodeclaims.json run_collector "${early_artifacts}" "${early_log}"
    early_elapsed_ms=$(($(date +%s%3N) - started))
    (( early_elapsed_ms <= 10000 ))
    assert_jq '.source_availability.nodeclaims == false and .source_availability.karpenter_events == true' "${early_artifacts}/nap-failure-details.json"
    assert_sanitized "${early_artifacts}" "${early_log}"

    write_empty_fixtures
    started="$(date +%s%3N)"
    MOCK_HANG_FILES=nodeclaims.json,karpenter-events.json,scheduler-events.json \
        run_collector "${artifacts}" "${log}"
    elapsed_ms=$(($(date +%s%3N) - started))
    (( elapsed_ms <= 15000 ))
    assert_summary_value metrics_available false "${artifacts}/nap-failure-summary.txt"
    assert_summary_value details_available false "${artifacts}/nap-failure-summary.txt"
    assert_sanitized "${artifacts}" "${log}"

    write_empty_fixtures
    started="$(date +%s%3N)"
    MOCK_HANG_JQ=true run_collector "${parser_artifacts}" "${parser_log}"
    parser_elapsed_ms=$(($(date +%s%3N) - started))
    (( parser_elapsed_ms <= 15000 ))
    assert_summary_value metrics_available false "${parser_artifacts}/nap-failure-summary.txt"
    assert_summary_value details_available false "${parser_artifacts}/nap-failure-summary.txt"
    assert_sanitized "${parser_artifacts}" "${parser_log}"
    printf 'early_hang_elapsed_ms=%s sequential_hang_elapsed_ms=%s parser_hang_elapsed_ms=%s\n' \
        "${early_elapsed_ms}" "${elapsed_ms}" "${parser_elapsed_ms}"

    ARTIFACT_DIR="/not/a/writable/artifact/path"
    collect_nap_failure_artifacts >"${unwritable_log}" 2>&1
    assert_sanitized "${artifacts}" "${unwritable_log}"
}

test_expected_rejection_and_resource_state
test_karpenter_event_only_constraints
test_malformed_and_unavailable_inputs
test_output_bounds_and_best_effort_status
test_hard_deadline_and_unwritable_artifacts
echo "AKS NAP failure diagnostics tests: PASS"
