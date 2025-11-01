# Pre Upgrade checks

## What this step does ?

1. Creates a VM manifest file and deploy a VM 

2. Run checks to make sure VM deployed correctly

3. Execute SSH checks to make sure VM is accesible and running



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
