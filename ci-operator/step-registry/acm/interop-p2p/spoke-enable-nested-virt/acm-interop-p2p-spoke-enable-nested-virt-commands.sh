#!/bin/bash
#
# Enable nested virtualization on ACM spoke cluster worker nodes (AWS).
#
# The OpenShift Machine API does not yet expose EC2 CpuOptions.NestedVirtualization,
# so this script enables it post-deploy via the AWS CLI.  Each worker is cordoned,
# drained, stopped, reconfigured, restarted, and uncordoned sequentially.
#
# Bare-metal instances (*.metal) have native KVM and are skipped.
# Supported families (per AWS docs, June 2026): c7i m7i r7i c8i m8i r8i x8i i7i
#
# Reads:
#   ${SHARED_DIR}/managed-cluster-kubeconfig  — spoke admin kubeconfig
#   ${SHARED_DIR}/managed-cluster-regions     — spoke AWS region (one per line)
#   ACM_SPOKE_WORKER_TYPE                     — spoke worker EC2 instance type
#   CLUSTER_PROFILE_DIR/.awscred             — AWS credentials
#
set -euxo pipefail; shopt -s inherit_errexit

[ -f "${SHARED_DIR}/managed-cluster-kubeconfig" ]
export KUBECONFIG="${SHARED_DIR}/managed-cluster-kubeconfig"

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

# proxy-conf.sh may export HTTPS_PROXY=http://user:pass@... — disable xtrace so
# the assignment is not traced into CI logs; re-enable immediately after.
if test -f "${SHARED_DIR}/proxy-conf.sh"; then
    set +x
    # shellcheck disable=SC1091
    source "${SHARED_DIR}/proxy-conf.sh"
    set -x
fi

# Read the spoke cluster AWS region (first line; one spoke in this job)
typeset spokeRegion
spokeRegion="$(head -1 "${SHARED_DIR}/managed-cluster-regions")"
[[ -n "${spokeRegion}" ]]
export AWS_DEFAULT_REGION="${spokeRegion}"

# Supported non-metal families (per AWS, all commercial regions as of June 2026)
typeset -r NESTED_VIRT_FAMILIES="c7i m7i r7i c8i m8i r8i x8i i7i"

# ─── Helpers ────────────────────────────────────────────────────────────────

IsMetalInstance() { [[ "$1" == *.metal* ]]; }

InstanceFamily() {
    # "m8i.8xlarge" → "m8i"
    printf '%s' "${1%%.*}"
}

SupportsNestedVirt() {
    typeset family; family="$(InstanceFamily "$1")"
    [[ " ${NESTED_VIRT_FAMILIES} " == *" ${family} "* ]]
}

RequireAwsCliV2() {
    command -v aws 1>/dev/null || { echo >&2 "[ERROR] aws CLI not found"; exit 1; }
    typeset versionStr major
    versionStr="$(aws --version 2>&1 | grep -oE 'aws-cli/[0-9]+' | head -1)"
    major="${versionStr##*/}"
    if (( major < 2 )); then
        echo >&2 "[ERROR] AWS CLI v2 required (found: $(aws --version 2>&1))"
        exit 1
    fi
}

# ─── Core ───────────────────────────────────────────────────────────────────

# EnableNestedVirtOnNode — stop/modify/start one EC2 instance for nested virt.
# Arguments:
#   $1  instanceId   EC2 instance ID
#   $2  nodeName     OCP node name (for cordon/drain/uncordon)
EnableNestedVirtOnNode() {
    typeset instanceId="$1" nodeName="$2"

    : "Processing node ${nodeName} (${instanceId})"

    # Single describe call — extract all fields we need in one API round-trip
    typeset cpuOptsJson nestedVirtStatus coreCount threadsPerCore
    cpuOptsJson="$(aws ec2 describe-instances \
        --instance-ids "${instanceId}" \
        --query 'Reservations[0].Instances[0].CpuOptions' \
        --output json)"
    nestedVirtStatus="$(jq -r '.NestedVirtualization // "None"' <<< "${cpuOptsJson}")"
    coreCount="$(jq -r '.CoreCount' <<< "${cpuOptsJson}")"
    threadsPerCore="$(jq -r '.ThreadsPerCore' <<< "${cpuOptsJson}")"

    # Guard: describe-instances returned null or the CpuOptions fields are missing
    if [[ "${coreCount}" == "null" || -z "${coreCount}" || \
          "${threadsPerCore}" == "null" || -z "${threadsPerCore}" ]]; then
        echo >&2 "[ERROR] Could not read CpuOptions for instance ${instanceId} (got coreCount='${coreCount}' threadsPerCore='${threadsPerCore}')"
        echo >&2 "[ERROR] Verify the instance ID is valid and the AWS region is correct (${AWS_DEFAULT_REGION})"
        exit 1
    fi

    if [[ "${nestedVirtStatus}" == "enabled" ]]; then
        : "Nested virtualization already enabled on ${nodeName} — skipping"
        return 0
    fi

    oc adm cordon "${nodeName}"

    oc adm drain "${nodeName}" \
        --ignore-daemonsets \
        --delete-emptydir-data \
        --force \
        --timeout=300s || true

    : "Stopping EC2 instance ${instanceId}"
    aws ec2 stop-instances --instance-ids "${instanceId}" > /dev/null
    aws ec2 wait instance-stopped --instance-ids "${instanceId}"
    : "Instance ${instanceId} stopped"

    : "Enabling nested virtualization on ${instanceId}"
    aws ec2 modify-instance-cpu-options \
        --instance-id  "${instanceId}" \
        --core-count   "${coreCount}" \
        --threads-per-core "${threadsPerCore}" \
        --nested-virtualization enabled > /dev/null

    # Retry start for transient InsufficientInstanceCapacity
    typeset -i attempt
    for (( attempt = 1; attempt <= 10; attempt++ )); do
        if aws ec2 start-instances --instance-ids "${instanceId}" > /dev/null 2>&1; then
            break
        fi
        : "Start attempt ${attempt}/10 failed (capacity) — retrying in 30s"
        sleep 30
    done

    aws ec2 wait instance-running --instance-ids "${instanceId}"
    : "Instance ${instanceId} running"

    oc wait --for=condition=Ready "node/${nodeName}" --timeout=600s

    oc adm uncordon "${nodeName}"

    : "Nested virtualization enabled on ${nodeName}"
}

# ─── Main ───────────────────────────────────────────────────────────────────

typeset instanceType="${ACM_SPOKE_WORKER_TYPE}"

: "Spoke worker instance type: ${instanceType}"
: "Spoke AWS region: ${AWS_DEFAULT_REGION}"

if IsMetalInstance "${instanceType}"; then
    : "Bare-metal instance (${instanceType}): native KVM — nested virtualization not required, skipping"
    exit 0
fi

if ! SupportsNestedVirt "${instanceType}"; then
    echo >&2 "[ERROR] Instance family '$(InstanceFamily "${instanceType}")' does not support nested virtualization."
    echo >&2 "[ERROR] Supported families: ${NESTED_VIRT_FAMILIES}"
    echo >&2 "[ERROR] Switch ACM_SPOKE_WORKER_TYPE to a supported family or use a *.metal instance."
    exit 1
fi

RequireAwsCliV2

: "Fetching spoke worker machines from Machine API"
typeset machinesJson machineCount
machinesJson="$(oc get machines -n openshift-machine-api \
    -l 'machine.openshift.io/cluster-api-machine-role=worker' \
    -o json)"
machineCount="$(jq '.items | length' <<< "${machinesJson}")"

if (( machineCount == 0 )); then
    echo >&2 "[ERROR] No worker machines found in spoke cluster — cannot enable nested virtualization"
    exit 1
fi

: "Found ${machineCount} worker machine(s) to process"

typeset -i i
for (( i = 0; i < machineCount; i++ )); do
    typeset instanceId nodeName
    instanceId="$(jq -r ".items[${i}].status.providerStatus.instanceId" <<< "${machinesJson}")"
    nodeName="$(jq -r ".items[${i}].status.nodeRef.name" <<< "${machinesJson}")"

    if [[ -z "${instanceId}" || "${instanceId}" == "null" ]]; then
        : "Machine index ${i} has no instance ID yet — skipping"
        continue
    fi

    # Guard: nodeRef may be absent if the node has not yet joined the cluster.
    # After acm-interop-p2p-cluster-install completes (Provisioned=True), all
    # nodes must be Ready, so a null nodeRef here indicates an unexpected state.
    if [[ -z "${nodeName}" || "${nodeName}" == "null" ]]; then
        echo >&2 "[ERROR] Machine ${instanceId} (index ${i}) has no nodeRef — spoke cluster may not be fully Ready"
        echo >&2 "[ERROR] Check that acm-interop-p2p-cluster-install completed successfully"
        exit 1
    fi

    EnableNestedVirtOnNode "${instanceId}" "${nodeName}"
done

: "Nested virtualization setup complete on all spoke workers"
