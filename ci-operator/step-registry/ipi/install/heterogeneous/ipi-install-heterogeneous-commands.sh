#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

# Make sure yq is installed
if [ ! -f /tmp/yq-v4 ]; then
  # TODO move to image
  curl -L "https://github.com/mikefarah/yq/releases/download/v4.25.3/yq_linux_$(uname -m | sed s/aarch64/arm64/ | sed s/x86_64/amd64/)" -o /tmp/yq-v4 && chmod +x /tmp/yq-v4
  PATH=${PATH}:/tmp
fi

# Make sure jq is installed
if ! command -v jq; then
  # TODO move to image
  curl -sL https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 > /tmp/jq
  chmod +x /tmp/jq
  PATH=${PATH}:/tmp
fi

dir=/tmp/installer
mkdir "${dir}/"

REGION=${LEASED_RESOURCE}

echo "Fetching Worker MachineSet..."
oc -n openshift-machine-api get -o json machinesets | jq '[.items[] | select(.spec.template.metadata.labels["machine.openshift.io/cluster-api-machine-role"] == "worker")][0]' > ${dir}/99_openshift-cluster-api_worker-machineset-0.yaml

# AMI for AWS ARM
echo "Extracting AMI..."
oc -n openshift-machine-config-operator get configmap/coreos-bootimages -oyaml > ${dir}/coreos-bootimages.yaml
yq-v4 eval ".data.stream" ${dir}/coreos-bootimages.yaml > ${dir}/machineset.yaml
amiid_workers_additional=$(yq-v4 ".architectures.${ADDITIONAL_WORKER_ARCHITECTURE}.images.aws.regions.\"${REGION}\".image" ${dir}/machineset.yaml)
echo "Updating the machineset with ${ADDITIONAL_WORKER_VM_TYPE} and ami ${amiid_workers_additional} ..."
yq-v4 eval ".metadata.name += \"-additional\"
| .spec.replicas = ${ADDITIONAL_WORKERS}
| .spec.selector.matchLabels.\"machine.openshift.io/cluster-api-machineset\" = .metadata.name
| .spec.template.metadata.labels.\"machine.openshift.io/cluster-api-machineset\" = .metadata.name" \
${dir}/99_openshift-cluster-api_worker-machineset-0.yaml > ${dir}/99_openshift-cluster-api_worker-machineset-additional.yaml

yq-v4 eval ".spec.template.spec.providerSpec.value.ami.id = \"${amiid_workers_additional}\"
            | .spec.template.spec.providerSpec.value.instanceType = \"${ADDITIONAL_WORKER_VM_TYPE}\"
            " -i ${dir}/99_openshift-cluster-api_worker-machineset-additional.yaml

echo "Creating ${ADDITIONAL_WORKER_ARCHITECTURE} worker MachineSet"
exec oc create -f ${dir}/99_openshift-cluster-api_worker-machineset-additional.yaml &

wait "$!"
ret="$?"

echo "Exiting with ret=${ret}"
exit "${ret}"
