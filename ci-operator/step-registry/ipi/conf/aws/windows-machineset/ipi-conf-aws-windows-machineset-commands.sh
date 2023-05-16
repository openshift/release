#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Wait for WMCO to be up and running
oc wait deployment windows-machine-config-operator -n openshift-windows-machine-config-operator --for condition=Available=True --timeout=5m

# Ensure userDataSecret exist, fail otherwise. The userDataSecret is required and contains specific information to
# customize the machine at first boot. For instance, the authorized public key for the SSH server to accept
# incoming connections, firewall rules, etc.
timeout 3m bash -c 'until oc -n openshift-machine-api get secret "${WINDOWS_USER_DATA_SECRET}" 2> /dev/null; do echo -n "." && sleep 15; done'

# config AWS profile
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
export REGION="${LEASED_RESOURCE}"

# get most recent AMI ID for Windows Server
ami_id=$(aws ec2 describe-images \
  --region "${REGION}" \
  --filters "Name=name,Values=${WINDOWS_OS_ID}*" "Name=is-public,Values=true" \
  --query "reverse(sort_by(Images, &CreationDate))[*].{name: Name, id: ImageId}" \
  --output json | jq -r '.[0].id')
if [ -z "$ami_id" ]; then
      echo "cannot find AMI ID for Windows Server"
      exit 1
fi

# Get machineset name to generate a generic template
ref_machineset_name=$(oc -n openshift-machine-api get -o 'jsonpath={range .items[*]}{.metadata.name}{"\n"}{end}' machinesets | grep worker | head -n1)

# Replace machine name `worker` with `winworker`
winworker_machineset_name="${ref_machineset_name/worker/winworker}"

export ref_machineset_name winworker_machineset_name ami_id
# Get a templated json from worker machineset, apply Windows specific settings
# and pass it to `oc` to create a new machineset
oc get machineset "${ref_machineset_name}" -n openshift-machine-api -o json |
  jq --arg winworker_machineset_name "${winworker_machineset_name}" \
     --arg ami_id "${ami_id}" \
     --arg instance_type "${WINDOWS_NODE_TYPE}" \
     --arg user_data_secret "${WINDOWS_USER_DATA_SECRET}" \
     '
      .metadata.name = $winworker_machineset_name |
      .spec.replicas = 0 |
      .spec.selector.matchLabels."machine.openshift.io/cluster-api-machineset" = $winworker_machineset_name |
      .spec.template.metadata.labels."machine.openshift.io/cluster-api-machineset" = $winworker_machineset_name |
      .spec.template.metadata.labels."machine.openshift.io/exclude-node-draining" = "" |
      .spec.template.metadata.labels."machine.openshift.io/os-id" = "Windows" |
      .spec.template.spec.metadata.labels."node-role.kubernetes.io/worker" = "" |
      .spec.template.spec.providerSpec.value.ami.id = $ami_id |
      .spec.template.spec.providerSpec.value.instanceType = $instance_type |
      .spec.template.spec.providerSpec.value.userDataSecret.name = $user_data_secret |
      del(.status) |
      del(.metadata.selfLink) |
      del(.metadata.uid)
     ' | oc create -f -

# Scale machineset to expected number of replicas
oc -n openshift-machine-api scale machineset/"${winworker_machineset_name}" --replicas="${WINDOWS_NODE_REPLICAS}"
