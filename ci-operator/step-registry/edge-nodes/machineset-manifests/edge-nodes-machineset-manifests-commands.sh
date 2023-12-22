#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

REGION="${LEASED_RESOURCE}"
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

edge_zone_subnet_id=$(head -n 1 "${SHARED_DIR}/edge_zone_subnet_id")
edge_zone_name=$(head -n 1 "${SHARED_DIR}/edge-zone-name.txt")
edge_zone_group_name=$(head -n 1 "${SHARED_DIR}"/edge-zone-group-name.txt)

# keeping manifest_ prefix as this step can be used in manifest injection before installation 
localzone_machineset="${SHARED_DIR}/manifest_localzone_machineset.yaml"


if [[ ${LOCALZONE_INSTANCE_TYPE} != "" ]]; then
  instance_type=${LOCALZONE_INSTANCE_TYPE}
  echo "instance_type: using use provided ${LOCALZONE_INSTANCE_TYPE}"
else
  instance_type=$(aws --region ${REGION} ec2 describe-instance-type-offerings --location availability-zone --filters Name=location,Values=${edge_zone_name} | jq -r '.InstanceTypeOfferings[].InstanceType' | grep -E '^[rc][0-9][a-z]{0,1}\.2xlarge$' | sort | head -n 1)
  echo "instance_type: auto selected ${instance_type}"
fi

if [[ ${instance_type} == "" ]]; then
  echo "instance type is empty, exit now"
  exit 1
fi

echo "Creating machineset manifests ... "
# PLACEHOLDER_INFRA_ID
# PLACEHOLDER_AMI_ID
cat <<EOF > ${localzone_machineset}
apiVersion: machine.openshift.io/v1beta1
kind: MachineSet
metadata:
  labels:
    machine.openshift.io/cluster-api-cluster: PLACEHOLDER_INFRA_ID
  name: PLACEHOLDER_INFRA_ID-edge-${edge_zone_name}
  namespace: openshift-machine-api
spec:
  replicas: ${LOCALZONE_WORKER_NUMBER}
  selector:
    matchLabels:
      machine.openshift.io/cluster-api-cluster: PLACEHOLDER_INFRA_ID
      machine.openshift.io/cluster-api-machineset: PLACEHOLDER_INFRA_ID-edge-${edge_zone_name}
  template:
    metadata:
      labels:
        machine.openshift.io/cluster-api-cluster: PLACEHOLDER_INFRA_ID
        machine.openshift.io/cluster-api-machine-role: edge
        machine.openshift.io/cluster-api-machine-type: edge
        machine.openshift.io/cluster-api-machineset: PLACEHOLDER_INFRA_ID-edge-${edge_zone_name}
    spec:
      metadata:
        labels:
          machine.openshift.io/zone-type: ${EDGE_ZONE_TYPE}
          machine.openshift.io/zone-group: ${edge_zone_group_name}
          node-role.kubernetes.io/edge: ""
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
            availabilityZone: ${edge_zone_name}
            region: ${REGION}
          securityGroups:
            - filters:
              - name: tag:Name
                values:
                  - PLACEHOLDER_INFRA_ID-worker-sg
          subnet:
            id: ${edge_zone_subnet_id}
          tags:
            - name: kubernetes.io/cluster/PLACEHOLDER_INFRA_ID
              value: owned
          userDataSecret:
            name: worker-user-data
EOF

if [[ "${LOCALZONE_WORKER_ASSIGN_PUBLIC_IP}" == "yes" ]]; then
  ip_patch=`mktemp`
  cat <<EOF > ${ip_patch}
spec:
  template:
    spec:
      providerSpec:
        value:
          publicIp: true
EOF
  yq-go m -x -i "${localzone_machineset}" "${ip_patch}"
fi

if [[ "${LOCALZONE_WORKER_SCHEDULABLE}" == "no" ]]; then
  schedulable_patch=`mktemp`
  cat <<EOF > ${schedulable_patch}
spec:
  template:
    spec:
      taints:
        - key: node-role.kubernetes.io/edge
          effect: NoSchedule
EOF
  yq-go m -x -i "${localzone_machineset}" "${schedulable_patch}"
fi
cp "${localzone_machineset}" "${ARTIFACT_DIR}/"
