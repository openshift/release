#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

REGION="${LEASED_RESOURCE}"
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"


MACHINE_ROLE="outposts"
if [[ ${EDGE_NODE_WORKER_ASSIGN_PUBLIC_IP} == "yes" ]]; then
  subnet_id=$(head -n 1 "${SHARED_DIR}/outpost_public_id")
else
  subnet_id=$(head -n 1 "${SHARED_DIR}/outpost_private_id")
fi

zone_name=$(head -n 1 "${SHARED_DIR}/outpost_availability_zone")
machineset_name_postfix=${RANDOM:0:2}

# keeping manifest_ prefix as this step can be used in manifest injection before installation 
edge_node_machineset="${SHARED_DIR}/manifest_edge_node_machineset.yaml"


if [[ ${EDGE_NODE_INSTANCE_TYPE} != "" ]]; then
  instance_type=${EDGE_NODE_INSTANCE_TYPE}
  echo "instance_type: using use provided ${EDGE_NODE_INSTANCE_TYPE}"
else
  instance_type=$(aws --region ${REGION} ec2 describe-instance-type-offerings --location availability-zone --filters Name=location,Values=${zone_name} | jq -r '.InstanceTypeOfferings[].InstanceType' | grep -E '^[rc][0-9][a-z]{0,1}\.2xlarge$' | sort | head -n 1)
  echo "instance_type: auto selected ${instance_type}"
fi

if [[ ${instance_type} == "" ]]; then
  echo "instance type is empty, exit now"
  exit 1
fi

echo "Creating machineset manifests ... "
# PLACEHOLDER_INFRA_ID
# PLACEHOLDER_AMI_ID
cat <<EOF > ${edge_node_machineset}
apiVersion: machine.openshift.io/v1beta1
kind: MachineSet
metadata:
  labels:
    machine.openshift.io/cluster-api-cluster: PLACEHOLDER_INFRA_ID
  name: PLACEHOLDER_INFRA_ID-${MACHINE_ROLE}-${zone_name}${machineset_name_postfix}
  namespace: openshift-machine-api
spec:
  replicas: ${EDGE_NODE_WORKER_NUMBER}
  selector:
    matchLabels:
      machine.openshift.io/cluster-api-cluster: PLACEHOLDER_INFRA_ID
      machine.openshift.io/cluster-api-machineset: PLACEHOLDER_INFRA_ID-${MACHINE_ROLE}-${zone_name}${machineset_name_postfix}
  template:
    metadata:
      labels:
        machine.openshift.io/cluster-api-cluster: PLACEHOLDER_INFRA_ID
        machine.openshift.io/cluster-api-machine-role: ${MACHINE_ROLE}
        machine.openshift.io/cluster-api-machine-type: ${MACHINE_ROLE}
        machine.openshift.io/cluster-api-machineset: PLACEHOLDER_INFRA_ID-${MACHINE_ROLE}-${zone_name}${machineset_name_postfix}
    spec:
      metadata: {}
      providerSpec:
        value:
          ami:
            id: PLACEHOLDER_AMI_ID
          apiVersion: machine.openshift.io/v1beta1
          blockDevices:
            - ebs:
                volumeSize: 120
                volumeType: gp2
          credentialsSecret:
            name: aws-cloud-credentials
          deviceIndex: 0
          iamInstanceProfile:
            id: PLACEHOLDER_INFRA_ID-worker-profile
          instanceType: ${instance_type}
          kind: AWSMachineProviderConfig
          placement:
            availabilityZone: ${zone_name}
            region: ${REGION}
          securityGroups:
            - filters:
              - name: tag:Name
                values:
                  - PLACEHOLDER_INFRA_ID-worker-sg
          subnet:
            id: ${subnet_id}
          tags:
            - name: kubernetes.io/cluster/PLACEHOLDER_INFRA_ID
              value: owned
          userDataSecret:
            name: worker-user-data
EOF

if [[ "${EDGE_NODE_WORKER_ASSIGN_PUBLIC_IP}" == "yes" ]]; then
  ip_patch=`mktemp`
  cat <<EOF > ${ip_patch}
spec:
  template:
    spec:
      providerSpec:
        value:
          publicIp: true
EOF
  yq-go m -x -i "${edge_node_machineset}" "${ip_patch}"
fi

if [[ "${EDGE_NODE_WORKER_SCHEDULABLE}" == "no" ]]; then
  schedulable_patch=`mktemp`
  cat <<EOF > ${schedulable_patch}
spec:
  template:
    spec:
      taints:
        - key: node-role.kubernetes.io/outposts
          effect: NoSchedule
EOF
  yq-go m -x -i "${edge_node_machineset}" "${schedulable_patch}"
fi

cp "${edge_node_machineset}" "${ARTIFACT_DIR}/"
