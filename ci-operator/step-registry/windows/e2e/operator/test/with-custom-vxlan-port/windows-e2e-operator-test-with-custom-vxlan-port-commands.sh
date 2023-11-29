#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/.awscred
export KUBE_SSH_KEY_PATH=${CLUSTER_PROFILE_DIR}/ssh-privatekey

declare vsphere_portgroup
if [[ "${CLUSTER_TYPE}" == "vsphere" ]]; then
  # notes: jcallen: split the LEASED_RESOURCE e.g. bcr01a.dal10.1153
  # into: primary router hostname, datacenter and vlan id
  vlanid=$(awk -F. '{print $3}' <(echo "${LEASED_RESOURCE}"))

  # notes: jcallen: all new subnets resides on port groups named: ci-vlan-#### where #### is the vlan id.
  vsphere_portgroup="ci-vlan-${vlanid}"
  export LEASED_RESOURCE="${vsphere_portgroup}"

fi

make run-ci-e2e-test
