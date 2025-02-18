#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

function exit_trap {
    echo "Exit trap triggered"
    # popd
    rm -fr venv_olm kube-burner-ocp || true
    # deactivate
}

function generate_junit_xml {
    local ret_code="$1"
    junit_dir="${ARTIFACT_DIR}/junit"
    mkdir -p "${junit_dir}" || true

    if [ "W${ret_code}W" != "W0W" ]; then
        cat >"${junit_dir}/import-OLM.xml" <<- EOF
<testsuite time="${BURNER_RUN_DURATION}" name="OLM" tests="1" failures="1" skipped="0" errors="0">
  <testcase name="OCP-00000:kuiwang:OLM:[sig-olm] olm create and delete operator repeatedly to check cpu of catalogsource" time="${BURNER_RUN_DURATION}">
    <failure message="">"${FAIL_MESSAGE}"</failure>
  </testcase>
</testsuite>
EOF

    else
        cat >"${junit_dir}/import-OLM.xml" <<- EOF
<testsuite time="${BURNER_RUN_DURATION}" name="OLM" tests="1" failures="0" skipped="0" errors="0">
  <testcase name="OCP-00000:kuiwang:OLM:[sig-olm] olm create and delete operator repeatedly to check cpu of catalogsource" time="${BURNER_RUN_DURATION}"/>
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

    get_burner_run_duration

    if [ "W${generate_junit}W" == "WyesW" ]; then
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

# cat /etc/os-release
# oc config view
# oc projects
# oc version
python --version
pushd /tmp
python -m virtualenv ./venv_olm
source ./venv_olm/bin/activate

trap 'exit_trap' EXIT

function download_binary {
    local tmp_dir="$1"
    local kube_burner_version="$2"
    local kube_burner_url="https://github.com/kube-burner/kube-burner-ocp/releases/download/v${kube_burner_version}/kube-burner-ocp-V${kube_burner_version}-linux-x86_64.tar.gz"
    # curl --fail --retry 8 --retry-all-errors -sS -L "${kube_burner_url}" | tar -xzC "${tmp_dir}/" kube-burner-ocp
    curl --fail --retry 8 -sS -L "${kube_burner_url}" | tar -xzC "${tmp_dir}/" kube-burner-ocp || ret_code=$?;FAIL_MESSAGE="cant get kube-burner-ocp";exit_burner $ret_code yes
}

function get_config_files {
    local repo_url="https://github.com/kuiwang02/burner-config.git" # will change to the official
    local git_option="--branch main"
    rm -fr burner-config metrics-profiles templates || true
    git clone $repo_url $git_option --depth 1 || ret_code=$?;FAIL_MESSAGE="cant clone burner-config";exit_burner $ret_code yes
    cp -fr burner-config/config/${OPERATION}/* . || ret_code=$?;FAIL_MESSAGE="cant copy burner-config";exit_burner $ret_code yes
}

function set_prometheus {
    PROMETHEUS_URL=https://$(oc get route -n openshift-monitoring prometheus-k8s -o jsonpath="{.spec.host}")
    set +x
    PROMETHEUS_TOKEN=$(oc create token -n openshift-monitoring prometheus-k8s)
    set -x
    export PROMETHEUS_URL PROMETHEUS_TOKEN
}

function collect_container_cpu_metrics {
    metrics_origin_file="$1"
    metric_name=$2
    local ccpu_dir=$3
    prefix_mt_ccpu_con="${ccpu_dir}/mt_ccpu_con_${metric_name}"
    # prefix_mt_ccpu_abs="${ccpu_dir}/mt_ccpu_abs_${metric_name}"

    mkdir -p ${ccpu_dir} || ret_code=$?;FAIL_MESSAGE="cant get create dir ${ccpu_dir}";exit_burner $ret_code yes
    rm -f "${ccpu_dir}/*" || true

    jq -c '.[]' "$metrics_origin_file" | while read -r line; do
        pod=$(echo "$line" | jq -r '.labels.pod')
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

    for file in ${CCPU_DIR}/mt_ccpu_abs_*.json; do
        echo "put ${file} into shared dir"
        file_name=$(basename "$file")
        rm -f ${SHARED_DIR}/${file_name} || true
        cp -fr ${file} "${SHARED_DIR}/${file_name}" || true
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
    GC_METRICS=${GC_METRICS:-false} # the default is false for the command
    PROFILE_TYPE=${PROFILE_TYPE:-both} # acutally it does not work for init because we should define metric endpoint
    CHECK_HEALTH=${CHECK_HEALTH:-true}
    BASE_FLAGS="--log-level=${LOG_LEVEL} --check-health=${CHECK_HEALTH} --qps=${QPS} --burst=${BURST} --gc=${GC} --uuid=${UUID} --timeout=${BURNER_TIMEOUT} --gc-metrics=${GC_METRICS} --profile-type=${PROFILE_TYPE}"
    METRICS_ENDPOINT=${METRICS_ENDPOINT:-metrics-endpoint.yml}
    BASE_FLAGS+=" --metrics-endpoint=${METRICS_ENDPOINT}"
    # ES_SERVER=${ES_SERVER=https://USER:PASSWORD@HOSTNAME:443}
    # if [[ -n ${ES_SERVER} ]]; then
    #     BASE_FLAGS+=" --es-server=${ES_SERVER} --es-index=ripsaw-kube-burner"
    # fi

    CHURN=${CHURN:-true}
    CHURN_CYCLES=${CHURN_CYCLES:-1}
    CHURN_DELAY=${CHURN_DELAY:-2m0s}
    CHURN_DELETIOIN_STRATEGY=${CHURN_DELETIOIN_STRATEGY:-default}
    CHURN_DURATION=${CHURN_DURATION:-5h0m0s}
    CHURN_PERCENT=${CHURN_PERCENT:-20}
    CHURN_FLAGS=" --churn=${CHURN} --churn-cycles=${CHURN_CYCLES} --churn-delay=${CHURN_DELAY} --churn-deletion-strategy=${CHURN_DELETIOIN_STRATEGY} --churn-duration=${CHURN_DURATION} --churn-percent=${CHURN_PERCENT}"

    JOB_ITERATIONS=${JOB_ITERATIONS:?}
    ITERATIONS_PER_NAMESPACE=${ITERATIONS_PER_NAMESPACE:-1}
    NAMESPACED_ITERATIONS=${NAMESPACED_ITERATIONS:-true}
    ITERATIONS_FLAGS=" --iterations=${JOB_ITERATIONS} --iterations-per-namespace=${ITERATIONS_PER_NAMESPACE} --namespaced-iterations=${NAMESPACED_ITERATIONS}"

    SERVICE_FLAGS=" --service-latency=false"

    EXTRA_FLAGS="${CHURN_FLAGS} ${ITERATIONS_FLAGS} ${SERVICE_FLAGS}"
    
    CONFIG_FLAGS=" --config=${CONFIG_FILE}"

    cmd="${KUBE_DIR}/kube-burner-ocp ${WORKLOAD} ${CONFIG_FLAGS} ${BASE_FLAGS} ${EXTRA_FLAGS}"


    download_binary $KUBE_DIR $KUBE_BURNER_VERSION
    set_prometheus
    get_config_files
    # Capture the exit code of the run, but don't exit the script if it fails.
    set +e

    echo $cmd
    JOB_START=${JOB_START:-$(date -u +"%Y-%m-%dT%H:%M:%SZ")};
    $cmd
    exit_code=$?
    JOB_END=${JOB_END:-$(date -u +"%Y-%m-%dT%H:%M:%SZ")};

    if [[ "${ENABLE_LOCAL_INDEX:-false}" == "true" ]]; then
        collect_multi_container_cpu_metrics
        put_origin_metrics_to_artfacts
    fi
    set -e

    if [ $exit_code -eq 0 ]; then
        JOB_STATUS="success"
    else
        JOB_STATUS="failure"
        FAIL_MESSAGE="there is abnormal usage on cpu"
    fi
    echo $JOB_STATUS

    exit_burner $ret_code yes

    # # env JOB_START="$JOB_START" JOB_END="$JOB_END" JOB_STATUS="$JOB_STATUS" UUID="$UUID" WORKLOAD="$WORKLOAD" ES_SERVER="$ES_SERVER" ../../utils/index.sh
    # return $exit_code

}

# shellcheck disable=SC2155
export WORKLOAD=init OPERATION="pkg-ins" UUID=$(uuidgen) ES_SERVER="" METRICS_ANALYSIS_DIR="metrics_analysis"
export JOB_ITERATIONS
export GC CHURN CHURN_CYCLES CHURN_DELAY CHURN_DURATION CHURN_PERCENT CHURN_DELETIOIN_STRATEGY
export PKG_NAME CHANNEL_NAME CATALOGSOURCE_NAME CATALOGSOURCE_NAMESPACE
export BURNER_TIMEOUT MAX_WAIT_TIMEOUT JOB_ITERATION_DELAY JOB_PAUSE
export KUBE_BURNER_VERSION LOG_LEVEL GC_METRICS CHECK_HEALTH BURST QPS
export ENABLE_LOCAL_INDEX METRICS_ENDPOINT

BURNER_START=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
export BURNER_START
echo "Start time: $BURNER_START"
kube_burner_run
