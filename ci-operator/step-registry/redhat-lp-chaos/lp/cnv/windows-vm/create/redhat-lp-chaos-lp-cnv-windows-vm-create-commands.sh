#!/bin/bash
set -euxo pipefail; shopt -s inherit_errexit

[ -s "${KUBECONFIG}" ]

# Flatten KUBECONFIG to embed certs inline — required by benchmark-runner Python client.
oc config view --flatten > /tmp/config
export KUBECONFIG=/tmp/config

function BenchmarkRunnerDebug () {
    oc get all -n benchmark-runner 2>&1 || true
    oc get events -n benchmark-runner --sort-by='.lastTimestamp' 2>&1 || true
    oc get vmi -n benchmark-runner -o yaml 2>&1 || true
    oc get dv -n benchmark-runner 2>&1 || true
    oc describe dv -n benchmark-runner 2>&1 || true
    oc describe pod -n benchmark-runner -l cdi.kubevirt.io=importer 2>&1 || true
    oc logs -n benchmark-runner -l cdi.kubevirt.io=importer --tail=200 --prefix 2>&1 || true
    oc get deployment -n openshift-storage 2>&1 || true
    oc get storageclass 2>&1 || true
}
_TERM_RECEIVED=false
function _term_handler () { _TERM_RECEIVED=true; BenchmarkRunnerDebug; }
function _on_exit () {
    local _rc=$?
    # Skip if TERM handler already ran BenchmarkRunnerDebug
    ${_TERM_RECEIVED} && return
    [[ ${_rc} -eq 0 ]] || BenchmarkRunnerDebug
}
# ERR omitted — double-fires with EXIT on failure
trap _term_handler TERM
trap _on_exit EXIT

set +x
KUBEADMIN_PASSWORD=$(cat "${SHARED_DIR}/kubeadmin-password")
WINDOWS_URL=$(cat /var/run/secrets/windows-vm/S3-bucket-url)
SCALE_NODES=$(oc get nodes -l kubevirt.io/schedulable=true -o jsonpath-as-json='{.items[*].metadata.name}' | jq -r '[ .[] | "'"'"'" + . + "'"'"'" ] | "[" + join(", ") + "]"')
set -x
export KUBEADMIN_PASSWORD WINDOWS_URL SCALE_NODES

export CREATE_VMS_ONLY=True

oc create namespace benchmark-runner --dry-run=client -o json --save-config | oc apply -f -

if oc get daemonset virt-handler -n openshift-cnv --ignore-not-found -o name | grep -q .; then
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

# ODF 4.21 renamed csi-rbdplugin-provisioner to the FQDN form; created before
# StorageCluster Available so rollout status completes immediately
oc rollout status deployment/openshift-storage.rbd.csi.ceph.com-ctrlplugin \
    -n openshift-storage --timeout=10m

oc get storageclass ocs-storagecluster-ceph-rbd-virtualization -o name

buildVersion=$(
    curl -s "https://pypi.org/pypi/benchmark-runner/json" |
    python3.14 -c "import json,sys; print(json.load(sys.stdin)['info']['version'])" ||
    echo "1.0.0"
)
export BUILD_VERSION="${buildVersion}"

export RUN_TYPE="${RUN_TYPE:-test_ci}"

: "Creating Windows VM: workload=${WORKLOAD} scale=${SCALE} image=${WINDOWS_IMAGE}"
python3.14 /benchmark_runner/main/main.py
