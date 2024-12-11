#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x
cat /etc/os-release

oc config view
oc projects

# Disk cleaning
for worker in $(oc get node --no-headers -l node-role.kubernetes.io/worker --output custom-columns="NAME:.status.addresses[0].address"); do
  for disk in {0..7}; do
    ssh -t -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null -J root@${bastion} core@${worker} "sudo sgdisk --zap-all /dev/nvme${disk}n1; sudo wipefs -a /dev/nvme${disk}n1"
  done
done

# Install the LSO operator
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-local-storage
spec: {}
EOF

cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: local-operator-group
  namespace: openshift-local-storage
spec:
  targetNamespaces:
  - openshift-local-storage
EOF

cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: local-storage-operator
  namespace: openshift-local-storage
spec:
  channel: "stable"
  installPlanApproval: Automatic
  name: local-storage-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

# Wait for the operator to be ready
until [ "$(kubectl get csv -n openshift-local-storage | grep local-storage-operator > /dev/null; echo $?)" == 0 ];
  do echo "Waiting for LSO operator"
  sleep 5
done
kubectl wait --for jsonpath='{.status.phase}'=Succeeded --timeout=10m -n openshift-local-storage "$(kubectl get csv -n openshift-local-storage -oname)"
sleep 60

# Node labeling
for i in $(oc get node -l node-role.kubernetes.io/worker -oname | grep -oP "^node/\K.*"); do
  oc label node $i cluster.ocs.openshift.io/openshift-storage='' --overwrite
done

# Auto Discovering Devices and creating Persistent Volumes

cat <<EOF | oc apply -f -
apiVersion: local.storage.openshift.io/v1alpha1
kind: LocalVolumeDiscovery
metadata:
  name: auto-discover-devices
  namespace: openshift-local-storage
spec:
  nodeSelector:
    nodeSelectorTerms:
      - matchExpressions:
        - key: cluster.ocs.openshift.io/openshift-storage
          operator: Exists
EOF

cat <<EOF | oc apply -f -
apiVersion: local.storage.openshift.io/v1alpha1
kind: LocalVolumeSet
metadata:
  name: local-block
  namespace: openshift-local-storage
spec:
  nodeSelector:
    nodeSelectorTerms:
      - matchExpressions:
          - key: cluster.ocs.openshift.io/openshift-storage
            operator: In
            values:
              - ""
  storageClassName: localblock
  volumeMode: Block
  fstype: ext4
  maxDeviceCount: ${DEVICES}
  deviceInclusionSpec:
    deviceTypes:
    - disk
    deviceMechanicalProperties:
    - NonRotational
EOF
