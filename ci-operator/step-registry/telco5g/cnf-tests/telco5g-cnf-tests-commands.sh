#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function create_tests_skip_list_file {
# List of test cases to ignore due to open bugs
cat <<EOF >"${SKIP_TESTS_FILE}"
# <feature> <test name>

# this test is checking that there are no none cnf-worker nodes with rt kernel enabled.
# when running cnf-tests in parallel we do have other nodes with rt kernel so the test is failing.
performance "a node without performance profile applied should not have RT kernel installed"

# bz### known bug
sriov "Should be able to configure a metaplugin"
# bz### known bug
sriov "Webhook resource injector"
# bz### known bug
sriov "pod with sysctl\\\'s on bond over sriov interfaces should start"
# need to investigate why it's failing
sriov "Test Connectivity Connectivity between client and server Should work over a SR-IOV device"
EOF
}

function create_ns {
    ns=$1

cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: ${ns}
---
EOF
}

function is_bm_node {
    node=$1

    machine=$(oc get "${node}" -o json | jq '.metadata.annotations' | grep "machine.openshift.io/machine" | cut -d ":" -f2 | tr -d '", ')
    machine_ns=$(echo "${machine}" | cut -d "/" -f1)
    machine_name=$(echo "${machine}" | cut -d "/" -f2)
    bmh=$(oc get machine -n "${machine_ns}" "${machine_name}" -o json | jq '.metadata.annotations' | grep "metal3.io/BareMetalHost" | cut -d ":" -f2 | tr -d '", ')
    bmh_ns=$(echo "${bmh}" | cut -d "/" -f1)
    bmh_name=$(echo "${bmh}" | cut -d "/" -f2)
    manufacturer=$(oc get bmh -n "${bmh_ns}" "${bmh_name}" -o json | jq '.status.hardware.systemVendor.manufacturer')
    # if the system manufacturer is not Red Hat, that's a BM node
    if [[ "${manufacturer}" != *"Red Hat"* ]]; then
        return 0
    fi
    return 1
}

function get_skip_tests {
    feature="$1"

    skip_list=""
    if [ -f "${SKIP_TESTS_FILE}" ]; then
        rm -f feature_skip_list.txt
        grep --text ^"${feature}" "${SKIP_TESTS_FILE}" > feature_skip_list.txt
        skip_list=""
        while read line;
        do
            test=$(echo "${line}" | cut -d " " -f2- | tr " " .)
            if [ ! -z "${test}" ]; then
                if [ "${skip_list}" == "" ]; then
                    skip_list="${test}"
                else
                    skip_list="${skip_list} ${test}"
                fi
            fi
        done < feature_skip_list.txt
    fi

    echo "${skip_list}"
}

function deploy_and_test {
    feature=$1
    nodes=$2

    # work in tmp dir to be able compile cnf-tests in parallel, per tested feature
    tmp_dir=$(mktemp -d -t cnf-XXXXX)
    cd "${tmp_dir}" || exit 1
    cp -r "$cnf_dir"/cnf-features-deploy .
    cd cnf-features-deploy

    # MCP name can't have '_' char
    node_label=$(sed 's/_/-/g' <<<worker-${feature})
    features_env="ci"

    if [[ "${feature}" == "performance" ]] ; then
        node_label="worker-cnf"
        create_ns "performance-addon-operators-testing"
        features_env="typical-baremetal"
    fi

    if [[ "${feature}" == "sriov" ]]; then
        rm -f perf_profile_for_sriov.yaml
        oc kustomize feature-configs/typical-baremetal/performance > perf_profile_for_sriov.yaml
        sed -i "s/name\: performance/name\: performance-sriov/g" perf_profile_for_sriov.yaml
        sed -i "s/worker-cnf/${node_label}/g" perf_profile_for_sriov.yaml
        oc apply -f perf_profile_for_sriov.yaml
    fi

    if [[ "${feature}" == "xt_u32" ]] || [[ "${feature}" == "sctp" ]]; then
        sed -i "s/worker-cnf/${node_label}/g" feature-configs/deploy/"${feature}"/"${feature}"_module_mc.yaml
    else
        export NODES_SELECTOR="node-role.kubernetes.io/${node_label}="
    fi

    export ROLE_WORKER_CNF="${node_label}"
    export TESTS_REPORTS_PATH="${ARTIFACT_DIR}/${feature}"

    CNF_NODES="${nodes}" make setup-test-cluster

    FEATURES_ENVIRONMENT="${features_env}" FEATURES="${feature}" make feature-deploy
    FEATURES_ENVIRONMENT="${features_env}" FEATURES="${feature} general" make feature-wait

    skip_tests=$(get_skip_tests "${feature}")
    FEATURES="\[${feature}\]" SKIP_TESTS="${skip_tests}" make functests

    # cleanup nodes
    for node in $nodes; do
        oc label "${node}" "node-role.kubernetes.io/${node_label}"-
        touch "${cnf_dir}/${node}_ready.txt"
    done
}

export FEATURES="${FEATURES:-sriov performance sctp xt_u32 ovn}" # next: ovs_qos metallb
export SKIP_TESTS_FILE="${SKIP_TESTS_FILE:-${SHARED_DIR}/telco5g-cnf-tests-skip-list.txt}"
export SCTPTEST_HAS_NON_CNF_WORKERS="${SCTPTEST_HAS_NON_CNF_WORKERS:-false}"
export XT_U32TEST_HAS_NON_CNF_WORKERS="${XT_U32TEST_HAS_NON_CNF_WORKERS:-false}"

export CNF_REPO="${CNF_REPO:-https://github.com/openshift-kni/cnf-features-deploy.git}"
export CNF_BRANCH="${CNF_BRANCH:-master}"

echo "************ telco5g cnf-tests commands ************"

if [[ -n "${E2E_TESTS_CONFIG:-}" ]]; then
    readarray -t config <<< "${E2E_TESTS_CONFIG}"
    for var in "${config[@]}"; do
        if [[ ! -z "${var}" ]]; then
            if [[ "${var}" == *"CNF_BRANCH"* ]]; then
                CNF_BRANCH="$(echo "${var}" | cut -d'=' -f2)"
            elif [[ "${var}" == *"FEATURES"* ]]; then
                FEATURES="$(echo "${var}" | cut -d'=' -f2 | tr -d '"')"
            fi
        fi
    done
fi

worker_nodes=$(oc get nodes --selector='node-role.kubernetes.io/worker' \
--selector='!node-role.kubernetes.io/master' -o name)
if [ -z "${worker_nodes}" ]; then
    echo "[ERROR]: No worker nodes found in cluster"
    exit 1
fi

# get BM workers for testing
test_nodes=""
for node in ${worker_nodes}; do
    if is_bm_node "${node}"; then
        test_nodes="${test_nodes} ${node}"
    fi
done

if [ -z "${test_nodes}" ]; then
    echo "[ERROR]: No BM worker nodes found in cluster"
    exit 1
fi

cnf_dir=$(mktemp -d -t cnf-XXXXX)
cd "$cnf_dir" || exit 1

mkdir -p node
for node in ${test_nodes}; do
    touch "${node}_ready.txt"
done

echo "running on branch ${CNF_BRANCH}"
git clone -b "${CNF_BRANCH}" "${CNF_REPO}" cnf-features-deploy
cd cnf-features-deploy
oc patch OperatorHub cluster --type json -p '[{"op": "add", "path": "/spec/disableAllDefaultSources", "value": true}]'
make setup-build-index-image
cd -

create_tests_skip_list_file

# run cnf-tests by feature in a thread on a free worker node
for feature in ${FEATURES}; do
    log_file="${ARTIFACT_DIR}/deploy_and_test_${feature}.log"
    rm -f "${log_file}"
    
    feature_nodes=""
    num_of_free_nodes=0
    num_of_required_nodes=1
    if [[ "${feature}" == "ovs_qos" ]]; then
        num_of_required_nodes=2
    fi
    while [ ${num_of_free_nodes} -lt ${num_of_required_nodes} ]; do
        for node in ${test_nodes}; do
            node_ready_file="${node}_ready.txt"
            if [ -f "${node_ready_file}" ]; then
                rm -f "${node_ready_file}"
                feature_nodes="${feature_nodes} ${node}"
                num_of_free_nodes=$((num_of_free_nodes+1))
            fi
            if [ ${num_of_free_nodes} -eq ${num_of_required_nodes} ]; then
                (deploy_and_test "${feature}" "${feature_nodes}" || true) 2>&1 | tee "${log_file}" &
                break
            fi
        done
        sleep 10
    done
done
wait

# cleanup
for node in ${test_nodes}; do
    rm -f "${node}_ready.txt"
done
rm -rf node/

cd -

# check tests results
exit_code=0
err_msg=""
rm -f summary.txt
for feature in ${FEATURES}; do
    log_file="${ARTIFACT_DIR}/deploy_and_test_${feature}.log"
    if [ ! -f "${log_file}" ]; then
        err_msg="${err_msg}\n[ERROR]: Failed to test ${feature}"
        exit_code=1
    else
        # this sed removes coloring from log
        sed -i "s,\x1B\[[0-9;]*[a-zA-Z],,g" "${log_file}"
        # check if actually reached the stage of integration tests
        if [ ! "$(grep --text "Running Suite: CNF Features e2e integration tests" "${log_file}")" ]; then
            err_msg="${err_msg}\n[ERROR]: ${feature} testing didn't reach integration tests"
            exit_code=1
        else
            # get integration tests results from the full log file
            rm -f temp_summary.log
            stage_first_line=$(grep --text -n -m 1 "Running Suite: CNF Features e2e integration tests" "${log_file}" | cut -f1 -d:)
            tail --lines=+"${stage_first_line}" "${log_file}" >> temp_summary.log
            SUCCESS=$(grep --text 'Ran.*of.*Specs in.*seconds' temp_summary.log -A 1 | head -2  | tail -1)
            if [ -z "${SUCCESS}" ]; then
                err_msg="${err_msg}\n[ERROR]: ${feature} tests failed"
                exit_code=1
            elif [[ "${SUCCESS}" != *"SUCCESS"* ]]; then
                SUMMARY=$(grep --text 'Summarizing.*Failure*' temp_summary.log)
                if [ -n "${SUMMARY}" ]; then
                    cat temp_summary.log | sed -n '/Summarizing.*Failure*/,/Ran.*of.*Specs in.*seconds.*/p' | sed -e '$d' >> summary.txt
                fi
                err_msg="${err_msg}\n[ERROR]: ${feature} tests failed"
                exit_code=1
            fi
        fi
    fi
done

echo -e "${err_msg}\n"
if [ -f "summary.txt" ]; then
    cat summary.txt
fi
exit ${exit_code}
