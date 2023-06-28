#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# ensure LEASED_RESOURCE is set
if [[ -z "${LEASED_RESOURCE}" ]]; then
  echo "Failed to acquire lease"
  exit 1
fi

echo "$(date -u --rfc-3339=seconds) - sourcing context from vsphere_context.sh..."
# shellcheck source=/dev/null
# shellcheck disable=SC2034
declare dns_server
source "${SHARED_DIR}/vsphere_context.sh"

third_octet=$(grep -oP '[ci|qe\-discon]-segment-\K[[:digit:]]+' <(echo "${LEASED_RESOURCE}"))

echo "$(date -u --rfc-3339=seconds) - retrieving IPAM controller CI configuration"

curl https://raw.githubusercontent.com/rvanderp3/machine-ipam-controller/main/hack/ci-resources.yaml | oc process -p THIRD_OCTET="${third_octet}" --local=true -f - | oc create -f -

echo "$(date -u --rfc-3339=seconds) - applying ippool configuration to compute machineset"
oc get machineset.machine.openshift.io -n openshift-machine-api -o json | jq -r '.items[0].spec.template.spec.providerSpec.value.network.devices[0] += 
{
    addressesFromPool: 
        [
            {
                group: "ipamcontroller.openshift.io", 
                name: "static-ci-pool", 
                resource: "IPPool"
            }
        ],
    nameservers:
        [ "$dns_server" ]
}' | jq '.items[1].spec.template.metadata.labels += 
{
    ipam: "true"
}' | envsubst | oc apply -f -

echo "$(date -u --rfc-3339=seconds) - scaling up machineset with ippool configuration"
MACHINESET_NAME=$(oc get machineset.machine.openshift.io -n openshift-machine-api -o json | jq -r '.items[0].metadata.name')
oc scale machineset.machine.openshift.io --replicas=2 ${MACHINESET_NAME} -n openshift-machine-api

VALID_STATIC_IP=("192.168.${third_octet}.129" "192.168.${third_octet}.130" "192.168.${third_octet}.131")

echo "$(date -u --rfc-3339=seconds) - validating static IPs are applied to applicable nodes"
for retries in {1..16}; do  
    NODES_VALIDATED=0
    readarray NODEREF_ARRAY <<< "$(oc get machines.machine.openshift.io -n openshift-machine-api -l ipam=true -o=json | jq -r .items[].status.nodeRef.name)"
    if [[ ${#NODEREF_ARRAY[@]} -lt 2 ]]; then
        echo "$(date -u --rfc-3339=seconds) - ${#NODEREFS[@]} of 2 node refs available"    
        NODES_VALIDATED=$((${NODES_VALIDATED}-1))
    else            
        for NODE in "${NODEREF_ARRAY[@]}"; do           
            NODE=$(echo ${NODE} | tr -d '\n')
            if [[ ${NODE} = "null" ]]; then                                
                echo "$(date -u --rfc-3339=seconds) - not all machines have nodeRefs. Will recheck in 15 seconds."
                NODES_VALIDATED=$((${NODES_VALIDATED}-1))
                break
            fi
            echo "$(date -u --rfc-3339=seconds) - verifying static IP for node ${NODE}"        
            ADDRESS=$(oc get node ${NODE} -o=jsonpath='{.status.addresses}' | jq -r '.[] | select(.type=="InternalIP") | .address')
            if [ -z "${ADDRESS}" ]; then
                echo "$(date -u --rfc-3339=seconds) - no address available for node ${NODE}"
                break
            fi
            MATCH=0
            for VALID_IP in "${VALID_STATIC_IP[@]}"; do
                if [[ ${VALID_IP} = "${ADDRESS}" ]]; then
                    MATCH=1 
                fi
            done
            if [[ ${MATCH} -eq 0 ]]; then
                echo "$(date -u --rfc-3339=seconds) - node ${NODE} does not have an expected address. InternalIP ${ADDRESS}"
                NODES_VALIDATED=$((${NODES_VALIDATED}-1))
            fi        
        done
    fi
    if [[ ${NODES_VALIDATED} -eq 0 ]]; then
        echo "$(date -u --rfc-3339=seconds) - all nodes validated"
        exit 0
    else
        echo "$(date -u --rfc-3339=seconds) - attempt ${retries} - not all nodes have been validated. Will recheck in 15 seconds."
        sleep 15
    fi
done 

echo "$(date -u --rfc-3339=seconds) - unable to verify applicable nodes received static IPs"
exit 1 