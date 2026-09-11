#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [[ "${CLUSTER_PROFILE_NAME:-}" != "vsphere-elastic" ]]; then
  echo "using legacy sibling of this step"
  exit 0
fi

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

HOME=/tmp
export HOME

echo "$(date -u --rfc-3339=seconds) - Locating RHCOS image for release..."

ova_url=$(<"${SHARED_DIR}"/ova_url.txt)
vm_template="${ova_url##*/}"

# Troubleshooting UPI OVA import issue
echo "$(date -u --rfc-3339=seconds) - vm_template: ${vm_template}"

echo "$(date -u --rfc-3339=seconds) - Configuring govc exports..."

declare GOVC_URL
declare GOVC_DATACENTER
declare GOVC_DATASTORE
declare vsphere_portgroup
declare GOVC_RESOURCE_POOL

# shellcheck source=/dev/null
source "${SHARED_DIR}/govc.sh"

unset SSL_CERT_FILE
unset GOVC_TLS_CA_CERTS

govc_version=$(govc version)

echo "$(date -u --rfc-3339=seconds) - govc version: ${govc_version}"

echo "$(date -u --rfc-3339=seconds) - Checking if RHCOS OVA needs to be downloaded from ${ova_url}..."

vsphere_version=$(govc about -json | jq -r .About.Version | awk -F'.' '{print $1}')
vsphere_minor_version=$(govc about -json | jq -r .About.Version | awk -F'.' '{print $3}')
FDS=$(jq '.failureDomains | length' "$SHARED_DIR"/platform.json)
fd_idx=0


echo "$(date -u --rfc-3339=seconds) - ***** DEBUG: ${FDS}"


# iterate each failure domain and ensure a template is available in
# each failure domain
while [[ $fd_idx -lt $FDS ]]; do
    FD=$(jq -c -r '.failureDomains['${fd_idx}']' "$SHARED_DIR"/platform.json)

    echo "$(date -u --rfc-3339=seconds) - ***** DEBUG: index: ${fd_idx} $(echo "${FD}" | jq -r '.')"

    CLUSTER=$(echo "${FD}" | jq -r .topology.computeCluster)
    GOVC_DATASTORE=$(echo "${FD}" | jq -r .topology.datastore)
    GOVC_DATACENTER=$(echo "${FD}" | jq -r .topology.datacenter)
    # shellcheck disable=SC2034
    GOVC_URL=$(echo "${FD}" | jq -r '.server')

    # Since the resource pool doesn't exist yet use the cluster hidden Resources
    GOVC_RESOURCE_POOL="${CLUSTER}/Resources"
    vsphere_portgroup=$(echo "${FD}" | jq -r .topology.networks[0])

    OVA_NETWORK=""
    mapfile -t NETWORKS < <(govc find -i network -name "$vsphere_portgroup")

    # Search the found networks for a network that exists in the target cluster.
    echo "$(date -u --rfc-3339=seconds) - Validating network configuration... ${#NETWORKS[@]}"
    if [ "${#NETWORKS[@]}" -gt 1 ]; then
        echo "$(date -u --rfc-3339=seconds) - Detected multiple matching networks.  Searching for valid network target."
        for NET in "${NETWORKS[@]}"; do
            case "${NET}" in
            DistributedVirtualPortgroup*)
                DVPG=$(echo "${NET}" | cut -d':' -f2-)
                echo "Checking ${DVPG}"
                FOUND=$(govc object.collect -json -type c | jq -r --arg CLUSTER "$CLUSTER" --arg DVPG "$DVPG" 'select(.ChangeSet[] | .Name == "name" and .Val == $CLUSTER) | .ChangeSet[] | select(.Name == "network") | .Val.ManagedObjectReference | any(.Value == $DVPG)')
                if [ "$FOUND" = true ]; then
                    echo "$(date -u --rfc-3339=seconds) - Found network matching for name=${vsphere_portgroup}.  Setting ova network to ${NET}"
                    OVA_NETWORK=${NET}
                    break
                fi
                ;;
            *)
                echo "$(date -u --rfc-3339=seconds) - Unknown network type: ${NET}"
                exit 1
                ;;
            esac
        done
    else
        echo "$(date -u --rfc-3339=seconds) - Only one network found with name=${vsphere_portgroup} for datacenter ${GOVC_DATACENTER}.  Setting ova network to ${vsphere_portgroup}"
        OVA_NETWORK=${vsphere_portgroup}
    fi

    # Generate rhcos.json for ova import
    echo "$(date -u --rfc-3339=seconds) - Generating rhcos.json for ova import using network ${OVA_NETWORK}"
    cat <<EOF >/tmp/rhcos.json
{
   "DiskProvisioning": "thin",
   "MarkAsTemplate": false,
   "PowerOn": false,
   "InjectOvfEnv": false,
   "WaitForIP": false,
   "Name": "${vm_template}",
   "NetworkMapping":[{"Name":"VM Network","Network":"${OVA_NETWORK}"}]
}
EOF

    echo "$(date -u --rfc-3339=seconds) - Configured Datacenter: ${GOVC_DATACENTER}"
    echo "$(date -u --rfc-3339=seconds) - Configured Resource Pool: ${GOVC_RESOURCE_POOL}"
    echo "$(date -u --rfc-3339=seconds) - Configured Leased Resource: ${vsphere_portgroup}"
    echo "$(date -u --rfc-3339=seconds) - Configured Portgroup: ${LEASED_RESOURCE}"
    echo "$(date -u --rfc-3339=seconds) - Configured OVA Network as MOB ID: ${OVA_NETWORK}"
    echo "$(date -u --rfc-3339=seconds) - Configured Datastore: ${GOVC_DATASTORE}"

    if [[ "$(govc vm.info "${vm_template}" | wc -c)" -eq 0 ]]; then
        echo "$(date -u --rfc-3339=seconds) - Creating a template for the VMs from ${ova_url}..."
        curl -L -o /tmp/rhcos.ova "${ova_url}"
        govc import.ova -options=/tmp/rhcos.json /tmp/rhcos.ova &
        wait "$!"
    else
        echo "$(date -u --rfc-3339=seconds) - Skipping ova import due to image already existing."
    fi

    hw_versions=(15 17 18 19)
    if [[ ${vsphere_version} -eq 8 ]]; then
        hw_versions=(20)
      if [[ ${vsphere_minor_version} -ge 2 ]]; then
        hw_versions=(20 21)
      fi
    fi

    for hw_version in "${hw_versions[@]}"; do
        govc_vm_info=$(govc vm.info "${vm_template}-hw${hw_version}")
        echo "$(date -u --rfc-3339=seconds) - govc_vm_info ${govc_vm_info}"
        if [[ "$(govc vm.info "${vm_template}-hw${hw_version}" | wc -c)" -eq 0 ]]; then
            echo "$(date -u --rfc-3339=seconds) - Cloning and upgrading ${vm_template} to hw version ${hw_version}..."
            echo "$(date -u --rfc-3339=seconds) - Configured Cluster for clone: ${CLUSTER}"

            govc vm.clone -ds="${GOVC_DATASTORE}" -pool="${GOVC_RESOURCE_POOL}" -on=false -vm="${vm_template}" "${vm_template}-hw${hw_version}"
            govc vm.upgrade -vm="${vm_template}-hw${hw_version}" -version="${hw_version}"

        else
            echo "$(date -u --rfc-3339=seconds) - Skipping ova import for hw${hw_version} due to image already existing."
        fi
    done

    fd_idx=$((fd_idx+1));
done
