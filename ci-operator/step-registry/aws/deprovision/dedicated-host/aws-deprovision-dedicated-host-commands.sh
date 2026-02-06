#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
REGION="${LEASED_RESOURCE}"

ret=0

dedicated_host_json="$SHARED_DIR"/dedicated_hosts_to_be_removed.json

if [ ! -f "$dedicated_host_json" ]; then
  echo "ERROR: dedicated_hosts_to_be_removed.json was not found."
  exit 1
fi

# shellcheck disable=SC2046
aws --region "$REGION" ec2 release-hosts --host-ids $(jq -r '[.Hosts[].HostId] | join(" ")'  "$dedicated_host_json") | tee /tmp/out.json
if [ "$(jq -r '.Unsuccessful|length' /tmp/out.json)" != "0" ]; then
  ret=$((ret+1))
fi

exit $ret
