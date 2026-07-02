#!/bin/bash
set -euxo pipefail; shopt -s inherit_errexit

[ -s "${KUBECONFIG}" ]

function BenchmarkRunnerDebug () {
    sleep 2h
    oc get all -n benchmark-runner 2>&1 || true
    oc get events -n benchmark-runner --sort-by='.lastTimestamp' 2>&1 || true
    oc get vmi -n benchmark-runner -o yaml 2>&1 || true
    oc get dv -n benchmark-runner 2>&1 || true
    oc describe dv -n benchmark-runner 2>&1 || true
}

trap BenchmarkRunnerDebug ERR TERM EXIT

# Required by benchmark-runner
( set +x; KUBEADMIN_PASSWORD=$(cat "${SHARED_DIR}/kubeadmin-password") )
export KUBEADMIN_PASSWORD

( set +x; WINDOWS_URL=$(cat /var/run/secrets/windows-vm/S3-bucket-url) )
export WINDOWS_URL

# SCALE_NODES is required by benchmark-runner whenever SCALE is set
# If empty, fall back to all workers
( set +x; SCALE_NODES=$(oc get nodes -l kubevirt.io/schedulable=true -o jsonpath-as-json='{.items[*].metadata.name}' | jq -r '[ .[] | "'"'"'" + . + "'"'"'" ] | "[" + join(", ") + "]"'))
export SCALE_NODES

# CREATE_VMS_ONLY instructs benchmark-runner to provision the VM and exit
# without running a benchmark workload, leaving the VM running for chaos steps
export CREATE_VMS_ONLY=True

# Ensure benchmark-runner namespace exists (idempotent).
oc create namespace benchmark-runner --dry-run=client -o json --save-config | oc apply -f -

# Wait for KubeVirt readiness before attempting VM creation
if oc get daemonset virt-handler -n openshift-cnv --ignore-not-found -o name | grep -q .; then
    # Pre-flight: verify KubeVirt rollout is healthy before scheduling VMs
    oc rollout status daemonset/virt-handler -n openshift-cnv --timeout=5m
    oc rollout status deployment/virt-controller -n openshift-cnv --timeout=3m
    oc rollout status deployment/virt-api -n openshift-cnv --timeout=3m
    sleep 10
    typeset -i schedulableNodeCnt
    schedulableNodeCnt=$(
        oc get nodes \
            -l kubevirt.io/schedulable=true \
            -o jsonpath-as-json='{.items[*].metadata.name}' |
        jq 'length'
    )
    : "${schedulableNodeCnt} nodes with kubevirt.io/schedulable=true"
fi

# BUILD_VERSION is required by benchmark-runner; fall back to 1.0.0 on fetch failure
typeset buildVersion
buildVersion=$(
    curl -s "https://pypi.org/pypi/benchmark-runner/json" |
    python3 -c "import json,sys; print(json.load(sys.stdin)['info']['version'])" ||
    echo "1.0.0"
)
export BUILD_VERSION="${buildVersion}"

: "Creating Windows VM: workload=${WORKLOAD} scale=${SCALE} image=${WINDOWS_IMAGE}"
python3 /benchmark_runner/main/main.py

true
