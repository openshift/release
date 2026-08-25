#!/bin/bash
#
# Runs eco-gotests (Ecosystem QE Golang / Ginkgo framework) against a pre-installed OCP cluster.
# Test selection is driven by ECO_TEST_FEATURES (required) and ECO_TEST_LABELS (optional).
# Polarion reporting: REPORT_CASE_TAG / REPORT_PARAMETER_TAG / ECO_TC_PREFIX.
# Additional eco-gotests vars can be injected via ECO_GOTESTS_ENV_VARS (newline-separated KEY=VALUE).
# Results (JUnit XML, Polarion XML) are collected to ARTIFACT_DIR and mirrored to SHARED_DIR.
# Ref: https://github.com/rh-ecosystem-edge/eco-gotests/blob/main/README.md
#
set -euo pipefail; shopt -s inherit_errexit

# CI framework writes hub kubeconfig to SHARED_DIR/kubeconfig; eco-gotests requires KUBECONFIG.
export KUBECONFIG="${KUBECONFIG:-${SHARED_DIR}/kubeconfig}"

# Parse ECO_GOTESTS_ENV_VARS - newline-separated KEY=VALUE pairs injected by the ref's env field
# for test-suite-specific config, e.g.:
#   ECO_TEST_FEATURES=rdscore
#   ECO_TEST_LABELS=clean-cluster && mount-ns
#   ECO_RDS_CORE_CONFIG_FILE_PATH=/configs/default.yaml
# Blank lines and lines starting with # are skipped.
if [[ -n "${ECO_GOTESTS_ENV_VARS:-}" ]]; then
    while IFS= read -r line; do
        [[ -z "${line}" || "${line}" == \#* ]] && continue
        export "${line?}"
    done <<< "${ECO_GOTESTS_ENV_VARS}"
fi

# ECO_TEST_FEATURES is mandatory - the runner uses it to find test directories.
[[ -z "${ECO_TEST_FEATURES:-}" ]] && {
    echo "[ERROR] ECO_TEST_FEATURES is not set. Pass it via ECO_GOTESTS_ENV_VARS or as a direct env var." >&2
    exit 1
}

# Polarion reporting - mirrors the standalone podman run convention:
#   -e REPORT_CASE_TAG=polarion-testcase-id  -e REPORT_PARAMETER_TAG=polarion-parameter  -e ECO_TC_PREFIX=OCP-
export REPORT_CASE_TAG="${REPORT_CASE_TAG:-polarion-testcase-id}"
export REPORT_PARAMETER_TAG="${REPORT_PARAMETER_TAG:-polarion-parameter}"
export ECO_TC_PREFIX="${ECO_TC_PREFIX:-OCP-}"

# Verbosity knobs (optional); ECO_VERBOSE_LEVEL must be >= 100 to enable glog output.
export ECO_TEST_VERBOSE="${ECO_TEST_VERBOSE:-false}"
[[ -n "${ECO_VERBOSE_LEVEL:-}" ]] && export ECO_VERBOSE_LEVEL

# In standalone podman runs the container writes to /tmp/reports (via volume mount).
# In CI redirect to ARTIFACT_DIR/junit_eco_gotests/ so Prow picks up the files automatically.
# CopyArtifacts also checks /tmp/reports as a fallback in case the runner ignores ECO_REPORTS_DUMP_DIR.
typeset junitDir="${ARTIFACT_DIR}/junit_eco_gotests"
mkdir -p "${junitDir}"

export ECO_DUMP_FAILED_TESTS="${ECO_DUMP_FAILED_TESTS:-true}"
export ECO_REPORTS_DUMP_DIR="${junitDir}"
export ECO_ENABLE_REPORT="${ECO_ENABLE_REPORT:-true}"

# CopyArtifacts - called on EXIT regardless of test outcome.
# Mirrors the telcov10n eco-gotests convention:
#   report_*.xml                  → SHARED_DIR/polarion_<filename>  (Polarion)
#   junit_*.xml / *_suite_*.xml   → SHARED_DIR/junit_<filename>     (Prow/Sippy)
CopyArtifacts() {
    typeset f filename

    # Fallback: collect from container's default /tmp/reports path in case the runner
    # does not honour ECO_REPORTS_DUMP_DIR.
    if compgen -G "/tmp/reports/*.xml" > /dev/null 2>&1; then
        cp /tmp/reports/*.xml "${junitDir}/" 2>/dev/null || true
    fi

    if ! compgen -G "${junitDir}/*.xml" > /dev/null 2>&1; then
        echo "[WARN] No XML results found in ${junitDir}" >&2
        return
    fi

    # Polarion reports (report_*.xml).
    for f in "${junitDir}"/report_*.xml; do
        [[ -f "${f}" ]] || continue
        filename="$(basename "${f}")"
        cp "${f}" "${SHARED_DIR}/polarion_${filename}"
    done

    # JUnit reports: junit_*.xml or *_suite_*.xml, excluding polarion reports.
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

# GenerateRdsCoreConfig - dynamically builds the rdscore default.yaml by querying the cluster
# for real node hostnames. Called when ECO_TEST_FEATURES contains "rdscore" and
# ECO_RDS_CORE_CONFIG_FILE_PATH is not already pointing at an existing file.
#
# Node assignment:
#   cpNode     - first control-plane node  (master role)
#   cnfNode    - first worker node         (no master role)
#   workerNode - second worker node        (falls back to first worker, then cpNode)
#
# Generated YAML format (matching reference config):
#   rdscore_kdump_cp_node_label: 'kubernetes.io/hostname=<name>'
GenerateRdsCoreConfig() {
    typeset configFile="${ECO_RDS_CORE_CONFIG_FILE_PATH:-/tmp/eco-gotests-config/default.yaml}"
    typeset configDir
    configDir="$(dirname "${configFile}")"
    mkdir -p "${configDir}"

    # Extract control-plane node hostname (first master node).
    typeset cpNode
    cpNode="$(oc get nodes -l node-role.kubernetes.io/master -o json \
        | jq -r '.items[0].metadata.labels["kubernetes.io/hostname"]')"

    [[ -z "${cpNode}" || "${cpNode}" == "null" ]] && {
        echo "[ERROR] Could not determine control-plane node hostname from cluster." >&2
        exit 1
    }

    # Extract worker node hostnames (nodes without master role).
    typeset -a workerNodesArr=()
    mapfile -t workerNodesArr < <(
        oc get nodes -l '!node-role.kubernetes.io/master' -o json \
            | jq -r '.items[].metadata.labels["kubernetes.io/hostname"]'
    )

    ((${#workerNodesArr[@]})) || {
        echo "[WARN] No worker nodes found; using control-plane node for all rdscore node labels." >&2
    }

    typeset cnfNode="${workerNodesArr[0]:-${cpNode}}"
    typeset workerNode="${workerNodesArr[1]:-${cnfNode}}"

    cat > "${configFile}" <<EOF
#
# kdump node labels - auto-generated from cluster node hostnames
#
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

    export ECO_RDS_CORE_CONFIG_FILE_PATH="${configFile}"

    true
}

# Generate rdscore config on the fly when the rdscore feature suite is requested
# and no pre-existing config file is provided.
if [[ "${ECO_TEST_FEATURES}" == *rdscore* ]] \
    && [[ ! -f "${ECO_RDS_CORE_CONFIG_FILE_PATH:-}" ]]; then
    GenerateRdsCoreConfig
fi

# Locate and execute the eco-gotests test runner.
# The eco-gotests container ships the pre-compiled binary and runner script.
# Equivalent to the standalone podman invocation:
#   podman run ... eco-gotests:latest --timeout=8h --keep-going
# The runner internally calls:
#   ginkgo -timeout=24h --keep-going --require-suite -r --label-filter=...
typeset ECO_RUNNER="/eco-gotests/scripts/test-runner.sh"

# Runtime summary before an opaque multi-hour test run (visible in xtrace and post-mortem logs).
: "eco-gotests features  : ${ECO_TEST_FEATURES}"
: "eco-gotests labels    : ${ECO_TEST_LABELS:-<none>}"
: "Polarion case tag     : ${REPORT_CASE_TAG}  TC prefix: ${ECO_TC_PREFIX}"
: "Reports directory     : ${junitDir}"
: "RDS core config       : ${ECO_RDS_CORE_CONFIG_FILE_PATH:-<not set>}"

if [[ -x "${ECO_RUNNER}" ]]; then
    "${ECO_RUNNER}"
else
    : "Runner not found at ${ECO_RUNNER}; falling back to make run-tests"
    make run-tests
fi

true
