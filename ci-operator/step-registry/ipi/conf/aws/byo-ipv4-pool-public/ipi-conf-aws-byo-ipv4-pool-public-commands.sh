#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
export AWS_REGION="${LEASED_RESOURCE}"

CONFIG="${SHARED_DIR}/install-config.yaml"

# Total Public IPs:
## bootstrap + (( Public LBs[API+Router] + Nat GWs) * Zones) = 1 + (3*2) = 7
#zone_count=$(yq-go r -j "$CONFIG" | jq -r '.controlPlane.platform.aws.zones | length')
#expected_ip_available=$(( ( zone_count * 3 ) + 1 ))

##> TODO> setting fixed number of available IPs to have a buffer while a 'pool semaphore'
# is not created.
expected_ip_available=30

echo "Retrieving available Public IPv4 Pools in the region..."
aws ec2 describe-public-ipv4-pools > /tmp/public-pool.json

pools_count=$(jq -r '.PublicIpv4Pools | length' /tmp/public-pool.json)
if [[ $pools_count -lt 1 ]]; then
  echo "No Public IPv4 Pools available."
  exit 1
fi
echo "Found ${pools_count} pool(s)."

# Getting the first Pool
pool_id=$(jq -r .PublicIpv4Pools[0].PoolId /tmp/public-pool.json)
available_ips=$(jq -r .PublicIpv4Pools[0].TotalAvailableAddressCount /tmp/public-pool.json)

if [[ $available_ips -lt $expected_ip_available ]]; then
  echo "WARNING: Unable to use custom IPv4 Pool, only ${available_ips} IPs available, want ${expected_ip_available}. using default (Amazon Provided)"
  exit 0
fi

# TODO: The installation will not allocate while the resource isn't created, the CI concurrency may
# introduce a problem in this step when the Pool is full (no IP address is available).
# We may need to implement some CI-specific API to "pre-allocate" the
# block to prevent CI failures when pass in this step, but, no address available when
# creating the resource (EIP) infrastructure (Terraform/CAPI/SDK).
echo "Found ${available_ips} IP address(es) available, the installation will use ${expected_ip_available}."

CONFIG_PATCH="/tmp/install-config-public-ipv4-pool.yaml.patch"
cat > "${CONFIG_PATCH}" << EOF
platform:
  aws:
    publicIpv4Pool: "${pool_id}"
EOF

echo "Custom Pool Patch:"
cat ${CONFIG_PATCH}

yq-go m -x -i "${CONFIG}" "${CONFIG_PATCH}"