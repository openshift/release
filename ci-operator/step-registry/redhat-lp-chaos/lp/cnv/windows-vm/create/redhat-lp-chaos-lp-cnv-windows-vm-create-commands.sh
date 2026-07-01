#!/bin/bash
set -euxo pipefail; shopt -s inherit_errexit

[ -s "${KUBECONFIG}" ]

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

# CREATE_VMS_ONLY instructs benchmark-runner to provision the VM and exit
# without running a benchmark workload, leaving the VM running for chaos steps
export CREATE_VMS_ONLY=True

# BUILD_VERSION is required by benchmark-runner; fall back to 1.0.0 on fetch failure
typeset buildVersion
buildVersion=$(
    curl -s "https://pypi.org/pypi/benchmark-runner/json" |
    python3 -c "import json,sys; print(json.load(sys.stdin)['info']['version'])" ||
    echo "1.0.0"
)
export BUILD_VERSION="${buildVersion}"

( set +x; WINDOWS_URL=$(cat /var/run/secrets/windows-vm/S3-bucket-url) )
export WINDOWS_URL

# benchmark-runner's Windows templates default to ODF storage (ocs-storagecluster-ceph-rbd-virtualization)
# This cluster uses AWS EBS only (gp3-csi), so patch the templates to use a compatible storage class
oc apply -f - <<'SCEOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3-csi-immediate
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
reclaimPolicy: Delete
allowVolumeExpansion: true
volumeBindingMode: Immediate
SCEOF

typeset brTmplDir
brTmplDir="$(python3 -c "import benchmark_runner, os; \
print(os.path.dirname(benchmark_runner.__file__))")/common/template_operations/templates/windows/internal_data"
sed -i 's/storageClassName: ocs-storagecluster-ceph-rbd-virtualization/storageClassName: gp3-csi-immediate/' \
    "${brTmplDir}/windows_dv_template.yaml" \
    "${brTmplDir}/windows_vm_template.yaml"
sed -i 's/ReadWriteMany/ReadWriteOnce/' \
    "${brTmplDir}/windows_dv_template.yaml" \
    "${brTmplDir}/windows_vm_template.yaml"
sed -i '/evictionStrategy: LiveMigrate/d' \
    "${brTmplDir}/windows_vm_template.yaml"

# SCALE_NODES is required by benchmark-runner whenever SCALE is set.
# Derive from KubeVirt-schedulable nodes, which are confirmed present by the pre-flight check above.
typeset scaleNodes
scaleNodes=$(
    oc get nodes -l kubevirt.io/schedulable=true \
        -o jsonpath='{.items[*].metadata.name}' |
    tr ' ' ','
)
export SCALE_NODES="${scaleNodes}"

function BenchmarkRunnerDebug () {
    oc get all -n benchmark-runner 2>&1 || true
    oc get events -n benchmark-runner --sort-by='.lastTimestamp' 2>&1 || true
    oc get vmi -n benchmark-runner -o yaml 2>&1 || true
    oc get dv -n benchmark-runner 2>&1 || true
    oc describe dv -n benchmark-runner 2>&1 || true
    true
}

: "Creating Windows VM: workload=${WORKLOAD} scale=${SCALE} image=${WINDOWS_IMAGE}"
trap BenchmarkRunnerDebug ERR
python3.14 /benchmark_runner/main/main.py

true
