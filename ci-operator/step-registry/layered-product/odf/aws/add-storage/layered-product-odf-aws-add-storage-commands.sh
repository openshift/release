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

# create 6 machinesets for ocp storage on aws
cat <<'EOF' > add-worker-nodes.yaml
---
apiVersion: template.openshift.io/v1
kind: Template
metadata:
  name: add-node-template
  annotations:
    description: "adding 6 worker nodes"
    iconClass: "icon-redis"
    tags: "nodes,worker"
objects:
- apiVersion: machine.openshift.io/v1beta1
  kind: MachineSet
  metadata:
    labels:
      machine.openshift.io/cluster-api-cluster: "${CLUSTERID}"
      machine.openshift.io/cluster-api-machine-role: workerocs
      machine.openshift.io/cluster-api-machine-type: workerocs
    name:  "${CLUSTERID}-workerocs-${AZ}"
    namespace: openshift-machine-api
  spec:
    replicas: "${{REPLICA_COUNT}}"
    selector:
      matchLabels:
        machine.openshift.io/cluster-api-cluster: "${CLUSTERID}"
        machine.openshift.io/cluster-api-machineset: "${CLUSTERID}-workerocs-${AZ}"
    template:
      metadata:
        creationTimestamp: null
        labels:
          machine.openshift.io/cluster-api-cluster: "${CLUSTERID}"
          machine.openshift.io/cluster-api-machine-role: workerocs
          machine.openshift.io/cluster-api-machine-type: workerocs
          machine.openshift.io/cluster-api-machineset: "${CLUSTERID}-workerocs-${AZ}"
      spec:
        metadata:
          creationTimestamp: null
          labels:
            cluster.ocs.openshift.io/openshift-storage: ""
            node-role.kubernetes.io/worker: ""
        providerSpec:
          value:
            ami:
              id: ami-0fe05b1aa8dacfa90
            apiVersion: awsproviderconfig.openshift.io/v1beta1
            blockDevices:
            - ebs:
                iops: 0
                volumeSize: 100
                volumeType: "${VOLUME_TYPE}"
            credentialsSecret:
              name: aws-cloud-credentials
            deviceIndex: 0
            iamInstanceProfile:
              id: "${CLUSTERID}-worker-profile" 
            instanceType: ${INSTANCE_TYPE}
            kind: AWSMachineProviderConfig
            metadata:
              creationTimestamp: null
            placement:
              availabilityZone: ${AZ}
              region: ${REGION}
            publicIp: null
            securityGroups:
            - filters:
              - name: tag:Name
                values:
                -  "${CLUSTERID}-worker-sg" 
            subnet:
              filters:
              - name: tag:Name
                values:
                - "${CLUSTERID}-private-${AZ}"
            tags:
            - name: "kubernetes.io/cluster/${CLUSTERID}"
              value: owned
            userDataSecret:
              name: worker-user-data
        versions:
          kubelet: ""
parameters:
- description: cluter id of cluter 
  name: CLUSTERID
  required: true 
- description: Available zone of cluter 
  name: AZ
  required: true 
- description: region of cluter 
  name: REGION
  required: true 
- description: volume type of cluter 
  name: VOLUME_TYPE
  value: gp3
  required: true 
- description: the number of replica 
  name: REPLICA_COUNT
  value: "7"
  required: true 
- description: instance type of cluter 
  name: INSTANCE_TYPE
  value: m6a.2xlarge
  required: true 
---
EOF

chmond 777 add-worker-nodes.yaml
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

oc process -f add-worker-nodes.yaml -p CLUSTERID=$CLUSTERID -p AZ=$AZ -p REGION=$REGION -p VOLUME_TYPE=$VOLUME_TYPE -p INSTANCE_TYPE=$INSTANCE_TYPE | oc apply -f - -n openshift-machine-api

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

