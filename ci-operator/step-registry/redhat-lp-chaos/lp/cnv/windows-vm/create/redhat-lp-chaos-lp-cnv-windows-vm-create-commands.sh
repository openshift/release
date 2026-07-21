#!/bin/bash
set -euxo pipefail; shopt -s inherit_errexit

[ -s "${KUBECONFIG}" ]

# Flatten KUBECONFIG to embed certs inline — required by benchmark-runner Python client.
oc config view --flatten > /tmp/config
export KUBECONFIG=/tmp/config

typeset benchmarkNs='benchmark-runner'

function BenchmarkRunnerDebug () {
    oc get all -n "${benchmarkNs}" 2>&1 || true
    oc get events -n "${benchmarkNs}" --sort-by='.lastTimestamp' 2>&1 || true
    oc get vmi -n "${benchmarkNs}" -o yaml 2>&1 || true
    oc get dv -n "${benchmarkNs}" 2>&1 || true
    oc describe dv -n "${benchmarkNs}" 2>&1 || true
    oc describe pod -n "${benchmarkNs}" -l cdi.kubevirt.io=importer 2>&1 || true
    oc logs -n "${benchmarkNs}" -l cdi.kubevirt.io=importer --tail=200 --prefix 2>&1 || true
    oc get deployment -n openshift-storage 2>&1 || true
    oc get storageclass 2>&1 || true
    oc describe pvc windows-clone-dv -n "${benchmarkNs}" 2>&1 || true
    oc get storageprofile gp3-csi -o yaml 2>&1 || true
    true
}
typeset isTermReceived=false
function TermHandler () { isTermReceived=true; BenchmarkRunnerDebug; }
function OnExit () {
    typeset -i exitCode=$?
    # Skip if TermHandler already ran BenchmarkRunnerDebug
    ${isTermReceived} && return
    ((exitCode == 0)) || BenchmarkRunnerDebug
    true
}
# ERR omitted — double-fires with EXIT on failure
trap TermHandler TERM
trap OnExit EXIT

typeset clusterRegion
clusterRegion="${LEASED_RESOURCE:-us-east-1}"

typeset windowsUrl scaleNodes
case "${clusterRegion}" in
    us-west-*)
        windowsUrl='https://ieng--vm-image--windows--us-west-2.s3.us-west-2.amazonaws.com/win10/windows10.qcow2'
        ;;
    *)
        windowsUrl='https://ieng--vm-image--windows--us-east-1.s3.us-east-1.amazonaws.com/win10/windows10.qcow2'
        ;;
esac
scaleNodes=$(oc get nodes -l kubevirt.io/schedulable=true -o jsonpath-as-json='{.items[*].metadata.name}' | jq -r '[ .[] | "'"'"'" + . + "'"'"'" ] | "[" + join(", ") + "]"')

set +x
export KUBEADMIN_PASSWORD="$(cat "${SHARED_DIR}/kubeadmin-password")"
set -x

oc create namespace "${benchmarkNs}" --dry-run=client -o json --save-config | oc apply -f -

typeset s3CredSecretName='lp-chaos--vm-img--windows'
oc -n "${benchmarkNs}" create \
    secret generic "${s3CredSecretName}" \
    --type Opaque \
    --from-file accessKeyId=<(
        set +x
        printf '%s' "$(cat /var/run/secrets/windows-vm/AWS__S3__u-ieng--s3--vm-img--windows--ro__AccKeyId)"
    ) \
    --from-file secretKey=<(
        set +x
        printf '%s' "$(cat /var/run/secrets/windows-vm/AWS__S3__u-ieng--s3--vm-img--windows--ro__AccKeySecret)"
    ) \
    --dry-run=client -o yaml --save-config | oc apply -f -

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

typeset buildVersion
buildVersion=$(
    curl -s "https://pypi.org/pypi/benchmark-runner/json" |
    python3.14 -c "import json,sys; print(json.load(sys.stdin)['info']['version'])" ||
    echo "1.0.0"
)

typeset runType="${RUN_TYPE:-test_ci}"

: "Creating Windows VM: workload=${WORKLOAD} scale=${SCALE} image=${WINDOWS_IMAGE}"
CREATE_VMS_ONLY=True \
    DELETE_ALL=False \
    RUN_STRATEGY=True \
    CDI_SOURCE_TYPE=s3 \
    CDI_SOURCE_S3_CRED="${s3CredSecretName}" \
    WINDOWS_URL="${windowsUrl}" \
    SCALE_NODES="${scaleNodes}" \
    BUILD_VERSION="${buildVersion}" \
    RUN_TYPE="${runType}" \
    python3.14 /benchmark_runner/main/main.py

true
