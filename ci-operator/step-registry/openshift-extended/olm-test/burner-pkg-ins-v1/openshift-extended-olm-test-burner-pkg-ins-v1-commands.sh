#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

cat /etc/os-release
oc version
python --version
pushd /tmp
python -m virtualenv ./venv_olm
source ./venv_olm/bin/activate
python3 -m pip install click numpy matplotlib semver || { ret_code=$?; FAIL_MESSAGE="cant install python lib"; exit_burner $ret_code yes; }
shopt -s nullglob

function exit_trap {
    echo "Exit trap triggered"
    # popd
    rm -fr venv_olm kube-burner-ocp || true
    # deactivate
}


trap 'exit_trap' EXIT

function generate_junit_xml {
    local ret_code="$1"
    junit_dir="${ARTIFACT_DIR}/junit"
    mkdir -p "${junit_dir}" || true

    if [ "W${ret_code}W" != "W0W" ]; then
        cat >"${junit_dir}/import-OLM.xml" <<- EOF
<testsuite time="${BURNER_RUN_DURATION}" name="OLM" tests="1" failures="1" skipped="0" errors="0">
  <testcase name="OCP-${CASEID}:kuiwang:OLM:[sig-olm] ${CASETITLE}" time="${BURNER_RUN_DURATION}">
    <failure message="">"${FAIL_MESSAGE}"</failure>
  </testcase>
</testsuite>
EOF

    else
        cat >"${junit_dir}/import-OLM.xml" <<- EOF
<testsuite time="${BURNER_RUN_DURATION}" name="OLM" tests="1" failures="0" skipped="0" errors="0">
  <testcase name="OCP-${CASEID}:kuiwang:OLM:[sig-olm] ${CASETITLE}" time="${BURNER_RUN_DURATION}"/>
</testsuite>
EOF

    fi

}

function get_burner_run_duration {
    BURNER_END=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    export BURNER_END
    echo "End time: $BURNER_END"

    # shellcheck disable=SC2155
    local start_seconds=$(date -d "$BURNER_START" +%s)
    # shellcheck disable=SC2155
    local end_seconds=$(date -d "$BURNER_END" +%s)
    local time_diff=$((end_seconds - start_seconds))
    echo "Time difference: $time_diff seconds"

    export BURNER_RUN_DURATION="$time_diff"

}

function exit_burner {

    local ret_code="$1"
    local generate_junit="$2"

    if [ "W${generate_junit}W" == "WyesW" ]; then
        get_burner_run_duration
        generate_junit_xml $ret_code
    fi

    if [ "W${BURNER_FORCE_SUCCESS_EXIT}W" == "WnoW" ]; then
            echo "do not force success exit"
            exit $ret_code
    else
        echo "force success exit"
        exit 0
    fi

}

function download_binary {
    local tmp_dir="$1"
    local kube_burner_version="$2"
    local kube_burner_url="https://github.com/kube-burner/kube-burner-ocp/releases/download/v${kube_burner_version}/kube-burner-ocp-V${kube_burner_version}-linux-x86_64.tar.gz"
    curl --fail --retry 8 -sS -L "${kube_burner_url}" | tar -xzC "${tmp_dir}/" kube-burner-ocp || { ret_code=$?; FAIL_MESSAGE="cant get kube-burner-ocp"; exit_burner $ret_code yes; }
}

function get_config_files {
    local base_parent_dir="/go/src/github.com/openshift/openshift-tests-private/"
    local util_parent_dir="${base_parent_dir}test/extended/operators/stress/util"
    local config_parent_dir="${base_parent_dir}test/extended/operators/stress/manifests/config"
    cp -fr "${util_parent_dir}/"* . || { ret_code=$?; FAIL_MESSAGE="cant copy burner util"; exit_burner $ret_code yes; }
    cp -fr "${config_parent_dir}/${OPERATION}/"* . || { ret_code=$?; FAIL_MESSAGE="cant copy burner-config"; exit_burner $ret_code yes; }
}

function set_prometheus {
    PROMETHEUS_URL=https://$(oc get route -n openshift-monitoring prometheus-k8s -o jsonpath="{.spec.host}")
    set +x
    PROMETHEUS_TOKEN=$(oc create token -n openshift-monitoring prometheus-k8s --duration 12h)
    set -x
    export PROMETHEUS_URL PROMETHEUS_TOKEN
}

function collect_catalogd_log {
    catalogd_log_dir="${ARTIFACT_DIR}/catalogdLog"
    mkdir -p "${catalogd_log_dir}" || { ret_code=$?; FAIL_MESSAGE="cant create dir ${catalogd_log_dir}"; exit_burner $ret_code yes; }
    duration_in_minutes=$(( BURNER_RUN_DURATION / 60 ))

    catalogdPodName="$(oc get pods \
        -l control-plane=catalogd-controller-manager \
        -n openshift-catalogd \
        -o=jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
    if [ $? -ne 0 ] || [ -z "$catalogdPodName" ]; then
        FAIL_MESSAGE="cant get pod name of catalogd"
        exit_burner 1 yes
    fi

    log_file_pod="${catalogdPodName}.log"
    oc logs -n openshift-catalogd ${catalogdPodName} --since "${duration_in_minutes}m" > ${log_file_pod} || true
    cp -fr ${log_file_pod} ${catalogd_log_dir} || true

    restart_count_pod="$(oc get pod "$catalogdPodName" \
        -n openshift-catalogd \
        -o=jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null)"
    if [ $? -ne 0 ] || [ -z "$restart_count_pod" ]; then
        FAIL_MESSAGE="cant get pod restart count of catalogd"
        exit_burner 1 yes
    fi

    if [ "$restart_count_pod" -gt 0 ]; then
        previous_log_file_pod="${catalogdPodName}.previous.log"
        oc logs -n openshift-catalogd ${catalogdPodName} --previous --since "${duration_in_minutes}m" > ${previous_log_file_pod} || true
        cp -fr ${previous_log_file_pod} ${catalogd_log_dir} || true
    fi
}

function collect_container_cpu_metrics {
    metrics_origin_file="$1"
    metric_name=$2
    local ccpu_dir=$3
    prefix_mt_ccpu_con="${ccpu_dir}/mt_ccpu_con_${metric_name}"

    mkdir -p ${ccpu_dir} || { ret_code=$?; FAIL_MESSAGE="cant get create dir ${ccpu_dir}"; exit_burner $ret_code yes; }
    rm -f "${ccpu_dir}/*" || true

    jq -c '.[]' "$metrics_origin_file" | while read -r line; do
        pod=$(echo "$line" | jq -r '.labels.pod') # need to enahance it to support different format, currently it only support by (container, pod) as hard-coded
        container=$(echo "$line" | jq -r '.labels.container')
        if [ -z "$pod" ] || [ -z "$container" ]; then
            echo "pod or container is empty"
            echo "pod is ${pod}, and container is ${container}"
            continue
        fi

        tmp_file="${prefix_mt_ccpu_con}_${pod}_${container}.tmp"

        echo "$line" >> "$tmp_file" || true
    done

    for file in ${prefix_mt_ccpu_con}_*_*.tmp; do
        metrics_concrete_file="${file%.tmp}.json"
        jq -s '.' "$file" > "$metrics_concrete_file" || true
        rm -f "$file" || true
    done

    for file in ${prefix_mt_ccpu_con}_*_*.json; do
        metrics_abstract_file="${file/_con_/_abs_}"

        jq 'map({timestamp: .timestamp, value: .value})' "$file" > "$metrics_abstract_file" || true
    done

}

function collect_multi_container_cpu_metrics {

    CCPU_DIR="${METRICS_ANALYSIS_DIR}/ccpu"
    export CCPU_DIR

    set +x
    for file in collected-metrics-${UUID}/containerCPU*-*.json; do
        echo "collecting ${file}"
        metric_name=$(basename "$file" .json)
        collect_container_cpu_metrics $file $metric_name $CCPU_DIR
    done

    mkdir -p "${ARTIFACT_DIR}/${CCPU_DIR}" || true
    cp -fr ${CCPU_DIR}/* "${ARTIFACT_DIR}/${CCPU_DIR}" || true

    # it is too long exceeding 1048576 bytes to cause job failed. currently we do not use it, so comment it.
    # for file in ${CCPU_DIR}/mt_ccpu_abs_*.json; do
    #     echo "put ${file} into shared dir"
    #     file_name=$(basename "$file")
    #     rm -f ${SHARED_DIR}/${file_name} || true
    #     cp -fr ${file} "${SHARED_DIR}/${file_name}" || true
    # done
    set -x

}

function analysis_container_cpu_metrics {

    CCPU_DIR="${METRICS_ANALYSIS_DIR}/ccpu"
    export CCPU_DIR
    CCPU_DIR_RESULT="${CCPU_DIR}/result"
    mkdir -p ${CCPU_DIR_RESULT} || { ret_code=$?; FAIL_MESSAGE="cant get create result dir ${CCPU_DIR_RESULT}"; exit_burner $ret_code yes; }
    export CCPU_DIR_RESULT

    set +x
    for file in ${CCPU_DIR}/mt_ccpu_abs_*.json; do
        echo "analysis ${file}"
        local ma_options=" --zscore_threshold ${ZSCORE_THRESHOLD} --window_threshold ${WINDOW_THRESHOLD} --window_size ${WINDOW_SIZE} --watermark ${WATERMARK}"
        python3 ma.py check-ccpu -i ${file} -o ${CCPU_DIR_RESULT} ${ma_options}
    done
    set -x

    mkdir -p "${ARTIFACT_DIR}/${CCPU_DIR_RESULT}" || true
    cp -fr ${CCPU_DIR_RESULT}/* "${ARTIFACT_DIR}/${CCPU_DIR_RESULT}" || true
}

function determine_container_cpu {

    CCPU_DIR="${METRICS_ANALYSIS_DIR}/ccpu"
    export CCPU_DIR
    CCPU_DIR_RESULT="${CCPU_DIR}/result"
    export CCPU_DIR_RESULT

    set +x
    FAIL_MESSAGE="cpu usage abnormal:"
    for file in ${CCPU_DIR}/mt_ccpu_abs_*.json; do
        echo "determine ${file}"
        file_name=$(basename "$file")
        file_wo_ext="${file_name%.*}"
        if [ -f "${CCPU_DIR_RESULT}/${file_wo_ext}_result-fail" ]; then
            echo "${file_wo_ext}_result-fail exists"
            FAIL_MESSAGE+=" ${file_name}"
            export CPU_USAGE_RESULT=1
        fi
    done
    set -x
}

function put_origin_metrics_to_artfacts {
    set +x
    metrics_folder_name=$(find . -maxdepth 1 -type d -name "collected-metrics-${UUID}*" | head -n 1)
    for file in ${metrics_folder_name}/*.json; do
        echo "convert ${file} into multi-line"
        jq . ${file} > "${file}_tmp" || true
        mv -f "${file}_tmp" ${file} || true
        rm -fr "${file}_tmp" || true
    done
    set -x
    cp -r "${metrics_folder_name}" "${ARTIFACT_DIR}/" || true
}

function summarize_test_result {
    local ret_code=$1
    echo "Summarizing test results..."
    if ! [[ -d "${ARTIFACT_DIR:-'/default-non-exist-dir'}" ]] ; then
        echo "Artifact dir '${ARTIFACT_DIR}' not exist"
        exit_burner $ret_code "no"
    else
        echo "Artifact dir '${ARTIFACT_DIR}' exist"
        ls -lR "${ARTIFACT_DIR}"
        files="$(find "${ARTIFACT_DIR}" -name '*.xml' | wc -l)"
        if [[ "$files" -eq 0 ]] ; then
            echo "There are no JUnit files"
            exit_burner $ret_code "no"
        fi
    fi
    declare -A results=([failures]='0' [errors]='0' [skipped]='0' [tests]='0')
    grep -r -E -h -o 'testsuite.*tests="[0-9]+"[^>]*' ${ARTIFACT_DIR}/junit/import*.xml > /tmp/result.log || { echo "can not grep test result";exit_burner 1 "no"; }
    while read row ; do
        echo "row: ${row}"
        for ctype in "${!results[@]}" ; do
            count="$(sed -E "s/.*$ctype=\"([0-9]+)\".*/\1/" <<< $row)"
            echo "ctpye: ${ctype}, count: ${count}"
            if [[ -n $count ]] && [[ "$count" != "0" ]] ; then
                results[$ctype]=$(( ${results[$ctype]} + $count )) || true
            fi
        done
    done < /tmp/result.log

    TEST_RESULT_FILE="${ARTIFACT_DIR}/test-results.yaml"
    cat > "${TEST_RESULT_FILE}" <<- EOF
openshift-extended-olm-test-burner-pkg-ins-v1:
  total: ${results[tests]}
  failures: ${results[failures]}
  errors: ${results[errors]}
  skipped: ${results[skipped]}
EOF

    if [ ${results[failures]} != 0 ] ; then
        echo '  failingScenarios:' >> "${TEST_RESULT_FILE}"
        echo "    - ${CASETITLE}" >> "${TEST_RESULT_FILE}"
    fi
    cat "${TEST_RESULT_FILE}" | tee -a "${SHARED_DIR}/openshift-e2e-test-qe-report" || true

}


function kube_burner_run {
    WORKLOAD=${WORKLOAD:?}
    OPERATION=${OPERATION:?}
    CONFIG_FILE="${OPERATION}.yml"
    KUBE_BURNER_VERSION=${KUBE_BURNER_VERSION:-1.6.3}
    KUBE_DIR=${KUBE_DIR:-/tmp}

    UUID=${UUID:-$(uuidgen)}
    BURNER_TIMEOUT=${BURNER_TIMEOUT:-4h0m0s}
    LOG_LEVEL=${LOG_LEVEL:-info}
    GC=${GC:-true}
    BURST=${BURST:-20}
    QPS=${QPS:-20}
    GC_METRICS=${GC_METRICS:-false}
    PROFILE_TYPE=${PROFILE_TYPE:-both}
    CHECK_HEALTH=${CHECK_HEALTH:-true}
    BASE_FLAGS="--log-level=${LOG_LEVEL} --check-health=${CHECK_HEALTH} --qps=${QPS} --burst=${BURST} --gc=${GC} --uuid=${UUID} --timeout=${BURNER_TIMEOUT} --gc-metrics=${GC_METRICS} --profile-type=${PROFILE_TYPE}"
    METRICS_ENDPOINT=${METRICS_ENDPOINT:-metrics-endpoint.yml}
    BASE_FLAGS+=" --metrics-endpoint=${METRICS_ENDPOINT}"
    # ES_SERVER=${ES_SERVER=https://USER:PASSWORD@HOSTNAME:443}
    # if [[ -n ${ES_SERVER} ]]; then
    #     BASE_FLAGS+=" --es-server=${ES_SERVER} --es-index=ripsaw-kube-burner"
    # fi

    # CHURN=${CHURN:-true}
    # CHURN_CYCLES=${CHURN_CYCLES:-1}
    # CHURN_DELAY=${CHURN_DELAY:-2m0s}
    # CHURN_DELETIOIN_STRATEGY=${CHURN_DELETIOIN_STRATEGY:-default}
    # CHURN_DURATION=${CHURN_DURATION:-5h0m0s}
    # CHURN_PERCENT=${CHURN_PERCENT:-20}
    # CHURN_FLAGS=" --churn=${CHURN} --churn-cycles=${CHURN_CYCLES} --churn-delay=${CHURN_DELAY} --churn-deletion-strategy=${CHURN_DELETIOIN_STRATEGY} --churn-duration=${CHURN_DURATION} --churn-percent=${CHURN_PERCENT}"

    JOB_ITERATIONS=${JOB_ITERATIONS:?}
    ITERATIONS_PER_NAMESPACE=${ITERATIONS_PER_NAMESPACE:-1}
    NAMESPACED_ITERATIONS=${NAMESPACED_ITERATIONS:-true}
    ITERATIONS_FLAGS=" --iterations=${JOB_ITERATIONS} --iterations-per-namespace=${ITERATIONS_PER_NAMESPACE} --namespaced-iterations=${NAMESPACED_ITERATIONS}"

    SERVICE_FLAGS=" --service-latency=false"

    # EXTRA_FLAGS="${CHURN_FLAGS} ${ITERATIONS_FLAGS} ${SERVICE_FLAGS}"
    EXTRA_FLAGS="${ITERATIONS_FLAGS} ${SERVICE_FLAGS}"

    CONFIG_FLAGS=" --config=${CONFIG_FILE}"

    cmd="${KUBE_DIR}/kube-burner-ocp ${WORKLOAD} ${CONFIG_FLAGS} ${BASE_FLAGS} ${EXTRA_FLAGS}"


    download_binary $KUBE_DIR $KUBE_BURNER_VERSION
    set_prometheus
    get_config_files
    # Capture the exit code of the run, but don't exit the script if it fails.
    set +e
    touch "${ARTIFACT_DIR}/skip_overall_if_fail"

    echo $cmd
    JOB_START=${JOB_START:-$(date -u +"%Y-%m-%dT%H:%M:%SZ")};
    $cmd
    exit_code=$?
    JOB_END=${JOB_END:-$(date -u +"%Y-%m-%dT%H:%M:%SZ")};

    if [[ "${ENABLE_LOCAL_INDEX:-false}" == "true" ]]; then
        put_origin_metrics_to_artfacts
        collect_multi_container_cpu_metrics
        analysis_container_cpu_metrics
        determine_container_cpu
    fi
    set -e

    if [ $exit_code -eq 0 ]; then
        JOB_STATUS="success"
    else
        JOB_STATUS="failure"
    fi
    echo "kube burner job status: $JOB_STATUS"

    get_burner_run_duration
    generate_junit_xml $CPU_USAGE_RESULT
    summarize_test_result $CPU_USAGE_RESULT
    collect_catalogd_log
    exit_burner $CPU_USAGE_RESULT "no"

}

# shellcheck disable=SC2155
export WORKLOAD=init OPERATION="pkg-ins-v1" UUID=$(uuidgen) ES_SERVER="" METRICS_ANALYSIS_DIR="metrics_analysis"
export JOB_ITERATIONS="${JOB_ITERATIONS_V1}"
export GC="${GC_V1}"
export PREFIX_PKG_NAME_V1
export BURNER_TIMEOUT="${BURNER_TIMEOUT_V1}" MAX_WAIT_TIMEOUT="${MAX_WAIT_TIMEOUT_V1}" JOB_ITERATION_DELAY="${JOB_ITERATION_DELAY_V1}" JOB_PAUSE="${JOB_PAUSE_V1}"
export KUBE_BURNER_VERSION="${KUBE_BURNER_VERSION_V1}" LOG_LEVEL="${LOG_LEVEL_V1}" GC_METRICS="${GC_METRICS_V1}" CHECK_HEALTH="${CHECK_HEALTH_V1}" BURST="${BURST_V1}" QPS="${QPS_V1}"
export ENABLE_LOCAL_INDEX="${ENABLE_LOCAL_INDEX_V1}" METRICS_ENDPOINT="${METRICS_ENDPOINT_V1}" ZSCORE_THRESHOLD="${ZSCORE_THRESHOLD_V1}" WINDOW_THRESHOLD="${WINDOW_THRESHOLD_V1}" WINDOW_SIZE="${WINDOW_SIZE_V1}" WATERMARK="${WATERMARK_V1}"
export CPU_USAGE_RESULT=0 BURNER_FORCE_SUCCESS_EXIT="${BURNER_FORCE_SUCCESS_EXIT_V1}" CASEID="${CID_V1}" CASETITLE="${CTITLE_V1}"

BURNER_START=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
export BURNER_START
echo "Start time: $BURNER_START"
kube_burner_run
