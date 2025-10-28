# Post Upgrade Checks

## What this step does ?

1. Check if the VM exists 

2. If VM exists, then check if VM is running

3. Execute SSH checks to make sure VM is accesible and running

4. Check HyperConverged operator status


## Requirements

1. Container Image with virtctl, sshpass, kubectl available

2. Spoke kubeconfig available in location "<SHARED_DIR/managed-cluster-kubeconfig>"

# Configuration
VM_NAME="vmi-ephemeral"
NAMESPACE="default"
CSV_NAMESPACE="openshift-cnv"
TIMEOUT="300"
WORK_DIR="/tmp/kubevirt-test-$$"
KUBECTL_CMD="kubectl"
VIRTCTL_CMD="virtctl"
MODE="pre-upgrade"
VM_IMAGE="quay.io/kubevirt/cirros-container-disk-demo:devel"
