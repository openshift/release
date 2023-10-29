#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

remote_machineset_name="remote-worker"
remote_worker_number="${REMOTEWORKER_NUMBER}"
declare vsphere_connected_portgroup
# shellcheck source=/dev/null
source "${SHARED_DIR}/vsphere_context.sh"
remote_network_name="${vsphere_connected_portgroup}"

# Get machineset name to generate a generic template
ref_machineset_name=$(oc -n openshift-machine-api get -o 'jsonpath={range .items[*]}{.metadata.name}{"\n"}{end}' machinesets | grep worker | head -n1)

# Get a templated json from worker machineset, change machineset name and network
# and pass it to oc to create a new machine set
oc get machineset "$ref_machineset_name" -n openshift-machine-api -o json |
  jq --arg remote_machineset_name "${remote_machineset_name}" \
    --arg remote_worker_number "${remote_worker_number}" \
    --arg remote_network_name "${remote_network_name}" \
    '
      .metadata.name = $remote_machineset_name |
      .spec.selector.matchLabels."machine.openshift.io/cluster-api-machineset" = $remote_machineset_name |
      .spec.template.metadata.labels."machine.openshift.io/cluster-api-machineset" = $remote_machineset_name |
      .spec.replicas = ($remote_worker_number|tonumber) |
      .spec.template.spec.providerSpec.value.network.devices[0].networkName = $remote_network_name |
      del(.status) |
      del(.metadata.selfLink) |
      del(.metadata.uid)
     ' | oc create -f -

echo "Waiting for remote worker nodes to come up"
while [[ $(oc -n openshift-machine-api get machineset/${remote_machineset_name} -o 'jsonpath={.status.readyReplicas}') != "${remote_worker_number}" ]]; do echo -n "." && sleep 5; done
