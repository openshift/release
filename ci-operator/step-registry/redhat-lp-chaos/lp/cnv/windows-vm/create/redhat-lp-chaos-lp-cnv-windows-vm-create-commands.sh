#!/bin/bash
set -euxo pipefail; shopt -s inherit_errexit

[ -s "${KUBECONFIG}" ]

function BenchmarkRunnerDebug () {
    sleep 5m
    oc get all -n benchmark-runner 2>&1 || true
    oc get events -n benchmark-runner --sort-by='.lastTimestamp' 2>&1 || true
    oc get vmi -n benchmark-runner -o yaml 2>&1 || true
    oc get dv -n benchmark-runner 2>&1 || true
    oc describe dv -n benchmark-runner 2>&1 || true
}
# ERR omitted — double-fires with EXIT on failure
# TERM ($? may be 0 at signal time): always collect debug regardless
trap BenchmarkRunnerDebug TERM
trap 'exit_code=$?; [[ ${exit_code} -eq 0 ]] || BenchmarkRunnerDebug' EXIT

set +x  # avoid leaking secrets into CI logs
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

# odf-apply-storage-cluster exits when StorageCluster is Available but OSD pods
# and the CSI provisioner are still initialising — poll until the deployment appears
timeout 15m bash -c '
    until oc get deployment csi-rbdplugin-provisioner \
            -n openshift-storage --ignore-not-found -o name 2>/dev/null | grep -q .; do
        sleep 10
    done
'
oc rollout status deployment/csi-rbdplugin-provisioner \
    -n openshift-storage --timeout=30m

# CNV creates this storage class after detecting ODF — several minutes after
# StorageCluster Available; DataVolume imports fail without it
timeout 10m bash -c '
    until oc get storageclass ocs-storagecluster-ceph-rbd-virtualization \
            --ignore-not-found -o name 2>/dev/null | grep -q .; do
        sleep 10
    done
'

typeset buildVersion
buildVersion=$(
    curl -s "https://pypi.org/pypi/benchmark-runner/json" |
    python3 -c "import json,sys; print(json.load(sys.stdin)['info']['version'])" ||
    echo "1.0.0"
)
export BUILD_VERSION="${buildVersion}"

: "Creating Windows VM: workload=${WORKLOAD} scale=${SCALE} image=${WINDOWS_IMAGE}"
python3.14 /benchmark_runner/main/main.py
