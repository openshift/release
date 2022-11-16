#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

REGION="${LEASED_RESOURCE}"

localzone_subnet_id=$(head -n 1 "${SHARED_DIR}/localzone_subnet_id")
localzone_az_name=$(head -n 1 "${SHARED_DIR}/localzone_az_name")
localzone_machineset="${SHARED_DIR}/manifest_localzone_machineset.yaml"

echo "Creating machineset manifests ... "
# PLACEHOLDER_INFRA_ID
# PLACEHOLDER_AMI_ID
cat <<EOF > ${localzone_machineset}
apiVersion: machine.openshift.io/v1beta1
kind: MachineSet
metadata:
  labels:
    machine.openshift.io/cluster-api-cluster: PLACEHOLDER_INFRA_ID
  name: PLACEHOLDER_INFRA_ID-edge-${localzone_az_name}
  namespace: openshift-machine-api
spec:
  replicas: ${LOCALZONE_WORKER_NUMBER}
  selector:
    matchLabels:
      machine.openshift.io/cluster-api-cluster: PLACEHOLDER_INFRA_ID
      machine.openshift.io/cluster-api-machineset: PLACEHOLDER_INFRA_ID-edge-${localzone_az_name}
  template:
    metadata:
      labels:
        machine.openshift.io/cluster-api-cluster: PLACEHOLDER_INFRA_ID
        machine.openshift.io/cluster-api-machine-role: edge
        machine.openshift.io/cluster-api-machine-type: edge
        machine.openshift.io/cluster-api-machineset: PLACEHOLDER_INFRA_ID-edge-${localzone_az_name}
    spec:
      metadata:
        labels:
          location: local-zone
          zone_group: ${localzone_az_name::-1}
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
          instanceType: ${LOCALZONE_INSTANCE_TYPE}
          kind: AWSMachineProviderConfig
          placement:
            availabilityZone: ${localzone_az_name}
            region: ${REGION}
          securityGroups:
            - filters:
              - name: tag:Name
                values:
                  - PLACEHOLDER_INFRA_ID-worker-sg
          subnet:
            id: ${localzone_subnet_id}
          tags:
            - name: kubernetes.io/cluster/PLACEHOLDER_INFRA_ID
              value: owned
          userDataSecret:
            name: worker-user-data
EOF

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

default_ingress="${SHARED_DIR}/manifest_localzone_cluster-ingress-default-ingresscontroller.yaml"
echo "Creating ingress manifests ... "
cat <<EOF > "${default_ingress}"
apiVersion: operator.openshift.io/v1
kind: IngressController
metadata:
  creationTimestamp: null
  name: default
  namespace: openshift-ingress-operator
spec:
  endpointPublishingStrategy:
    loadBalancer:
      scope: External
      providerParameters:
        type: AWS
        aws:
          type: NLB
    type: LoadBalancerService
EOF

cp "${localzone_machineset}" "${ARTIFACT_DIR}/"
cp "${default_ingress}" "${ARTIFACT_DIR}/"
