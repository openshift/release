#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

HOME=/tmp
export HOME

echo "$(date -u --rfc-3339=seconds) - Locating RHCOS image for release..."

ova_url=$(<"${SHARED_DIR}"/ova_url.txt)
vm_template="${ova_url##*/}"

# Troubleshooting UPI OVA import issue
echo "$(date -u --rfc-3339=seconds) - vm_template: ${vm_template}"

echo "$(date -u --rfc-3339=seconds) - Configuring govc exports..."
# shellcheck source=/dev/null
source "${SHARED_DIR}/govc.sh"

declare vsphere_cluster
declare vsphere_portgroup
source "${SHARED_DIR}/vsphere_context.sh"

DATACENTERS=("$GOVC_DATACENTER")
DATASTORES=("$GOVC_DATASTORE")
CLUSTERS=("$vsphere_cluster")

# If testing a zonal install, the template also needs to be available in the
# secondary datacenter
if [ -f "${SHARED_DIR}/ova-datacenters" ]; then
    if [ -f "${SHARED_DIR}/ova-datastores" ]; then
        echo "$(date -u --rfc-3339=seconds) - Adding zonal datacenters/datastores..."
        mapfile DATACENTERS <${SHARED_DIR}/ova-datacenters
        mapfile DATASTORES <${SHARED_DIR}/ova-datastores
        mapfile CLUSTERS <${SHARED_DIR}/ova-clusters
    fi
fi

govc_version=$(govc version)

echo "$(date -u --rfc-3339=seconds) - govc version: ${govc_version}"

echo "$(date -u --rfc-3339=seconds) - Checking if RHCOS OVA needs to be downloaded from ${ova_url}..."

vsphere_version=$(govc about -json | jq -r .About.Version | awk -F'.' '{print $1}')
for i in "${!DATACENTERS[@]}"; do
    DATACENTER=$(echo -n ${DATACENTERS[$i]} | tr -d '\n')
    export GOVC_DATACENTER=$DATACENTER
    DATASTORE=$(echo -n ${DATASTORES[$i]} | tr -d '\n')
    export GOVC_DATASTORE=$DATASTORE
    CLUSTER=$(echo -n ${CLUSTERS[$i]} | tr -d '\n')
    RESOURCE_POOL="/$DATACENTER/host/$CLUSTER/Resources"
    export GOVC_RESOURCE_POOL=$RESOURCE_POOL

    OVA_NETWORK=""
    mapfile -t NETWORKS < <(govc find -i network -name $vsphere_portgroup)

    # Search the found networks for a network that exists in the target cluster.
    echo "$(date -u --rfc-3339=seconds) - Validating network configuration... ${#NETWORKS[@]}"
    if [ "${#NETWORKS[@]}" -gt 1 ]; then
        echo "$(date -u --rfc-3339=seconds) - Detected multiple matching networks.  Searching for valid network target."
        for NET in "${NETWORKS[@]}"; do
            case "${NET}" in
            DistributedVirtualPortgroup*)
                DVPG=$(echo ${NET} | cut -d':' -f2-)
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
        echo "$(date -u --rfc-3339=seconds) - Only one network found with name=${vsphere_portgroup} for datacenter ${DATACENTER}.  Setting ova network to ${vsphere_portgroup}"
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

    if [[ "$(govc vm.info "${vm_template}" | wc -c)" -eq 0 ]]; then
        echo "$(date -u --rfc-3339=seconds) - Creating a template for the VMs from ${ova_url}..."
        curl -L -o /tmp/rhcos.ova "${ova_url}"
        govc import.ova -options=/tmp/rhcos.json /tmp/rhcos.ova &
        wait "$!"
    else
        echo "$(date -u --rfc-3339=seconds) - Skipping ova import due to image already existing."
    fi

    echo "$(date -u --rfc-3339=seconds) - Configured Resource Pool: ${GOVC_RESOURCE_POOL}"
    echo "$(date -u --rfc-3339=seconds) - Configured Leased Resource: ${vsphere_portgroup}"
    echo "$(date -u --rfc-3339=seconds) - Configured Portgroup: ${LEASED_RESOURCE}"
    echo "$(date -u --rfc-3339=seconds) - Configured OVA Network as MOB ID: ${OVA_NETWORK}"
    echo "$(date -u --rfc-3339=seconds) - Configured Datastore: ${GOVC_DATASTORE}"

    hw_versions=(15 17 18 19)
    if [[ ${vsphere_version} -eq 8 ]]; then
        hw_versions=(20)
    fi

    for hw_version in "${hw_versions[@]}"; do
        govc_vm_info=$(govc vm.info "${vm_template}-hw${hw_version}")
        echo "$(date -u --rfc-3339=seconds) - govc_vm_info ${govc_vm_info}"
        if [[ "$(govc vm.info "${vm_template}-hw${hw_version}" | wc -c)" -eq 0 ]]; then
            echo "$(date -u --rfc-3339=seconds) - Cloning and upgrading ${vm_template} to hw version ${hw_version}..."
            echo "$(date -u --rfc-3339=seconds) - Configured Cluster for clone: ${CLUSTER}"

            govc vm.clone -ds=${GOVC_DATASTORE} -pool=${GOVC_RESOURCE_POOL} -on=false -vm="${vm_template}" "${vm_template}-hw${hw_version}"
            govc vm.upgrade -vm="${vm_template}-hw${hw_version}" -version=${hw_version}

        else
            echo "$(date -u --rfc-3339=seconds) - Skipping ova import for hw${hw_version} due to image already existing."
        fi
    done
done
