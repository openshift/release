#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x
cat /etc/os-release

SRIOV_NUM_VFS=$(cat ${CLUSTER_PROFILE_DIR}/config | jq ".sriov_num_vfs")
SRIOV_PF_NAME=$(cat ${CLUSTER_PROFILE_DIR}/sriov_pf_name)
SRIOV_KERNEL_VFS_RANGE=$(cat ${CLUSTER_PROFILE_DIR}/sriov_kernel_vfs_range)
SRIOV_DPDK_VFS_RANGE=$(cat ${CLUSTER_PROFILE_DIR}/sriov_dpdk_vfs_range)


oc config view
oc projects

# Install the SRIOV operator
cat << EOF| oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-sriov-network-operator
  annotations:
    workload.openshift.io/allowed: management
EOF

cat << EOF| oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: sriov-network-operators
  namespace: openshift-sriov-network-operator
spec:
  targetNamespaces:
  - openshift-sriov-network-operator
EOF

cat << EOF| oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: sriov-network-operator-subscription
  namespace: openshift-sriov-network-operator
spec:
  channel: stable
  name: sriov-network-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

# Wait for the operator to be ready
until [ "$(kubectl get csv -n openshift-sriov-network-operator | grep sriov-network-operator > /dev/null; echo $?)" == 0 ];
  do echo "Waiting for SRIOV operator"
  sleep 5
done
kubectl wait --for jsonpath='{.status.phase}'=Succeeded --timeout=10m -n openshift-sriov-network-operator "$(kubectl get csv -n openshift-sriov-network-operator -oname | grep sriov)"
sleep 60

{
cat << EOF| oc apply -f -
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovOperatorConfig
metadata:
  name: default
  namespace: openshift-sriov-network-operator
spec:
  disableDrain: false
  enableInjector: true
  enableOperatorWebhook: true
  logLevel: 2
EOF
} || echo Failed to apply SriovOperatorConfig

sleep 180

# Create the SRIOV network policy for Kernel and DPDK VFs

cat << EOF| oc apply -f -
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovNetworkNodePolicy
metadata:
  name: ${SRIOV_POLICY_NAME_KERNEL_VFS}
  namespace: openshift-sriov-network-operator
spec:
  deviceType: netdevice
  nicSelector:
    pfNames:
     - ${SRIOV_PF_NAME}#{KERNEL_VFS_RANGE}
  mtu: ${SRIOV_MTU}
  nodeSelector:
    ${SRIOV_NODE_SELECTOR}: ""
  numVfs: ${SRIOV_NUM_VFS}
  resourceName: ${SRIOV_RESOURCE_NAME_KERNEL_VFS}
EOF

cat << EOF| oc apply -f -
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovNetworkNodePolicy
metadata:
  name: ${SRIOV_POLICY_NAME_DPDK_VFS}
  namespace: openshift-sriov-network-operator
spec:
  deviceType: vfio-pci
  nicSelector:
    pfNames:
     - ${SRIOV_PF_NAME}#{DPDK_VFS_RANGE}
  mtu: ${SRIOV_MTU}
  nodeSelector:
    ${SRIOV_NODE_SELECTOR}: ""
  numVfs: ${SRIOV_NUM_VFS}
  resourceName: ${SRIOV_RESOURCE_NAME_DPDK_VFS}
EOF
