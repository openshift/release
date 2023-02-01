#!/bin/bash
set -x
set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG=${SHARED_DIR}/kubeconfig

# create the policies namespace
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-storage
EOF

oc label namespace openshift-storage openshift.io/cluster-monitoring=true

#THis is for ACS and QUAY
oc scale --replicas=7 machineset "$(oc get machineset -n  openshift-machine-api -o jsonpath='{.items[0].metadata.name}')" -n openshift-machine-api

# create 12 machinesets for ocp storage on aws


CLUSTERID=$(oc get machineset -n openshift-machine-api -o jsonpath='{.items[0].metadata.labels.machine\.openshift\.io/cluster-api-cluster}')
AZ=$(oc get machineset -n openshift-machine-api -o jsonpath='{.items[0].spec.template.spec.providerSpec.value.placement.availabilityZone}')
REGION=$(oc get machineset -n openshift-machine-api -o jsonpath='{.items[0].spec.template.spec.providerSpec.value.placement.region}')
VOLUME_TYPE=$(oc get machineset -n  openshift-machine-api -o jsonpath='{.items[0].spec.template.spec.providerSpec.value.blockDevices[0].ebs.volumeType}')
INSTANCE_TYPE=$( oc get machineset -n  openshift-machine-api -o jsonpath='{.items[0].spec.template.spec.providerSpec.value.instanceType}')
echo $AZ
echo $REGION
echo $CLUSTERID
echo $VOLUME_TYPE
echo $INSTANCE_TYPE


oc apply -f - <<EOF 
apiVersion: machine.openshift.io/v1beta1
kind: MachineSet
metadata:
  labels:
    machine.openshift.io/cluster-api-cluster: $CLUSTERID
    machine.openshift.io/cluster-api-machine-role: workerocs
    machine.openshift.io/cluster-api-machine-type: workerocs
  name: $CLUSTERID-workerocs-$AZ
  namespace: openshift-machine-api
spec:
  replicas: 12
  selector:
    matchLabels:
      machine.openshift.io/cluster-api-cluster: $CLUSTERID
      machine.openshift.io/cluster-api-machineset: $CLUSTERID-workerocs-$AZ
  template:
    metadata:
      creationTimestamp: null
      labels:
        machine.openshift.io/cluster-api-cluster: $CLUSTERID
        machine.openshift.io/cluster-api-machine-role: workerocs
        machine.openshift.io/cluster-api-machine-type: workerocs
        machine.openshift.io/cluster-api-machineset: $CLUSTERID-workerocs-$AZ
    spec:
      metadata:
        creationTimestamp: null
        labels:
          cluster.ocs.openshift.io/openshift-storage: ""
          node-role.kubernetes.io/worker: ""
      providerSpec:
        value:
          ami:
            id: ami-0cd5c6a0f8bb3c33d
          apiVersion: awsproviderconfig.openshift.io/v1beta1
          blockDevices:
          - ebs:
              iops: 0
              volumeSize: 120
              volumeType: $VOLUME_TYPE
          credentialsSecret:
            name: aws-cloud-credentials
          deviceIndex: 0
          iamInstanceProfile:
            id: $CLUSTERID-worker-profile
          instanceType: $INSTANCE_TYPE
          kind: AWSMachineProviderConfig
          metadata:
            creationTimestamp: null
          placement:
            availabilityZone: $AZ
            region: $REGION
          publicIp: null
          securityGroups:
          - filters:
            - name: tag:Name
              values:
              - $CLUSTERID-worker-sg
          subnet:
            filters:
            - name: tag:Name
              values:
              - $CLUSTERID-private-$AZ
          tags:
          - name: kubernetes.io/cluster/$CLUSTERID
            value: owned
          userDataSecret:
            name: worker-user-data
      versions:
        kubelet: ""
EOF
echo "machineset applied..."

# wait for storage nodes to be ready
RETRIES=30
for i in $(seq "${RETRIES}"); do
  if [[ $(oc get nodes -l cluster.ocs.openshift.io/openshift-storage= | grep Ready) ]]; then
    echo "storage worker nodes are up is Running"
    break
  else
    echo "Try ${i}/${RETRIES}: Storage nodes are not ready yet. Checking again in 30 seconds"
    sleep 30
  fi
done

echo "storage nodes are ready"
