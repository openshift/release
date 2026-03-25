#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
REGION="${LEASED_RESOURCE}"

ret=0

function remove_dh()
{
  local dn_out_json="$1"
  # shellcheck disable=SC2046
  aws --region "$REGION" ec2 release-hosts --host-ids $(jq -r '[.Hosts[].HostId] | join(" ")'  "$dn_out_json") | tee /tmp/out.json
  if [ "$(jq -r '.Unsuccessful|length' /tmp/out.json)" != "0" ]; then
    ret=$((ret+1))
  fi
}

if [ -f "${SHARED_DIR}/selected_dedicated_hosts_controlplane.json" ]; then
  echo "Removing DH for controlPlane nodes"
  remove_dh "${SHARED_DIR}/selected_dedicated_hosts_controlplane.json"
fi

if [ -f "${SHARED_DIR}/selected_dedicated_hosts_compute.json" ]; then
  echo "Removing DH for compute nodes"
  remove_dh "${SHARED_DIR}/selected_dedicated_hosts_compute.json"
fi

if [ -f "${SHARED_DIR}/selected_dedicated_hosts_default.json" ]; then
  echo "Removing DH for default machine pool"
  remove_dh "${SHARED_DIR}/selected_dedicated_hosts_default.json"
fi

exit $ret
