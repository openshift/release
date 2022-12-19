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

if test "${ret}" -eq 0 ; then
  touch  "${SHARED_DIR}/success"
  # Save console URL in `console.url` file so that ci-chat-bot could report success
  echo "https://$(env KUBECONFIG=${dir}/auth/kubeconfig oc -n openshift-console get routes console -o=jsonpath='{.spec.host}')" > "${SHARED_DIR}/console.url"

  echo "Collecting cluster data for analysis..."
  set +o errexit
  set +o pipefail
  if [ ! -f /tmp/jq ]; then
    curl -L https://stedolan.github.io/jq/download/linux64/jq -o /tmp/jq && chmod +x /tmp/jq
  fi
  if ! pip -V; then
    echo "pip is not installed: installing"
    if python -c "import sys; assert(sys.version_info >= (3,0))"; then
      python -m ensurepip --user || easy_install --user 'pip'
    fi
  fi
  echo "Installing python modules: json"
  python3 -c "import json" || pip3 install --user pyjson
  PLATFORM="$(env KUBECONFIG=${dir}/auth/kubeconfig oc get infrastructure/cluster -o json | /tmp/jq '.status.platform')"
  TOPOLOGY="$(env KUBECONFIG=${dir}/auth/kubeconfig oc get infrastructure/cluster -o json | /tmp/jq '.status.infrastructureTopology')"
  NETWORKTYPE="$(env KUBECONFIG=${dir}/auth/kubeconfig oc get network.operator cluster -o json | /tmp/jq '.spec.defaultNetwork.type')"
  if [[ "$(env KUBECONFIG=${dir}/auth/kubeconfig oc get network.operator cluster -o json | /tmp/jq '.spec.clusterNetwork[0].cidr')" =~ .*":".*  ]]; then
    NETWORKSTACK="IPv6"
  else
    NETWORKSTACK="IPv4"
  fi
  CLOUDREGION="$(env KUBECONFIG=${dir}/auth/kubeconfig oc get node -o json | /tmp/jq '.items[]|.metadata.labels' | grep topology.kubernetes.io/region | cut -d : -f 2 | head -1 | sed 's/,//g')"
  CLOUDZONE="$(env KUBECONFIG=${dir}/auth/kubeconfig oc get node -o json | /tmp/jq '.items[]|.metadata.labels' | grep topology.kubernetes.io/zone | cut -d : -f 2 | sort -u | tr -d \")"
  CLUSTERVERSIONHISTORY="$(env KUBECONFIG=${dir}/auth/kubeconfig oc get clusterversion -o json | /tmp/jq '.items[]|.status.history' | grep version | cut -d : -f 2 | tr -d \")"
  python3 -c '
import json;
dictionary = {
    "Platform": '$PLATFORM',
    "Topology": '$TOPOLOGY',
    "NetworkType": '$NETWORKTYPE',
    "NetworkStack": "'$NETWORKSTACK'",
    "CloudRegion": '"$CLOUDREGION"',
    "CloudZone": "'"$CLOUDZONE"'".split(),
    "ClusterVersionHistory": "'"$CLUSTERVERSIONHISTORY"'".split()
}
with open("'${ARTIFACT_DIR}/cluster-data.json'", "w") as outfile:
    json.dump(dictionary, outfile)'
set -o errexit
set -o pipefail
echo "Done collecting cluster data for analysis!"
fi

echo "Exiting with ret=${ret}"
exit "${ret}"
