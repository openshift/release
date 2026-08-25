#!/bin/bash
#
# Run eco-gotests rdscore mount-ns tests against the cluster in KUBECONFIG.
# Feature/label defaults live in p2p-telco-mount-ns-ref.yaml.
# Runner: https://github.com/rh-ecosystem-edge/eco-gotests
#
set -euxo pipefail; shopt -s inherit_errexit

export KUBECONFIG="${KUBECONFIG:-${SHARED_DIR}/kubeconfig}"

# Extra eco-gotests KEY=VALUE pairs from the job env (blank / # lines skipped).
if [[ -n "${ECO_GOTESTS_ENV_VARS}" ]]; then
    while IFS= read -r line; do
        [[ -z "${line}" || "${line}" == \#* ]] && continue
        export "${line?}"
    done <<< "${ECO_GOTESTS_ENV_VARS}"
fi

[[ -n "${ECO_TEST_FEATURES}" ]]
[[ -n "${ECO_TEST_LABELS}" ]]

[[ -n "${ECO_VERBOSE_LEVEL}" ]] && export ECO_VERBOSE_LEVEL

typeset junitDir="${ARTIFACT_DIR}/junit_eco_gotests"
mkdir -p "${junitDir}"
export ECO_REPORTS_DUMP_DIR="${junitDir}"

CopyArtifacts() {
    typeset f filename

    # Fallback if the runner ignores ECO_REPORTS_DUMP_DIR.
    if compgen -G "/tmp/reports/*.xml" > /dev/null 2>&1; then
        cp /tmp/reports/*.xml "${junitDir}/" || true
    fi

    if ! compgen -G "${junitDir}/*.xml" > /dev/null 2>&1; then
        : "No XML results found in ${junitDir}"
        return
    fi

    for f in "${junitDir}"/report_*.xml; do
        [[ -f "${f}" ]] || continue
        filename="$(basename "${f}")"
        cp "${f}" "${SHARED_DIR}/polarion_${filename}"
    done

    for f in "${junitDir}"/*.xml; do
        [[ -f "${f}" ]] || continue
        filename="$(basename "${f}")"
        if [[ "${filename}" == junit_*.xml || "${filename}" == *_suite_*.xml ]] \
            && [[ "${filename}" != report_*.xml ]]; then
            cp "${f}" "${SHARED_DIR}/junit_${filename}"
        fi
    done

    true
}

trap 'CopyArtifacts' EXIT

# Build rdscore YAML from cluster node hostnames when the job did not supply one.
# cpNode     - first control-plane node
# cnfNode    - first worker (falls back to cpNode)
# workerNode - second worker (falls back to cnfNode)
if [[ ! -f "${ECO_RDS_CORE_CONFIG_FILE_PATH}" ]]; then
    typeset configDir
    configDir="$(dirname "${ECO_RDS_CORE_CONFIG_FILE_PATH}")"
    mkdir -p "${configDir}"

    typeset cpNode
    cpNode="$(oc get nodes -l node-role.kubernetes.io/master -o json \
        | jq -r '.items[0].metadata.labels["kubernetes.io/hostname"]')"
    [[ -n "${cpNode}" && "${cpNode}" != "null" ]] \
        || { : 'Could not determine control-plane node hostname.'; false; }

    typeset -a workerNodesArr=()
    mapfile -t workerNodesArr < <(
        oc get nodes -l '!node-role.kubernetes.io/master' -o json \
            | jq -r '.items[].metadata.labels["kubernetes.io/hostname"]'
    )
    ((${#workerNodesArr[@]})) || : "No worker nodes found; using control-plane node for rdscore labels."

    typeset cnfNode="${workerNodesArr[0]:-${cpNode}}"
    typeset workerNode="${workerNodesArr[1]:-${cnfNode}}"

    cat > "${ECO_RDS_CORE_CONFIG_FILE_PATH}" <<EOF
rdscore_kdump_cp_node_label: 'kubernetes.io/hostname=${cpNode}'
rdscore_kdump_cnf_node_label: 'kubernetes.io/hostname=${cnfNode}'
rdscore_kdump_worker_node_label: 'kubernetes.io/hostname=${workerNode}'

#
# SR-IOV rootless dpdk
#
rdscore_rootless_dpdk_ns: 'rds-rootless-dpdk-wlkd'

#
# EgressIP
#
rdscore_egressip_ns_label: 'env=sys-qa'
rdscore_egressip_pod_label: 'app=web'
rdscore_egressip_ns_one: 'rds-egressip-ns-one'
rdscore_egressip_ns_two: 'rds-egressip-ns-two'
EOF
fi

# Same extra args as the proven standalone podman run:
#   quay.io/ocp-edge-qe/eco-gotests:latest --timeout=8h --keep-going
typeset ecoRunner="/eco-gotests/scripts/test-runner.sh"
: "eco-gotests features=${ECO_TEST_FEATURES} labels=${ECO_TEST_LABELS}"
: "rdscore config=${ECO_RDS_CORE_CONFIG_FILE_PATH} reports=${junitDir}"

if [[ -x "${ecoRunner}" ]]; then
    "${ecoRunner}" --timeout=8h --keep-going
else
    : "Runner not found at ${ecoRunner}; falling back to make run-tests"
    make run-tests
fi

true
