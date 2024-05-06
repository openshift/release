#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export OS_CLOUD
export OS_CLIENT_CONFIG_FILE="${SHARED_DIR}/clouds.yaml"

# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    # shellcheck disable=SC1090,SC1091
    source "${SHARED_DIR}/proxy-conf.sh"
fi

CLUSTERID=$(oc get infrastructure.config.openshift.io cluster -o=jsonpath='{.status.infrastructureName}')
CLUSTERTAG="openshiftClusterID=${CLUSTERID}"
ROUTERID=$(oc get kuryrnetwork -A --no-headers -o custom-columns=":status.routerId"|uniq)

function log {
    local msg=$1
    date "+%Y-%m-%d %H:%M:%S ${msg}"
}

function wait_for_operators {
    timeout "$KURYR_CO_TIMEOUT" bash <<EOF
until
    oc wait co --all --for='condition=AVAILABLE=True' --timeout=10s && \
    oc wait co --all --for='condition=PROGRESSING=False' --timeout=10s && \
    oc wait co --all --for='condition=DEGRADED=False' --timeout=10s;
do
    sleep 10
    date "+%Y-%m-%d %H:%M:%S Some ClusterOperators aren't ready yet"
done
EOF
}

function wait_for_machineconfpools {
    timeout "$KURYR_MCP_TIMEOUT" bash <<EOF
until
    oc wait mcp --all --for='condition=UPDATED=True' --timeout=10s && \
    oc wait mcp --all --for='condition=UPDATING=False' --timeout=10s && \
    oc wait mcp --all --for='condition=DEGRADED=False' --timeout=10s;
do
    sleep 10
    date "+%Y-%m-%d %H:%M:%S Some MachineConfigPools aren't ready yet"
done
EOF
}

# check if this cluster is driven by kuryr
nettype=$(oc get network.config/cluster -o jsonpath='{.status.networkType}{"\n"}')
if [[ "$nettype" != "Kuryr" ]]; then
    log "Cluster is running on different than Kuryr network type: ${nettype}"
    exit 1
fi

log "Start migration"
rm -fr /tmp/venv
python3 -m venv /tmp/venv

# shellcheck disable=SC1090,SC1091
source /tmp/venv/bin/activate

# venv -----------------------------------------------------------------------

log "Python version: $(python --version)"
pip install --upgrade pip
pip install openstacksdk==0.54.0 python-openstackclient==5.5.0 python-octaviaclient==2.3.0 'python-neutronclient<9.0.0'

log "Setting migration to OVNKubernetes"
oc patch Network.operator.openshift.io cluster --type=merge \
    --patch '{"spec": {"migration": {"networkType": "OVNKubernetes"}}}'
log "Waiting a minute for migration be initialized"
oc wait mcp --for='condition=UPDATING=True' master --timeout=5m

log "Waiting for migration to finish on the nodes"
wait_for_machineconfpools

log "Waiting for cluster readiness"
wait_for_operators

log "Migrate the cluster to OVNKubernetes"
oc patch Network.config.openshift.io cluster --type=merge \
    --patch '{ "spec": { "networkType": "OVNKubernetes" } }'

log "Reboot nodes"
# reboot each node and wait for the cluster to stabilize.
for name in $(openstack server list --name "${CLUSTERID}*" -f value -c Name); do
    openstack server reboot "${name}"
done

log "Wait for cluster being accessible"
wait_for_operators

oc patch Network.operator.openshift.io cluster --type=merge \
    --patch '{ "spec": { "migration": null } }'
log "Migration completed"

# clean up resources
log "Start cleanup"

function REMFIN {
    local resource=$1
    local finalizer=$2
    # shellcheck disable=SC2016
    for res in $(oc get "${resource}" -A --template='{{range $i,$p := .items}}{{ $p.metadata.name }}|{{ $p.metadata.namespace }}{{"\n"}}{{end}}'); do
        name=${res%%|*}
        ns=${res##*|}
        yaml=$(oc get -n "${ns}" "${resource}" "${name}" -o yaml)
        if echo "${yaml}" | grep -q "${finalizer}"; then
            echo "${yaml}" | grep -v  "${finalizer}" | oc replace -n "${ns}" "${resource}" "${name}" -f -
        fi
    done
}

log "Removing kuryr finalizer form services"
REMFIN services kuryr.openstack.org/service-finalizer || true
if oc get -n openshift-kuryr service service-subnet-gateway-ip &>/dev/null; then
    log "Removing kuryr subnet gateway ip service"
    oc -n openshift-kuryr delete service service-subnet-gateway-ip
fi
log "Removing loadbalancers from OpensStack"
for lb in $(openstack loadbalancer list --tags "${CLUSTERTAG}" -f value -c id); do
    openstack loadbalancer delete --cascade "${lb}"
done

log "Removing kuryr finalizer form kuryrloadbalancers CRD"
REMFIN kuryrloadbalancers.openstack.org kuryr.openstack.org/kuryrloadbalancer-finalizers || true
log "Removing k8s namespace openshift-kuryr"
oc delete namespace openshift-kuryr
log "Removing kuryr service subnet from OpenStack router"
openstack router remove subnet "${ROUTERID}" "${CLUSTERID}-kuryr-service-subnet"
log "Removing kuryr service from OpenStack network"
openstack network delete "${CLUSTERID}-kuryr-service-network"
log "Removing kuryr finalizer form k8s pods"
REMFIN pods kuryr.openstack.org/pod-finalizer || true
log "Removing kuryr finalizer form kuryrports CRD"
REMFIN kuryrports.openstack.org kuryr.openstack.org/kuryrport-finalizer || true
log "Removing kuryr finalizer form k8s np"
REMFIN networkpolicy kuryr.openstack.org/networkpolicy-finalizer || true
log "Removing kuryr finalizer form kuryrnetworkpolicies CRD"
REMFIN kuryrnetworkpolicies.openstack.org kuryr.openstack.org/networkpolicy-finalizer || true
mapfile trunks < <(python -c "import openstack; n = openstack.connect().network; print('\n'.join([x.id for x in n.trunks(any_tags='$CLUSTERTAG')]))")
i=0
log "Removing subports that Kuryr created from trunks,"
for trunk in "${trunks[@]}"; do
    trunk=$(echo "$trunk"|tr -d '\n')
    i=$((i+1))
    log "Processing trunk $trunk, ${i}/${#trunks[@]}."
    subports=()
    for subport in $(python -c "import openstack; n = openstack.connect().network; print(' '.join([x['port_id'] for x in n.get_trunk('$trunk').sub_ports if '$CLUSTERTAG' in n.get_port(x['port_id']).tags]))"); do
        subports+=("$subport");
    done
    args=()
    for sub in "${subports[@]}" ; do
        args+=("--subport $sub")
    done
    if [ ${#args[@]} -gt 0 ]; then
        openstack network trunk unset ${args[*]} "${trunk}" || true
    fi
done

log "Removing OpensStack ports, router interfaces and networks"
# shellcheck disable=SC2016
mapfile -t kuryrnetworks < <(oc get kuryrnetwork -A --template='{{range $i,$p := .items}}{{ $p.status.netId }}|{{ $p.status.subnetId }}{{"\n"}}{{end}}') && \
i=0 && \
for kn in "${kuryrnetworks[@]}"; do
    i=$((i+1))
    netID=${kn%%|*}
    subnetID=${kn##*|}
    log "Processing network $netID, ${i}/${#kuryrnetworks[@]}"
    # Remove all ports from the network.
    for port in $(python -c "import openstack; n = openstack.connect().network; print(' '.join([x.id for x in n.ports(network_id='$netID') if x.device_owner != 'network:router_interface']))"); do
        ( openstack port delete "${port}"  || true ) &

        # Only allow 20 jobs in parallel.
        if [[ $(jobs -r -p | wc -l) -ge 20 ]]; then
            wait -n
        fi
    done
    wait

    # Remove the subnet from the router.
    openstack router remove subnet "${ROUTERID}" "${subnetID}" || true

    # Remove the network.
    openstack network delete "${netID}" || true
done
log "Removing OpensStack kuryr security groups"
openstack security group delete "${CLUSTERID}-kuryr-pods-security-group"
log "Removing kuryr created OpensStack subnet pools"
for subnetpool in $(openstack subnet pool list --tags "${CLUSTERTAG}" -f value -c ID); do
    openstack subnet pool delete "${subnetpool}" || true
done
log "Removing kuryr created OpensStack subnet pools"
networks=$(oc get kuryrnetwork -A --no-headers -o custom-columns=":status.netId") && \
for existingNet in $(openstack network list --tags "${CLUSTERTAG}" -f value -c ID); do
    if [[ $networks =~ $existingNet ]]; then
        log "Network still exists: $existingNet, Cleaning up resources has failed"
        exit 1
    fi
done
log "Removing kuryr created OpensStack security groups"
for sgid in $(openstack security group list -f value -c ID -c Description | grep 'Kuryr-Kubernetes Network Policy' | cut -f 1 -d ' '); do
    openstack security group delete "${sgid}" || true
done
log "Removing kuryr finalizer form kuryrnetworkpolicies CRD"
REMFIN kuryrnetworks.openstack.org kuryrnetwork.finalizers.kuryr.openstack.org
if python3 -c "import sys; import openstack; n = openstack.connect().network; r = n.get_router('$ROUTERID'); sys.exit(0) if r.description != 'Created By OpenShift Installer' else sys.exit(1)"; then
    log "Removing router ${ROUTERID}"
    openstack router delete "${ROUTERID}" || true
fi

# this is needed as deactivating will fail on old version of python and/or bash
set +o nounset
deactivate
rm -fr /tmp/venv
log "Cleanup completed"
