#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

REGION="${LEASED_RESOURCE}"
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

edge_zone_subnet_id=$(head -n 1 "${SHARED_DIR}/edge_zone_subnet_id")
edge_zone_name=$(head -n 1 "${SHARED_DIR}/edge-zone-names.txt")
source "${SHARED_DIR}/edge-zone-groups.env"
# shellcheck disable=SC2154
edge_zone_group_name="${edge_zone_groups[$edge_zone_name]}"

# keeping manifest_ prefix as this step can be used in manifest injection before installation 
edge_node_machineset="${SHARED_DIR}/manifest_edge_node_machineset.yaml"

echo "RELEASE_IMAGE_LATEST: ${RELEASE_IMAGE_LATEST}"
echo "RELEASE_IMAGE_LATEST_FROM_BUILD_FARM: ${RELEASE_IMAGE_LATEST_FROM_BUILD_FARM}"
export HOME="${HOME:-/tmp/home}"
export XDG_RUNTIME_DIR="${HOME}/run"
export REGISTRY_AUTH_PREFERENCE=podman # TODO: remove later, used for migrating oc from docker to podman
mkdir -p "${XDG_RUNTIME_DIR}"
# After cluster is set up, ci-operator make KUBECONFIG pointing to the installed cluster,
# to make "oc registry login" interact with the build farm, set KUBECONFIG to empty,
# so that the credentials of the build farm registry can be saved in docker client config file.
# A direct connection is required while communicating with build-farm, instead of through proxy
KUBECONFIG="" oc --loglevel=8 registry login
ocp_version=$(oc adm release info ${RELEASE_IMAGE_LATEST_FROM_BUILD_FARM} --output=json | jq -r '.metadata.version' | cut -d. -f 1,2)
echo "OCP Version: $ocp_version"
ocp_major_version=$( echo "${ocp_version}" | awk --field-separator=. '{print $1}' )
ocp_minor_version=$( echo "${ocp_version}" | awk --field-separator=. '{print $2}' )

if [[ ${EDGE_NODE_INSTANCE_TYPE} != "" ]]; then
  instance_type=${EDGE_NODE_INSTANCE_TYPE}
  echo "instance_type: using use provided ${EDGE_NODE_INSTANCE_TYPE}"
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
cat <<EOF > ${edge_node_machineset}
apiVersion: machine.openshift.io/v1beta1
kind: MachineSet
metadata:
  labels:
    machine.openshift.io/cluster-api-cluster: PLACEHOLDER_INFRA_ID
  name: PLACEHOLDER_INFRA_ID-edge-${edge_zone_name}
  namespace: openshift-machine-api
spec:
  replicas: ${EDGE_NODE_WORKER_NUMBER}
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
          machine.openshift.io/zone-type: ${EDGE_ZONE_TYPES}
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
          subnet:
            id: ${edge_zone_subnet_id}
          tags:
            - name: kubernetes.io/cluster/PLACEHOLDER_INFRA_ID
              value: owned
          userDataSecret:
            name: worker-user-data
EOF

# SG group patch
sg_patch=`mktemp`
if (( ocp_minor_version >= 16 && ocp_major_version == 4 )); then
  # CAPI
  cat <<EOF > ${sg_patch}
spec:
  template:
    spec:
      providerSpec:
        value:
          securityGroups:
            - filters:
              - name: tag:Name
                values:
                  - PLACEHOLDER_INFRA_ID-node
            - filters:
              - name: tag:Name
                values:
                  - PLACEHOLDER_INFRA_ID-lb
EOF
else
  # Terraform
  cat <<EOF > ${sg_patch}
spec:
  template:
    spec:
      providerSpec:
        value:
          securityGroups:
            - filters:
              - name: tag:Name
                values:
                  - PLACEHOLDER_INFRA_ID-worker-sg
EOF
fi

yq-go m -x -i "${edge_node_machineset}" "${sg_patch}"

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
        - key: node-role.kubernetes.io/edge
          effect: NoSchedule
EOF
  yq-go m -x -i "${edge_node_machineset}" "${schedulable_patch}"
fi
cp "${edge_node_machineset}" "${ARTIFACT_DIR}/"
