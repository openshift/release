#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

tfvars_path=/var/run/secrets/ci.openshift.io/cluster-profile/vmc.secret.auto.tfvars
cluster_name=${NAMESPACE}-${JOB_NAME_HASH}
ipam_token=$(grep -oP 'ipam_token\s*=\s*"\K[^"]+' ${tfvars_path})

# Array to hold virtual ips:
# 0: API
# 1: Ingress
declare -a vips

echo "Reserving virtual ip addresses from the IPAM server..."
for i in {0..1}
do
  args=$(jq -n \
            --arg hostn "$cluster_name-$i" \
            --arg token "$ipam_token" \
            '{network: "172.31.252.0", hostname: $hostn, ipam: "ipam.vmc.ci.openshift.org", ipam_token: $token}')

  vip_json=$(echo "$args" | bash <(curl -s https://raw.githubusercontent.com/openshift/installer/master/upi/vsphere/ipam/cidr_to_ip.sh))
  vips[$i]=$(echo "$vip_json" | jq -r .ip_address )
  if [[ -z ${vips[$i]} ]]; then
    echo "error: Unable to reserve virtual IP address, exiting" 1>&2
    exit 1
  fi
  echo "${vips[$i]}" >> "${SHARED_DIR}"/vips.txt
done

echo "Reserved the following IP addresses..."
cat "${SHARED_DIR}"/vips.txt
