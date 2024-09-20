#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

if [[ "${AWS_PUBLIC_IPV4_POOL_ID}" == "none" ]]; then
  echo "BYOIP custom IP pool use explicitly disabled with AWS_PUBLIC_IPV4_POOL_ID=${AWS_PUBLIC_IPV4_POOL_ID}; skipping"
  exit 0
fi

RELEASE_IMAGE_INSTALL="${RELEASE_IMAGE_INITIAL:-}"
if [[ -z "${RELEASE_IMAGE_INSTALL}" ]]; then
  # If there is no initial release, we will be installing latest.
  RELEASE_IMAGE_INSTALL="${RELEASE_IMAGE_LATEST:-}"
fi
cp ${CLUSTER_PROFILE_DIR}/pull-secret /tmp/pull-secret
oc registry login --to /tmp/pull-secret
ocp_version=$(oc adm release info --registry-config /tmp/pull-secret ${RELEASE_IMAGE_INSTALL} --output=json | jq -r '.metadata.version' | cut -d. -f 1,2)
ocp_major_version=$( echo "${ocp_version}" | awk --field-separator=. '{print $1}' )
ocp_minor_version=$( echo "${ocp_version}" | awk --field-separator=. '{print $2}' )
rm /tmp/pull-secret

if (( ocp_major_version < 4 || ( ocp_major_version == 4 && ocp_minor_version < 16 ))); then
  echo "BYOIP custom IP pool is not supported in target latest version ${ocp_version}; bypassing configuration"
  exit 0
fi

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
export AWS_REGION="${LEASED_RESOURCE}"

CONFIG="${SHARED_DIR}/install-config.yaml"

# Total Public IPs once LBs and NAT GW support custom pools:
## bootstrap + (( Public LBs[API+Router] + Nat GWs) * Zones) = 1 + (3*2) = 7
zone_count=$(yq-go r -j "$CONFIG" | jq -r '.controlPlane.platform.aws.zones | length')
# expected_ip_available=$(( ( zone_count * 3 ) + 1 ))  # Use this calculation once routers support pools.
expected_ip_available=$(( ( zone_count * 2 ) + 1 ))  # This accounts for API LB & NAT only.

# IP_POOL_AVAILABLE is automatically populated by CI infrastructure if there are
# BYOIP addresses available in the region's BYOIP pool.
echo "AVAILABLE: ${IP_POOL_AVAILABLE:-0}"
if (( "${IP_POOL_AVAILABLE:-0}" >= "${expected_ip_available}" )); then
  echo "Using custom IPv4 Pool. Sufficient BYOIP addresses (${expected_ip_available}) have been reserved in boskos for this job run in this region."
else
  if [[ ${ENFORCE_IPV4_POOL} == "yes" ]]; then
    echo "ENFORCE_IPV4_POOL is enabled, but no sufficient BYOIP addresses, exit now."
    exit 1
  else
    echo "Unable to use custom IPv4 Pool. Insufficient BYOIP addresses (${expected_ip_available}) available in boskos for this job run in this region. Using default (Amazon Provided)"
    exit 0
  fi
fi

echo "Retrieving available Public IPv4 Pools in the region..."
aws ec2 describe-public-ipv4-pools > /tmp/public-pool.json

pools_count=$(jq -r '.PublicIpv4Pools | length' /tmp/public-pool.json)
if [[ $pools_count -lt 1 ]]; then
  echo "No Public IPv4 Pools available."
  exit 1
fi
echo "Found ${pools_count} custom IPv4 pool(s)."

# Getting the first Pool
pool_id=$(jq -r .PublicIpv4Pools[0].PoolId /tmp/public-pool.json)
available_ips=$(jq -r .PublicIpv4Pools[0].TotalAvailableAddressCount /tmp/public-pool.json)

if [[ $available_ips -lt $expected_ip_available ]]; then
  echo "WARNING: boskos lease sanity check failed. Unable to use custom IPv4 Pool (${pool_id}), only ${available_ips} BYOIPs available, want ${expected_ip_available}. using default (Amazon Provided)"
  exit 0
fi

echo "Found ${available_ips} BYOIP address(es) available in custom IPv4 pool ${pool_id}, the installation will use ${expected_ip_available}."

unused_ip_addresses=$((IP_POOL_AVAILABLE-expected_ip_available))
echo "Releasing $unused_ip_addresses unused ip addresses"
echo "$unused_ip_addresses" >> "${SHARED_DIR}/UNUSED_IP_COUNT"

CONFIG_PATCH="/tmp/install-config-public-ipv4-pool.yaml.patch"
cat > "${CONFIG_PATCH}" << EOF
platform:
  aws:
    publicIpv4Pool: "${pool_id}"
EOF

echo "Custom Pool Patch:"
cat ${CONFIG_PATCH}

yq-go m -x -i "${CONFIG}" "${CONFIG_PATCH}"

# save pool id for post-check
echo "${pool_id}" > ${SHARED_DIR}/ipv4_pool_id

if [[ "${USE_PUBLIC_IPV4_POOL_INGRESS-}" != "yes" ]]; then
  echo "USE_PUBLIC_IPV4_POOL_INGRESS(${USE_PUBLIC_IPV4_POOL_INGRESS-}) is not enabled, skipping Ingress configuration"
  exit 0
fi

EXPIRATION_DATE=$(date -d '4 hours' --iso=minutes --utc)
CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"
TAGS="{Key=Name,Value=${CLUSTER_NAME}-eip-lb-ingress}"
TAGS+=",{Key=expirationDate,Value=${EXPIRATION_DATE}}"
TAGS+=",{Key=kubernetes.io/cluster/${CLUSTER_NAME},Value=shared}"
TAGS+=",{Key=sigs.k8s.io/cluster-api-provider-aws/cluster/${CLUSTER_NAME},Value=shared}"
TAGS+=",{Key=sigs.k8s.io/cluster-api-provider-aws/role,Value=none}"

RESOURCE_TAGS="ResourceType=elastic-ip,Tags=[${TAGS}]"

echo "Creating Elastic IPs for each zone..."
# Create a new Elastic IP for each zones
for i in $(seq 0 $((zone_count - 1))); do
  aws ec2 allocate-address \
    --domain vpc \
    --region "${AWS_REGION}" \
    --tag-specifications "${RESOURCE_TAGS}" \
    --public-ipv4-pool "${pool_id}" > /tmp/eip-"${i}".json
done

eip_allocation_ids=$(jq -r '.AllocationId' /tmp/eip-*.json | paste -sd "," -)

## Create Ingress manifest to use the custom pool
# Open question:
# - should we skip changing the LB type to NLB? Looks like the EP is limited to NLB:
# https://github.com/openshift/enhancements/blob/0c90e8e306581c80ca66a29ad5f56351f0ae8bcd/enhancements/ingress/set_eip_nlb_ingress.md
# ^-> need to confirm with NE team.
cat > "${SHARED_DIR}/manifest_cluster-ingress-default-ingresscontroller.yaml" << EOF
apiVersion: operator.openshift.io/v1
kind: IngressController
metadata:
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
           networkLoadBalancer:
             eipAllocations: [${eip_allocation_ids}]
     type: LoadBalancerService
EOF

# Saving the EIP allocation IDs for deprovision
echo "${eip_allocation_ids}" > "${SHARED_DIR}/eip_allocation_ids"

# Saving the EIP allocation IDs for post-check
echo "${eip_allocation_ids}" > "${ARTIFACT_DIR}/eip_allocation_ids"
