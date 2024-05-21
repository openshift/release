#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# ensure LEASED_RESOURCE is set
if [[ -z "${LEASED_RESOURCE}" ]]; then
  echo "$(date -u --rfc-3339=seconds) - failed to acquire lease"
  exit 1
fi

declare vsphere_datacenter

# only used in zonal and vsphere environments with
# multiple datacenters

declare vsphere_datastore
declare vsphere_cluster
declare cloud_where_run
declare dns_server
declare vsphere_resource_pool
declare vsphere_url
declare VCENTER_AUTH_PATH
declare vlanid
declare router
declare phydc
declare primaryrouterhostname
declare vsphere_portgroup
declare -a portgroup_list
declare multizone
declare vsphere_url

function log() {
  echo "$(date -u --rfc-3339=seconds) - " + $1
}

log "add jq plugin for converting json to yaml"
# this snippet enables jq to convert json to yaml
cat > ~/.jq <<EOF
def yamlify2:
    (objects | to_entries | (map(.key | length) | max + 2) as \$w |
        .[] | (.value | type) as \$type |
        if \$type == "array" then
            "\(.key):", (.value | yamlify2)
        elif \$type == "object" then
            "\(.key):", "    \(.value | yamlify2)"
        else
            "\(.key):\(" " * (.key | \$w - length))\(.value)"
        end
    )
    // (arrays | select(length > 0)[] | [yamlify2] |
        "  - \(.[0])", "    \(.[1:][])"
    )
    // .
    ;
EOF

if [[ ${JOB_NAME_SAFE} =~ "-upi" ]]; then
   IPI=0
   log "determined this is a UPI job"
else
   IPI=1
   log "determined this is an IPI job"
fi

if [[ -n "${VSPHERE_EXTRA_LEASED_RESOURCE:-}" ]]; then
  log "creating extra lease resources"

  i=1  
  for extra_leased_resource in ${VSPHERE_EXTRA_LEASED_RESOURCE}; do
    log "creating extra leased resource ${extra_leased_resource}"
    echo "apiVersion: vspherecapacitymanager.splat.io/v1
kind: Lease
metadata:
  generateName: "${LEASED_RESOURCE}-"
  namespace: "vsphere-infra-helpers"
  annotations: {}
  labels:
    boskos-lease-id: "${LEASED_RESOURCE}"
    job-name: "${JOB_NAME_SAFE}"
    VSPHERE_EXTRA_LEASED_RESOURCE: \"${i}\"
spec:
  vcpus: 0
  memory: 0
  networks: 1" | oc create --kubeconfig ${SA_KUBECONFIG} -f -

  i=$((i + 1))
  done
fi


if [[ -n "${VSPHERE_BASTION_LEASED_RESOURCE:-}" ]]; then  
  log "creating bastion lease resource ${VSPHERE_BASTION_LEASED_RESOURCE}"
  echo "apiVersion: vspherecapacitymanager.splat.io/v1
kind: Lease
metadata:
  generateName: "${LEASED_RESOURCE}-"
  namespace: "vsphere-infra-helpers"
  annotations: {}
  labels:
    boskos-lease-id: "${LEASED_RESOURCE}"
    job-name: "${JOB_NAME_SAFE}"
    VSPHERE_BASTION_LEASED_RESOURCE: \"${VSPHERE_BASTION_LEASED_RESOURCE}\"
spec:
  vcpus: 0
  memory: 0
  requiresPool: \"${VSPHERE_BASTION_LEASED_RESOURCE}\"
  networks: 1" | oc create --kubeconfig ${SA_KUBECONFIG} -f -
fi


POOLS=${POOLS:-}
declare -a pools=($POOLS)

SA_KUBECONFIG=${SA_KUBECONFIG:-/var/run/vault/vsphere-config/vsphere-capacity-manager-kubeconfig}
OPENSHIFT_REQUIRED_CORES=${OPENSHIFT_REQUIRED_CORES:-24}
OPENSHIFT_REQUIRED_MEMORY=${OPENSHIFT_REQUIRED_MEMORY:-96}

if [[ ${#pools[@]} -eq 0 ]]; then
  pools[0]="unspecified"
else
  # if we have multiple pools, attempt to spread the load evenly between the pools
  OPENSHIFT_REQUIRED_CORES=$((OPENSHIFT_REQUIRED_CORES / ${#pools[@]}))
  OPENSHIFT_REQUIRED_MEMORY=$((OPENSHIFT_REQUIRED_MEMORY / ${#pools[@]}))
fi

# create a lease for each pool
for POOL in ${pools[@]}; do
  log "creating lease for pool ${POOL}"
  requiredPool=""
  if [ $POOL != "unspecified" ]; then 
    requiredPool="required-pool: $POOL"
    log "setting required pool ${requiredPool}"
  fi
  echo "apiVersion: vspherecapacitymanager.splat.io/v1
kind: Lease
metadata:
  generateName: "${LEASED_RESOURCE}-"
  namespace: "vsphere-infra-helpers"
  annotations: {}
  labels:
    boskos-lease-id: "${LEASED_RESOURCE}"
    job-name: "${JOB_NAME_SAFE}"
spec:
  vcpus: ${OPENSHIFT_REQUIRED_CORES}
  memory: ${OPENSHIFT_REQUIRED_MEMORY}
  ${requiredPool}
  networks: 1" | oc create --kubeconfig ${SA_KUBECONFIG} -f -
done

log "waiting for lease to be fulfilled..."
oc wait leases.vspherecapacitymanager.splat.io --kubeconfig ${SA_KUBECONFIG} --timeout=30m --for=jsonpath='{.status.phase}'=Fulfilled -n vsphere-infra-helpers -l boskos-lease-id="${LEASED_RESOURCE}"

declare -A vcenter_portgroups

# reconcile leases
log "Extracting portgroups from leases..."
LEASES=$(oc get leases.vspherecapacitymanager.splat.io --kubeconfig ${SA_KUBECONFIG} -l boskos-lease-id="${LEASED_RESOURCE}" -n vsphere-infra-helpers -o=jsonpath='{.items[*].metadata.name}')
for LEASE in $LEASES; do
  oc get leases.vspherecapacitymanager.splat.io -n vsphere-infra-helpers --kubeconfig ${SA_KUBECONFIG} ${LEASE} -o json > /tmp/lease.json
  VCENTER=$(cat /tmp/lease.json | jq -r '.status.server')
  NETWORK_PATH=$(cat /tmp/lease.json | jq -r '.status.topology.networks[0]')
  NETWORK_RESOURCE=$(cat /tmp/lease.json | jq -r '.metadata.ownerReferences[] | select(.kind=="Network") | .name')

  portgroup_name=$(echo $NETWORK_PATH | cut -d '/' -f 4)  

  bastion_leased_resource=$(cat /tmp/lease.json | jq .metadata.labels.VSPHERE_BASTION_LEASED_RESOURCE)
  extra_leased_resource=$(cat /tmp/lease.json | jq .metadata.labels.VSPHERE_EXTRA_LEASED_RESOURCE)

  NETWORK_CACHE_PATH="${SHARED_DIR}/NETWORK_${NETWORK_RESOURCE}.json"
  
  if [ ! -f $NETWORK_CACHE_PATH ]; then
    log caching network resource ${NETWORK_RESOURCE}
    oc get networks.vspherecapacitymanager.splat.io -n vsphere-infra-helpers --kubeconfig ${SA_KUBECONFIG} ${NETWORK_RESOURCE} -o json > ${NETWORK_CACHE_PATH}
  fi

  if [ ${bastion_leased_resource} != "null" ]; then
    log "setting bastion portgroup ${portgroup_name} in vsphere_context.sh"  
    cat >>"${SHARED_DIR}/vsphere_context.sh" <<EOF    
export vsphere_bastion_portgroup="${portgroup_name}"
EOF

  elif [ ${extra_leased_resource} != "null" ]; then
    log "setting extra leased network ${portgroup_name} in vsphere_context.sh"  
    cat >>"${SHARED_DIR}/vsphere_context.sh" <<EOF
export vsphere_extra_portgroup_${extra_leased_resource}="${portgroup_name}"
EOF

  else
    vcenter_portgroups[$VCENTER]=${portgroup_name}
  fi

  cp /tmp/lease.json ${SHARED_DIR}/LEASE_$LEASE.json
  log "discovered portgroup ${vcenter_portgroups[$VCENTER]}"
done

# retrieving resource pools 
RESOURCE_POOLS=$(oc get pools.vspherecapacitymanager.splat.io --kubeconfig ${SA_KUBECONFIG} -n vsphere-infra-helpers -o=jsonpath='{.items[*].metadata.name}')

declare -A pool_usernames
declare -A pool_passwords
declare -A vsphere_datacenters

platformSpec='{"vcenters": [],"failureDomains": []}'

log "building local variables and failure domains"

for RESOURCE_POOL in ${RESOURCE_POOLS}; do
  log "checking to see if ${RESOURCE_POOL} is in use"
  # check to see if this pool is in use by a lease
  FOUND=0
  for _leaseJSON in $(ls -d $SHARED_DIR/LEASE*); do 
    _VCENTER=$(cat ${_leaseJSON} | jq -r .status.name)
    log "checking if ${_VCENTER} == ${RESOURCE_POOL}"
    if [ ${_VCENTER,,} = ${RESOURCE_POOL,,} ]; then
      FOUND=1
      break
    fi
  done

  if [ ${FOUND} -eq 0 ]; then
    log "resource pool ${RESOURCE_POOL} isn't in use. excluding from failure domains"
    continue    
  fi

  log "building local variables and platform spec for pool ${RESOURCE_POOL}"
  oc get pools.vspherecapacitymanager.splat.io --kubeconfig ${SA_KUBECONFIG} -n vsphere-infra-helpers ${RESOURCE_POOL} -o json > /tmp/pool.json
  VCENTER_AUTH_PATH=$(cat /tmp/pool.json | jq -r '.metadata.annotations["ci-auth-path"]')  
  # shellcheck source=/dev/null
  source ${VCENTER_AUTH_PATH}
  account_loc=$(($RANDOM % 4))
  VCENTER=$(cat /tmp/pool.json | jq -r '.spec.server')
  vsphere_user="${vcenter_usernames[$account_loc]}"
  vsphere_password="${vcenter_passwords[$account_loc]}"
  pool_usernames[$VCENTER]=${vsphere_user}
  pool_passwords[$VCENTER]=${vsphere_password}
  
  name=$(cat /tmp/pool.json | jq -r '.spec.name')
  server=$(cat /tmp/pool.json | jq -r '.spec.server')
  region=$(cat /tmp/pool.json | jq -r '.spec.region')
  zone=$(cat /tmp/pool.json | jq -r '.spec.zone')
  cluster=$(cat /tmp/pool.json | jq -r '.spec.topology.computeCluster')
  datacenter=$(cat /tmp/pool.json | jq -r '.spec.topology.datacenter')
  datastore=$(cat /tmp/pool.json | jq -r '.spec.topology.datastore')
  network="${vcenter_portgroups[${server}]}"
  if [ $IPI -eq 0 ]; then
    resource_pool=${cluster}/Resources/${NAMESPACE}-${UNIQUE_HASH}
  else
    resource_pool=${cluster}/Resources/ipi-ci-clusters
  fi
  platformSpec=$(echo ${platformSpec} | jq -r '.failureDomains += [{"server": "'${server}'", "name": "'${name}'", "zone": "'${zone}'", "region": "'${region}'", "server": "'${server}'", "topology": {"resourcePool": "'${resource_pool}'", "computeCluster": "'${cluster}'", "datacenter": "'${datacenter}'", "datastore": "'$datastore'", "networks": ["'${network}'"]}}]')

  cp /tmp/pool.json ${SHARED_DIR}/POOL_${RESOURCE_POOL}.json
done

log "building vcenters for platform spec"

# append vCenters to platform spec
for VCENTER in ${!pool_usernames[@]}; do
  log "building ${VCENTER} in platform spec"
  declare -A _datacenters
  for _poolJSON in $(ls -d $SHARED_DIR/POOL*); do 
    log "processing $_poolJSON"; 
    _VCENTER=$(cat ${_poolJSON} | jq -r .spec.server)
    _DATACENTER=$(cat ${_poolJSON} | jq -r .spec.topology.datacenter)
    if [ ${_VCENTER} = ${VCENTER} ]; then
      _datacenters[${_DATACENTER}]=${_DATACENTER}
    fi
  done
  printf -v joined '"%s",' "${_datacenters[@]}"
  log "found datacenters ${joined%,}"

  platformSpec=$(echo $platformSpec | jq -r '.vcenters += [{"server": "'$VCENTER'", "user": "'${pool_usernames[$VCENTER]}'", "password": "'${pool_passwords[$VCENTER]}'", "datacenters": ['$(echo "${joined%,}")']}]')
done

# # For most CI jobs, a single lease and single pool will be used. We'll initialize govc.sh and
# # vsphere_context.sh with the first lease we find. multi-zone and multi-vcenter will need to
# # parse topology, credentials, etc from $SHARED_DIR.

cp /tmp/lease.json $SHARED_DIR/LEASE_single.json
NETWORK_RESOURCE=$(cat /tmp/lease.json | jq -r '.metadata.ownerReferences[] | select(.kind=="Network") | .name')
cp "${SHARED_DIR}/NETWORK_${NETWORK_RESOURCE}.json" $SHARED_DIR/NETWORK_single.json

cat /tmp/lease.json | jq -r '.status.envVars' > /tmp/envvars
source /tmp/envvars

if [ $IPI -eq 0 ]; then
  resource_pool=${vsphere_cluster}/Resources/${NAMESPACE}-${UNIQUE_HASH}
else
  resource_pool=${vsphere_cluster}/Resources/ipi-ci-clusters
fi

log "Creating govc.sh file..."
cat >>"${SHARED_DIR}/govc.sh" <<EOF
$(cat /tmp/envvars)
export LEASE_PATH=${SHARED_DIR}/LEASE_single.json
export NETWORK_PATH=${SHARED_DIR}/NETWORK_single.json
export GOVC_INSECURE=1
export vsphere_resource_pool=${resource_pool}
export GOVC_RESOURCE_POOL=${resource_pool}
EOF

log "Creating vsphere_context.sh file..."
cp "${SHARED_DIR}/govc.sh" "${SHARED_DIR}/vsphere_context.sh"

# 1. Get the OpaqueNetwork (NSX-T port group) which is listed in LEASED_RESOURCE.
# 2. Select the virtual machines attached to network
# 3. list the path to the virtual machine via the managed object reference
# 4. skip the templates with ova
# 5. Power off and delete the virtual machine

# disable error checking in this section
# randomly delete may fail, this shouldn't cause an immediate issue
# but should eventually be cleaned up.

# set +e
# for LEASE in $LEASES; do
#   cat $SHARED_DIR/LEASE_$LEASE.json | jq -r '.status.envVars' > /tmp/envvars
#   source /tmp/envvars

#   export GOVC_USERNAME="${pool_usernames[$vsphere_url]}"
#   export GOVC_PASSWORD="${pool_passwords[$vsphere_url]}"
#   export GOVC_TLS_CA_CERTS=/var/run/vault/vsphere-ibmcloud-ci/vcenter-certificate

#   echo "$(date -u --rfc-3339=seconds) - Find virtual machines attached to ${vsphere_portgroup} in DC ${vsphere_datacenter} and destroy"
#   govc ls -json "${vsphere_portgroup}" |
#   jq '.elements[]?.Object.Vm[]?.Value' |
#   xargs -I {} --no-run-if-empty govc ls -json -L VirtualMachine:{} |
#   jq '.elements[].Path | select((contains("ova") or test("\\bci-segment-[0-9]?[0-9]?[0-9]-bastion\\b")) | not)' |
#   xargs -I {} --no-run-if-empty govc vm.destroy {}
# done
# set -e

log "writing the platform spec"
echo $platformSpec | jq -r yamlify2 | sed --expression='s/^/    /g' > $SHARED_DIR/platform.yaml
